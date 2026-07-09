//! less-sheet core — file access, parsing, and windowed row access.
//! Implements api/lesssheet.h exactly (see it and contracts/api.zig for the
//! full semantics: format neutrality, ownership & the eviction-safe borrow
//! rule, O(head) open cost, the scan frontier, threading lanes, dialect
//! grammar, sniffing, header rule). contracts/ and tests/ are planner-owned.
//!
//! Architecture (viewer-ui slice):
//!   - The source file is mmap'd read-only; nothing is copied. Cell text is
//!     re-lexed on demand into an owned window buffer (quote-collapsing means
//!     a cell is not always a contiguous file slice), so borrows survive the
//!     core's background scanning and are invalidated only by the next
//!     ls_window_set / ls_close (eviction-safe borrow rule).
//!   - A sparse row index (checkpoints: data-row -> content offset at record
//!     boundaries, one every `checkpoint_interval` rows) plus a monotone scan
//!     FRONTIER. ls_open indexes only the head region (<= head budget). One
//!     core-owned worker thread advances the frontier: to EOF under AUTO, or
//!     toward a jump target under MANUAL. window_set never advances it.
//!   - The worker is the SOLE writer of the frontier/index; a single pthread
//!     mutex guards the frontier + jump slot for the poll/control lane and for
//!     window_set's clamp/checkpoint lookup. The window buffer is touched only
//!     by the (caller-serialized) window lane, so cell reads need no lock.

const std = @import("std");
const api = @import("api");

const posix = std.posix;
const c = std.c;

const base = @import("base.zig");
const enc = @import("encoding.zig");
const lexer = @import("lexer.zig");
const matcher = @import("matcher.zig");
const sniff = @import("sniff.zig");
const filter = @import("filter.zig");
const search = @import("search.zig");
const index = @import("index.zig");
const window = @import("window.zig");
const Document = base.Document;
const CellRef = base.CellRef;
const asDoc = base.asDoc;
const asDocMut = base.asDocMut;
const freeDoc = base.freeDoc;

/// Re-exported so `root.isNumeric` stays a stable name (moved to matcher.zig;
/// not part of the C ABI, but was `pub` before the split).
pub const isNumeric = matcher.isNumeric;

/// Default allocator behind `ls_open` (thread-safe). `ls_close` returns all
/// document storage here.
const default_gpa = std.heap.smp_allocator;

// --- Tunables (implementation detail; not part of the ABI) -----------------

/// Sample size (SOURCE bytes) for encoding detection (BOM / NUL-ratio / UTF-8
/// validation): a small, fixed prefix of the head is plenty for the pinned
/// heuristics and keeps detection itself trivially cheap. Well within
/// `head_budget`, so it never affects the O(head) bound.
const encoding_sample_bytes: usize = 256 * 1024;

