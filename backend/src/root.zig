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
const csv_reader = @import("csv_reader.zig");
const source_mod = @import("source.zig");
const matcher = @import("matcher.zig");
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

    // Resolve the source encoding then the dialect from the raw head bytes
    // (see csv_reader.openHead: encoding BEFORE dialect sniffing -- TEXT AND
    // ENCODING) and hand back the ready CSV Reader + the post-BOM content
    // slice -- everything CSV-specific behind the Reader interface (see
    // docs/architecture/ARCH-reader-interface.md). `raw` is the whole
    // mapping (== file_size bytes) or empty for a 0-byte file; openHead runs
    // unconditionally either way, exactly like the pre-reorg pipeline.
    const raw: []const u8 = if (mapping) |m| m else &.{};
    const kind: source_mod.SourceKind = if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) .gzip else .mmap;
    var source = source_mod.sourceFromMappingAlloc(gpa, raw, kind) catch {
        if (mapping) |m| posix.munmap(m);
        return .io;
    };
    var source_owned = true;
    defer if (source_owned) source_mod.sourceDeinit(&source);
    if (!source.gzipUsable()) {
        if (mapping) |m| posix.munmap(m);
        return .io;
    }
    const head_bytes = if (kind == .gzip) source.openHead() else raw;
    const oh = csv_reader.openHead(head_bytes, opt, encoding_sample_bytes);
    source_mod.rebaseBom(&source, oh.bom_len);

    const doc = gpa.create(Document) catch {
        if (mapping) |m| posix.munmap(m);
        return .io;
    };
    doc.* = .{
        .gpa = gpa,
        .mapping = mapping,
        .source = source,
        .reader = .{ .csv = oh.reader },
        .content_len = if (kind == .mmap) oh.content.len else file_size,
        .file_size = file_size,
        .bom_len = oh.bom_len,
        .dialect = undefined,
        .column_count = 0,
        .data_start = undefined, // set unconditionally right after construction, below
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
        .oversized_checkpoints = .empty,
        .oversized_stage = .empty,
        .frontier_rows = 0,
        .frontier_pos = undefined, // set unconditionally right after construction, below
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
        .search_pos = undefined, // set unconditionally right after construction, below
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
        .search_failure = &.{},
        .scope_mask = &.{},
        .block_counts = .empty,
        .search_scratch = .empty,
        .search_refs = .empty,
        .w_value = .empty,
        .w_mask = .empty,
        .w_failure = .empty,
        .w_ctx = .{},
        .w_gen = 0,
        .nav_scratch = .empty,
        .nav_refs = .empty,
        .filter_state = .idle,
        .filter_progress = 0.0,
        .filter_total = 0,
        .filter_total_exact = false,
        .filter_pos = undefined, // set unconditionally right after construction, below
        .filter_rows = 0,
        .filter_gen = 0,
        .filter_kind = .text,
        .filter_op = .eq,
        .filter_column = 0,
        .filter_value = &.{},
        .filter_value_dec = .{},
        .filter_fold = false,
        .filter_failure = &.{},
        .filter_scope_mask = &.{},
        .filter_block_counts = .empty,
        .filter_oversized_stage = .empty,
        .filter_oversized_matches = .empty,
        .filter_scratch = .empty,
        .filter_refs = .empty,
        .wf_value = .empty,
        .wf_mask = .empty,
        .wf_failure = .empty,
        .wf_ctx = .{},
        .wf_gen = 0,
        .worker = null,
        .stop = false,
        .stop_atomic = .init(false),
        .win_buf = .empty,
        .win_refs = .empty,
        .win_source = .empty,
        .win_oversized = .empty,
        .win_first = 0,
        .win_rows = 0,
    };
    source_owned = false;

    if (kind == .gzip) switch (doc.source) {
        .gzip => |g| {
            doc.gz_physical_in = g.open_physical;
            doc.gz_inflated_out = g.open_inflated;
            doc.gz_resident_bytes = g.residentBytes();
        },
        .mmap => unreachable,
    };

    // `data_start`/`frontier_pos`/`search_pos`/`filter_pos` all start at the
    // Reader's own notion of "the very beginning" (0 for CSV) -- obtained
    // opaquely (never a bare literal; see reader.zig's module doc) now that
    // `doc.reader`/`doc.source` exist.
    const start_pos = doc.reader.start(doc.source);
    doc.data_start = start_pos;
    doc.frontier_pos = start_pos;
    doc.search_pos = start_pos;
    doc.filter_pos = start_pos;

    // Record 1 -> column count, header decision, header cells.
    if (oh.content.len > 0) {
        if (!buildShape(doc, opt)) {
            freeDoc(doc);
            return .io;
        }
        // The base checkpoint must exist: findCheckpoint always reads [0].
        doc.checkpoints.append(gpa, .{ .row = 0, .pos = doc.data_start }) catch {
            freeDoc(doc);
            return .io;
        };
        doc.frontier_pos = doc.data_start;
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
        .separator = oh.reader.sep,
        .quote = oh.reader.quote orelse api.default_quote,
        .has_quote = oh.reader.quote != null,
        .header = doc.has_header,
        .encoding = oh.reader.encoding,
        .separator_forced = opt.separator != api.sniff,
        .quote_forced = opt.quote != api.sniff,
        .header_forced = opt.header != api.sniff,
        .encoding_forced = opt.encoding != api.encoding_auto,
    };

    // Only after encoding/shape/header and the complete bounded head scan may
    // subsequent worker/cursor work consume compressed input past 4 MiB.
    source_mod.sourceFinishOpen(&doc.source);

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
    const res = doc.reader.materialize(doc.source, doc.reader.start(doc.source), null, api.cell_max_bytes, lim, &tmp_buf, &tmp_refs, doc.gpa) catch {
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
        doc.data_start = doc.reader.start(doc.source); // record 1 is data row 0
    } else {
        tmp_buf.deinit(doc.gpa);
        tmp_refs.deinit(doc.gpa);
        doc.data_start = doc.reader.start(doc.source); // record 1 is data row 0
    }
    return true;
}