// ---------------------------------------------------------------------------
// Lifecycle (C ABI + explicit-allocator seam).
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_open`. Equals
/// `openWithAllocator(<default allocator>, path, options, out_doc)`.
pub export fn ls_open(path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) callconv(.c) api.Status {
    return openWithAllocator(default_gpa, path, options, out_doc);
}

fn validByte(v: i32) bool {
    return v >= 0x01 and v <= 0x7F and v != 0x0A and v != 0x0D;
}

fn validEncodingOption(v: i32) bool {
    return v == api.encoding_auto or (v >= 0 and v <= @as(i32, api.encoding_windows1252));
}

fn validateOptions(opt: api.OpenOptions) bool {
    if (opt.separator != api.sniff and !validByte(opt.separator)) return false;
    if (opt.quote != api.sniff and opt.quote != api.quote_none and !validByte(opt.quote)) return false;
    if (opt.header != api.sniff and opt.header != api.header_off and opt.header != api.header_on) return false;
    if (opt.index_mode != api.index_auto and opt.index_mode != api.index_manual) return false;
    if (!validEncodingOption(opt.encoding)) return false;
    // Forced separator == forced quote byte is a collision.
    if (opt.separator != api.sniff and opt.separator == opt.quote) return false;
    return true;
}

/// See contracts/api.zig `openWithAllocator`. Every heap allocation for the
/// document goes through `gpa`; the file mapping itself (mmap) is exempt.
pub fn openWithAllocator(gpa: std.mem.Allocator, path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) api.Status {
    out_doc.* = null;

    const opt: api.OpenOptions = if (options) |o| o.* else .{};
    if (!validateOptions(opt)) return .invalid_argument;

    // Open + stat (no file bytes consumed beyond the head region below).
    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| return switch (err) {
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .io,
    };
    defer _ = c.close(fd);

    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return .io;
    if (!posix.S.ISREG(@as(u32, st.mode))) return .io; // dirs/devices -> distinct .io
    const file_size: u64 = if (st.size > 0) @intCast(st.size) else 0;

    // Map the file head-to-tail (sparse tails cost nothing; pages fault lazily
    // and the indexer madvises them away). Empty files are not mapped.
    var mapping: ?[]align(std.heap.page_size_min) const u8 = null;
    if (file_size > 0) {
        const m = posix.mmap(null, file_size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return .io;
        mapping = m;
    }

    // Resolve the source encoding from the raw head bytes (BEFORE dialect
    // sniffing -- see TEXT AND ENCODING): BOM, else the NUL-ratio heuristic,
    // else UTF-8 validation, else Latin-1; a forced encoding bypasses
    // detection but still strips a matching BOM. The sample is a small,
    // fixed prefix -- well within the O(head) budget regardless of file size.
    const sample: []const u8 = if (mapping) |m| m[0..@min(m.len, encoding_sample_bytes)] else &.{};
    const enc_res = enc.resolveEncoding(sample, opt.encoding);
    const content: []const u8 = if (mapping) |m| m[enc_res.bom_len..file_size] else &.{};

    const doc = gpa.create(Document) catch {
        if (mapping) |m| posix.munmap(m);
        return .io;
    };
    doc.* = .{
        .gpa = gpa,
        .mapping = mapping,
        .content = content,
        .content_len = content.len,
        .file_size = file_size,
        .bom_len = enc_res.bom_len,
        .encoding = enc_res.encoding,
        .sep = api.default_separator,
        .quote = api.default_quote,
        .dialect = undefined,
        .column_count = 0,
        .data_start = 0,
        .auto = opt.index_mode == api.index_auto,
        .has_header = false,
        .header_buf = &.{},
        .header_refs = &.{},
        .record1_capped = false,
        .row0_pinned_buf = &.{},
        .row0_pinned_refs = &.{},
        .mutex = .{},
        .cond = .{},
        .checkpoints = .empty,
        .frontier_rows = 0,
        .frontier_offset = 0,
        .complete = true, // an empty document is complete at open
        .total_rows = 0,
        .jump_state = .idle,
        .jump_target = 0,
        .jump_start_rows = 0,
        .jump_progress = 0.0,
        .jump_landed = 0,
        .search_state = .idle,
        .search_nav = .none,
        .search_progress = 0.0,
        .search_found_row = 0,
        .search_found_col = 0,
        .search_position = 0,
        .search_total = 0,
        .search_total_exact = false,
        .search_offset = 0,
        .search_rows = 0,
        .search_to_eof = true,
        .search_gen = 0,
        .nav_pending = false,
        .nav_anchor = 0,
        .nav_dir = .forward,
        .search_kind = .text,
        .search_op = .eq,
        .search_column = 0,
        .search_value = &.{},
        .search_value_dec = .{},
        .search_fold = false,
        .scope_mask = &.{},
        .block_counts = .empty,
        .search_scratch = .empty,
        .search_refs = .empty,
        .w_value = .empty,
        .w_mask = .empty,
        .w_ctx = .{},
        .w_gen = 0,
        .nav_scratch = .empty,
        .nav_refs = .empty,
        .filter_state = .idle,
        .filter_progress = 0.0,
        .filter_total = 0,
        .filter_total_exact = false,
        .filter_offset = 0,
        .filter_rows = 0,
        .filter_gen = 0,
        .filter_kind = .text,
        .filter_op = .eq,
        .filter_column = 0,
        .filter_value = &.{},
        .filter_value_dec = .{},
        .filter_fold = false,
        .filter_scope_mask = &.{},
        .filter_block_counts = .empty,
        .filter_scratch = .empty,
        .filter_refs = .empty,
        .wf_value = .empty,
        .wf_mask = .empty,
        .wf_ctx = .{},
        .wf_gen = 0,
        .worker = null,
        .stop = false,
        .stop_atomic = .init(false),
        .win_buf = .empty,
        .win_refs = .empty,
        .win_source = .empty,
        .win_first = 0,
        .win_rows = 0,
    };

    // Resolve the effective dialect (sniff the non-forced parameters) on the
    // TRANSCODED structure of the head: sniffing/header/column-count logic is
    // unchanged, but every byte comparison now flows through `decodeUnit` so
    // it is correct for whichever encoding produced this UTF-8 (see
    // api/lesssheet.h "Pipeline order at open").
    const rd = sniff.sniffDialect(content, opt, doc.encoding);
    doc.sep = rd.sep;
    doc.quote = rd.quote;

    // Record 1 -> column count, header decision, header cells.
    if (content.len > 0) {
        if (!buildShape(doc, opt)) {
            freeDoc(doc);
            return .io;
        }
        // The base checkpoint must exist: findCheckpoint always reads [0].
        doc.checkpoints.append(gpa, .{ .row = 0, .offset = doc.data_start }) catch {
            freeDoc(doc);
            return .io;
        };
        doc.frontier_offset = doc.data_start;
        if (doc.has_header and doc.record1_capped) {
            // The header record itself never terminated within the head
            // budget (requirement 9): its true end -- and therefore where
            // data would even start -- is unknown. Report 0 data rows,
            // exact, and do NOT headScan/index past the budget limit: doing
            // so would lex the still-open header field's tail as bogus data
            // records. The header cells themselves (capped + flagged) are
            // already pinned by buildShape and served by ls_header_cell.
            doc.complete = true;
            doc.total_rows = 0;
        } else {
            doc.complete = false;
            index.headScan(doc);
        }
    }

    doc.dialect = .{
        .separator = doc.sep,
        .quote = doc.quote orelse api.default_quote,
        .has_quote = doc.quote != null,
        .header = doc.has_header,
        .encoding = doc.encoding,
        .separator_forced = opt.separator != api.sniff,
        .quote_forced = opt.quote != api.sniff,
        .header_forced = opt.header != api.sniff,
        .encoding_forced = opt.encoding != api.encoding_auto,
    };

    // One worker for the document's lifetime: advances the frontier (AUTO) or
    // parks until a jump (MANUAL). Failure to spawn only forfeits background
    // progress; the head frontier still serves the first screen.
    doc.worker = std.Thread.spawn(.{}, index.workerMain, .{doc}) catch null;

    out_doc.* = @ptrCast(doc);
    return .ok;
}

/// Decode record 1, fix the column count, decide the header, and (when the
/// header is on) retain its cells. Bounded to the O(head) budget (requirement
/// 9 / BOUNDED RECORD 1): a record 1 that doesn't terminate within it still
/// yields a column count (>= 1, the fields decoded so far) and a display-
/// capped, truncation-flagged final field; when record 1 is ALSO data row 0
/// (header off) its capped decode is pinned (see Document.row0_pinned_*) so
/// ls_window_set never has to re-scan the pathological record. When record 1
/// IS the effective header instead, `data_start` becomes the budget cut point
/// only as a marker -- the caller (openWithAllocator) sees `record1_capped &&
/// has_header` and reports 0 data rows instead of headScan-ing from there
/// (the header's true end is unknown, so there is no confirmed data, and
/// nothing may lex the still-open header field's tail as bogus rows). Every
/// cell is ALSO subject to the LS_CELL_MAX_BYTES display cap regardless of
/// capping (header/row-0 cells are never re-decoded after open). Returns
/// false only on allocation failure.
fn buildShape(doc: *Document, opt: api.OpenOptions) bool {
    var tmp_buf: std.ArrayList(u8) = .empty;
    var tmp_refs: std.ArrayList(CellRef) = .empty;
    const lim = index.headSourceLimit(doc);
    const res = lexer.lexInto(doc.content, 0, doc.sep, doc.quote, null, api.cell_max_bytes, lim, doc.encoding, &tmp_buf, &tmp_refs, doc.gpa) catch {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        return false;
    };
    doc.column_count = @intCast(tmp_refs.items.len);
    doc.record1_capped = res.capped;

    var all_numeric = true;
    for (tmp_refs.items) |ref| {
        if (!matcher.isNumeric(tmp_buf.items[ref.start .. ref.start + ref.len])) {
            all_numeric = false;
            break;
        }
    }
    doc.has_header = switch (opt.header) {
        api.header_on => true,
        api.header_off => false,
        else => !all_numeric, // sniff: header unless every record-1 cell is numeric
    };

    if (doc.has_header) {
        doc.header_buf = tmp_buf.toOwnedSlice(doc.gpa) catch {
            tmp_buf.deinit(doc.gpa);
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.header_refs = tmp_refs.toOwnedSlice(doc.gpa) catch {
            doc.gpa.free(doc.header_buf);
            doc.header_buf = &.{};
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.data_start = res.next;
    } else if (doc.record1_capped) {
        doc.row0_pinned_buf = tmp_buf.toOwnedSlice(doc.gpa) catch {
            tmp_buf.deinit(doc.gpa);
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.row0_pinned_refs = tmp_refs.toOwnedSlice(doc.gpa) catch {
            doc.gpa.free(doc.row0_pinned_buf);
            doc.row0_pinned_buf = &.{};
            tmp_refs.deinit(doc.gpa);
            return false;
        };
        doc.data_start = 0; // record 1 is data row 0
    } else {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        doc.data_start = 0; // record 1 is data row 0
    }
    return true;
}

/// See api/lesssheet.h `ls_close`.
pub export fn ls_close(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.lock();
    d.stop = true;
    d.stop_atomic.store(true, .monotonic);
    d.wakeWorker();
    d.unlock();
    if (d.worker) |w| w.join();
    freeDoc(d);
}

// ---------------------------------------------------------------------------
// Document facts — zero allocation, total functions.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_dialect_get`.
pub export fn ls_dialect_get(doc: *const api.Doc) callconv(.c) api.Dialect {
    return asDoc(doc).dialect;
}

/// See api/lesssheet.h `ls_column_count`.
pub export fn ls_column_count(doc: *const api.Doc) callconv(.c) u32 {
    return asDoc(doc).column_count;
}

// ---------------------------------------------------------------------------
// Row-count knowledge and index progress.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_row_count_get`.
pub export fn ls_row_count_get(doc: *const api.Doc) callconv(.c) api.RowCount {
    return index.rowCount(asDocMut(doc));
}

/// See api/lesssheet.h `ls_index_poll`.
pub export fn ls_index_poll(doc: *const api.Doc) callconv(.c) api.ScanProgress {
    return index.indexPoll(asDocMut(doc));
}

// ---------------------------------------------------------------------------
// Windowed row access.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_window_set`. Never advances the frontier; re-lexes
/// the requested rows (behind the frontier) from the nearest checkpoint into
/// the owned window buffer, evicting the previous window. Every cell is
/// decoded through `decodeUnit` (the document's resolved encoding) and
/// display-capped to LS_CELL_MAX_BYTES (requirement 8).
pub export fn ls_window_set(doc: *api.Doc, first_row: u64, row_count: u32) callconv(.c) api.RowRange {
    const d: *Document = @ptrCast(@alignCast(doc));
    return window.windowSet(d, first_row, row_count);
}

/// See api/lesssheet.h `ls_cell`. Zero allocation; total function.
pub export fn ls_cell(doc: *const api.Doc, row: u64, col: u32) callconv(.c) api.Str {
    return window.cell(asDoc(doc), row, col);
}

/// See api/lesssheet.h `ls_header_cell`. Zero allocation; total function.
pub export fn ls_header_cell(doc: *const api.Doc, col: u32) callconv(.c) api.Str {
    return window.headerCell(asDoc(doc), col);
}

/// See api/lesssheet.h `ls_cell_truncated`. Same (row, col) domain and
/// window/borrow rules as ls_cell; reports whether the LS_CELL_MAX_BYTES
/// display cap cut the served cell (set alongside the cell's CellRef by
/// lexInto). Zero allocation; total function; never fails.
pub export fn ls_cell_truncated(doc: *const api.Doc, row: u64, col: u32) callconv(.c) bool {
    return window.cellTruncated(asDoc(doc), row, col);
}

/// See api/lesssheet.h `ls_header_cell_truncated`. Same semantics as
/// ls_cell_truncated for the effective header record. Zero allocation; total
/// function; never fails.
pub export fn ls_header_cell_truncated(doc: *const api.Doc, col: u32) callconv(.c) bool {
    return window.headerCellTruncated(asDoc(doc), col);
}

// ---------------------------------------------------------------------------
// Jump-scans.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_jump_start`.
pub export fn ls_jump_start(doc: *api.Doc, target_row: u64) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    index.jumpStart(d, target_row);
}

/// See api/lesssheet.h `ls_jump_cancel`.
pub export fn ls_jump_cancel(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    index.jumpCancel(d);
}

/// See api/lesssheet.h `ls_jump_poll`.
pub export fn ls_jump_poll(doc: *const api.Doc) callconv(.c) api.JumpStatus {
    return index.jumpPoll(asDocMut(doc));
}

// ===========================================================================
// Search (find-seek slice) — see src/search.zig for the streaming match-scan,
// navigation, and the ABI logic below. See api/lesssheet.h SEARCH.
// ===========================================================================

/// See api/lesssheet.h `ls_search_start`.
pub export fn ls_search_start(doc: *api.Doc, request: *const api.SearchRequest) callconv(.c) bool {
    const d: *Document = @ptrCast(@alignCast(doc));
    return search.startSearch(d, request);
}

/// See api/lesssheet.h `ls_search_nav`.
pub export fn ls_search_nav(doc: *api.Doc, anchor_row: u64, dir: api.SearchDir) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    search.navSearch(d, anchor_row, dir);
}

/// See api/lesssheet.h `ls_search_cancel`. Zero allocation.
pub export fn ls_search_cancel(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    search.cancelSearch(d);
}

/// See api/lesssheet.h `ls_search_poll`. Zero allocation; never fails.
pub export fn ls_search_poll(doc: *const api.Doc) callconv(.c) api.SearchStatus {
    return search.pollSearch(asDocMut(doc));
}

// ---------------------------------------------------------------------------
// Filtered views (filtered-views slice) — see api/lesssheet.h FILTERED VIEWS
// for the full model. ls_filter_set validates EXACTLY like ls_search_start
// (duplicated rather than shared, so neither call site risks drifting the
// other's already-frozen-green behavior).
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_filter_set`.
pub export fn ls_filter_set(doc: *api.Doc, request: *const api.SearchRequest) callconv(.c) bool {
    const d: *Document = @ptrCast(@alignCast(doc));
    return filter.setFilter(d, request);
}

/// See api/lesssheet.h `ls_filter_clear`. ZERO allocation.
pub export fn ls_filter_clear(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    filter.clearFilter(d);
}

/// See api/lesssheet.h `ls_filter_poll`. ZERO allocation; never fails.
pub export fn ls_filter_poll(doc: *const api.Doc) callconv(.c) api.FilterStatus {
    return filter.pollFilter(asDocMut(doc));
}

/// See api/lesssheet.h `ls_source_row`. Same window/borrow domain as ls_cell
/// (win_source[i] is populated by ls_window_set alongside win_refs). Total
/// function; ZERO allocation; never fails; never scans.
pub export fn ls_source_row(doc: *const api.Doc, row: u64) callconv(.c) u64 {
    return window.sourceRow(asDoc(doc), row);
}

/// See api/lesssheet.h `ls_row_oversized`. Same window/borrow domain as ls_cell
/// / ls_source_row (the per-row flag is set by ls_window_set alongside the
/// served cells). SEED (RED): forwards to window.rowOversized, which returns
/// false until the build cell bounds the window scan. Total function; ZERO
/// allocation; never fails; never scans.
pub export fn ls_row_oversized(doc: *const api.Doc, row: u64) callconv(.c) bool {
    return window.rowOversized(asDoc(doc), row);
}