/// See api/lesssheet.h `ls_close`.
pub export fn ls_close(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.lock();
    d.stop = true;
    d.stop_atomic.store(true, .monotonic);
    source_mod.sourceShutdown(&d.source);
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
/// served cells). Total function; ZERO allocation; never fails; never scans.
pub export fn ls_row_oversized(doc: *const api.Doc, row: u64) callconv(.c) bool {
    return window.rowOversized(asDoc(doc), row);
}

// ---------------------------------------------------------------------------
// Test-only instrumentation seam (ARCH-stream-copy AC1-AC5). NOT the C ABI:
// plain Zig fns re-exported by contracts/api.zig for the frozen backend tests
// ONLY (like `openWithAllocator`), so api/lesssheet.h + the ls_cell_copy ABI
// stay BYTE-IDENTICAL. They toggle the forward COPY CURSOR and read/reset the
// copy-path SOURCE-ROW-ADVANCE counter (base.Document.copy_cursor_enabled /
// copy_advances). Production always runs cursor-enabled; the tests flip it OFF
// to obtain the byte-identical locate-from-scratch REFERENCE (AC1/AC2) and the
// interval-costly BASELINE (AC3/AC4/AC5).
//
// SEED: the cursor is not built yet, so `cellCopy` locates from scratch in BOTH
// toggle states (identical output — cc1..cc5 + the AC1/AC2 equivalence sweeps
// stay green) and NOTHING increments `copy_advances` (copyAdvances == 0). That
// zero is exactly what makes the AC3/AC4/AC5 count assertions RED until the
// implementer builds the cursor AND increments `copy_advances` once per source
// row the copy path steps forward (a boundsAfter skip in cursor-OFF mode; a
// single cursor forward-advance in cursor-ON mode) — in BOTH the identity
// (window.cellCopy) and filtered (window.cellCopyFiltered) paths.
// ---------------------------------------------------------------------------

/// See contracts/api.zig `copyCursorSetEnabled`.
pub fn copyCursorSetEnabled(doc: *api.Doc, enabled: bool) void {
    asDocMut(doc).copy_cursor_enabled = enabled;
}

/// See contracts/api.zig `copyAdvances`.
pub fn copyAdvances(doc: *const api.Doc) u64 {
    return asDoc(doc).copy_advances;
}

/// See contracts/api.zig `copyAdvancesReset`.
pub fn copyAdvancesReset(doc: *api.Doc) void {
    asDocMut(doc).copy_advances = 0;
}

// ---------------------------------------------------------------------------
// Full-cell read (select-copy slice) — the bounded, window-INDEPENDENT LOSSLESS
// cell read. Poll/control lane (asDocMut takes the frontier mutex); copies into
// the caller buffer (no borrow); ZERO alloc; never fails. See api/lesssheet.h
// FULL-CELL READ. ARCH-stream-copy makes window.cellCopy cursor-accelerated
// behind this UNCHANGED ABI (byte-identical output).
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_cell_copy`.
pub export fn ls_cell_copy(doc: *const api.Doc, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) callconv(.c) api.CopyResult {
    return window.cellCopy(asDocMut(doc), row, col, buf, buf_len, out_len, out_truncated);
}

// ===========================================================================
// csv-gz internal-seam re-exports + instrumentation seams (ARCH-csv-gz).
// The re-exports below let contracts/api.zig pin the enumerated Source/Reader
// SEAM capabilities as `core.*` (Decision 1-C) while their DEFINITIONS stay in
// source.zig / reader.zig (implementer-owned; the af83db9 boundary). The gz*
// seams are Zig-only test instrumentation (NOT the C ABI -- like copyAdvances),
// reading DEFAULTED base.Document state, so api/lesssheet.h is byte-identical
// and a plain-CSV document reports zeros. SEED: gzip is not wired, so these
// report zero/false -> csv-gz quantitative ACs are RED; existing tests GREEN.
// ===========================================================================

const source_seam = @import("source.zig");
const reader_seam = @import("reader.zig");

// Seam CAPABILITY re-exports (pinned by contracts/api.zig comptime block).
pub const Source = source_seam.Source;
pub const Pos = reader_seam.Pos;
pub const Cursor = source_seam.Cursor;
pub const SourceKind = source_seam.SourceKind;
pub const sourceFromMapping = source_seam.sourceFromMapping;
pub const sourceShutdown = source_seam.sourceShutdown;
pub const sourceDeinit = source_seam.sourceDeinit;
pub const sourceEndAt = reader_seam.sourceEndAt;
pub const sourceCursorAt = reader_seam.sourceCursorAt;
pub const posLogicalBytes = reader_seam.posLogicalBytes;
pub const posPhysicalBytes = reader_seam.posPhysicalBytes;
pub const sourceRebaseBom = reader_seam.sourceRebaseBom;
pub const readerMatchRow = reader_seam.readerMatchRow;

/// See contracts/api.zig `gzOpenBudget` (AC5/AC6/AC7).
pub fn gzOpenBudget(doc: *const api.Doc) api.OpenBudget {
    const d = asDoc(doc);
    return .{ .physical_in = d.gz_physical_in, .inflated_out = d.gz_inflated_out };
}
/// See contracts/api.zig `gzReplayStats` (AC15).
pub fn gzReplayStats(doc: *const api.Doc) api.ReplayStats {
    const d = asDoc(doc);
    if (d.source == .gzip) {
        const g = d.source.gzip;
        g.lock();
        defer g.unlock();
        return .{ .landed = g.replay_landed, .restored_checkpoint_logical = g.replay_restored, .inflated_replay = g.replay_inflated };
    }
    return .{
        .landed = d.gz_replay_landed,
        .restored_checkpoint_logical = d.gz_replay_restored_logical,
        .inflated_replay = d.gz_replay_inflated,
    };
}
/// See contracts/api.zig `gzReplayStatsReset`.
pub fn gzReplayStatsReset(doc: *api.Doc) void {
    const d = asDocMut(doc);
    if (d.source == .gzip) {
        const g = d.source.gzip;
        g.lock();
        defer g.unlock();
        g.replay_landed = false;
        g.replay_restored = 0;
        g.replay_inflated = 0;
    }
    d.gz_replay_landed = false;
    d.gz_replay_restored_logical = 0;
    d.gz_replay_inflated = 0;
}
/// See contracts/api.zig `gzResidentBytes` (AC17).
pub fn gzResidentBytes(doc: *const api.Doc) u64 {
    const d = asDoc(doc);
    if (d.source == .gzip) {
        const g = d.source.gzip;
        g.lock();
        defer g.unlock();
        return g.residentBytes();
    }
    return 0;
}
/// See contracts/api.zig `gzCheckpointStore` (AC17/AC21).
pub fn gzCheckpointStore(doc: *const api.Doc) api.CheckpointStore {
    const d = asDoc(doc);
    if (d.source == .gzip) {
        const g = d.source.gzip;
        g.lock();
        defer g.unlock();
        return .{ .present = g.spill_fd != null, .bytes = g.spill_bytes, .mode = if (g.spill_fd != null) 0o600 else 0, .unlinked = g.spill_fd != null };
    }
    return .{
        .present = d.gz_ckpt_present,
        .bytes = d.gz_ckpt_bytes,
        .mode = d.gz_ckpt_mode,
        .unlinked = d.gz_ckpt_unlinked,
    };
}
/// See contracts/api.zig `gzCheckpointStoreFailAfter` (AC18).
pub fn gzCheckpointStoreFailAfter(doc: *api.Doc, ops: u64) void {
    const d = asDocMut(doc);
    d.gz_ckpt_fail_after = ops;
    if (d.source == .gzip) d.source.gzip.spill_fail_after.store(ops, .release);
}
/// See contracts/api.zig `gzForceChunkBytes` (AC12).
pub fn gzForceChunkBytes(doc: *api.Doc, n: u64) void {
    const d = asDocMut(doc);
    d.gz_force_chunk_bytes = n;
    if (d.source == .gzip) d.source.gzip.force_chunk.store(n, .release);
}
/// See contracts/api.zig `gzStreamMatcherResidentBytes` (AC13).
pub fn gzStreamMatcherResidentBytes(doc: *const api.Doc) u64 {
    return asDoc(doc).gz_match_resident_bytes;
}
/// See contracts/api.zig `gzStreamMatcherResidentReset`.
pub fn gzStreamMatcherResidentReset(doc: *api.Doc) void {
    asDocMut(doc).gz_match_resident_bytes = 0;
}
/// See contracts/api.zig `gzCacheCopyBytes` (AC20 regression proxy).
pub fn gzCacheCopyBytes(doc: *const api.Doc) u64 {
    return asDoc(doc).gz_cache_copy_bytes;
}
/// See contracts/api.zig `gzSnapshotProbe` (AC14). SEED: the inflate-checkpoint
/// snapshot adapter is not built yet -> report "no snapshot taken, not
/// identical" so AC14 is RED. The comptime shape-assertion in contracts/api.zig
/// already proves the adapter is FEASIBLE against the installed std; this seam
/// proves it WORKS byte-for-byte once built.
pub fn gzSnapshotProbe(gpa: std.mem.Allocator, gzip_bytes: []const u8, probe_logical: u64) api.SnapshotProbe {
    const identical = source_seam.snapshotProbe(gpa, gzip_bytes, probe_logical);
    return .{ .restored = identical, .identical = identical };
}


// ===========================================================================
// window-budget instrumentation seams (ARCH-window-budget). Zig-only test
// instrumentation (NOT the C ABI -- like copyAdvances / gz*), reading DEFAULTED
// base.Document state, so api/lesssheet.h stays BYTE-IDENTICAL (AC1) and a
// document that never hit the aggregate window cap / the #6 nav reports zero.
// SEED: the aggregate window meter and the bounded/off-main filtered nav are NOT
// built, so both report zero -> the quantitative window-budget/#6 ACs are RED;
// the existing window/search/filter behavior is unchanged and stays GREEN.
// ===========================================================================

/// See contracts/api.zig `windowChargedBytes` (AC2/AC3/AC4/AC8).
pub fn windowChargedBytes(doc: *const api.Doc) u64 {
    return asDoc(doc).window_charged_bytes;
}

/// See contracts/api.zig `navChargedBytes` (AC11/AC12, backlog #6).
pub fn navChargedBytes(doc: *const api.Doc) u64 {
    return asDoc(doc).nav_charged_bytes;
}
