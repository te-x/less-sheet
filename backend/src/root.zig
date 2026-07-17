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
const open = @import("open.zig");
const net_source = @import("net_source.zig");
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
/// document goes through `gpa`; the file mapping itself (mmap) is exempt. The
/// Document construction, head scan, shape build, and worker spawn are shared
/// with the network open path — see src/open.zig `buildDocument`.
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

    const raw: []const u8 = if (mapping) |m| m else &.{};
    const kind: source_mod.SourceKind = if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) .gzip else .mmap;
    var source = source_mod.sourceFromMappingAlloc(gpa, raw, kind) catch {
        if (mapping) |m| posix.munmap(m);
        return .io;
    };
    if (!source.gzipUsable()) {
        source_mod.sourceDeinit(&source);
        if (mapping) |m| posix.munmap(m);
        return .io;
    }

    const doc = open.buildDocument(gpa, source, mapping, file_size, opt) orelse return .io;
    out_doc.* = @ptrCast(doc);
    return .ok;
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
    const result = window.windowSet(d, first_row, row_count);
    column.windowMaterialized(d);
    return result;
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

/// See api/lesssheet.h `ls_window_match_flags` (MATCH-FLAGS EXTENSION).
/// Window lane; a const handle with interior-mutable memoization, exactly like
/// ls_cell_copy (asDocMut). Delegates to window.zig, which reads the
/// materialized window (win_buf/win_refs) + the active search request.
pub export fn ls_window_match_flags(doc: *const api.Doc, first_col: u32, col_count: u32) callconv(.c) api.Str {
    return window.matchFlags(asDocMut(doc), first_col, col_count);
}

// ---------------------------------------------------------------------------
// Streaming copy (thin-frontend-shared-core Phase 2) — the core-framed TSV COPY
// JOB (api/lesssheet.h "STREAMING COPY EXTENSION"). Poll/control lane; COPIES
// into the caller buffer (no borrow); the job holds no background thread.
//
// The job is a pull-model cursor over the caller's ls_copy_next calls: it sweeps
// the rect ROW-MAJOR, reading each cell LOSSLESSLY through window.cellCopy (the
// SAME primitive ls_cell_copy exposes, so the framing rides its forward COPY
// CURSOR — O(1) per row-major step, no per-cell re-location, which is what kills
// the ~80 s/100k-row stall), frames the TSV into a reused `pending` buffer
// (TAB/LF separators, spreadsheet quoting, the single-cell raw special-case —
// BYTE-IDENTICAL to the deleted TSVCopyBuilder), and hands the caller ≤ buf_len
// bytes per pull. A chunk ends at a field/row boundary except a single field
// longer than buf_len, which splits across pulls at a UTF-8 code-point boundary.
// A row at/beyond the frontier yields STALLED (nothing written; the caller jumps
// to stalled_row and retries). d.copy_cap_cells (0 == api.copy_max_cells) is the
// LS_COPY_MAX_CELLS safety cap reported via budget_capped on DONE.
// ---------------------------------------------------------------------------

/// Transcode-expansion bound on ONE cell's lossless output: a row's SOURCE is
/// capped at window_row_scan_max_bytes; the worst-case transcode (Latin-1 high
/// bytes double) expands it 2x. Sizing the per-cell scratch to this means a
/// window.cellCopy truncation flag can ONLY mean the genuine oversized-row source
/// cap (never a too-small buffer), so the served bytes match ls_cell_copy's own
/// bounded prefix exactly (the framing is byte-identical to reading the cell
/// through ls_cell_copy with an ~unbounded buffer).
const copy_cell_output_max: usize = 2 * @as(usize, api.window_row_scan_max_bytes) + 8;

const StreamCopyJob = struct {
    gpa: std.mem.Allocator,
    doc: *Document,
    rect: api.CopyRect,

    // Framing invariants captured at open (the rect never changes mid-job).
    single_cell: bool, // 1x1 rect -> raw, no quoting, no separators
    empty_job: bool, // empty / out-of-range rect -> DONE with 0 bytes, no sweep
    cap: u64, // LS_COPY_MAX_CELLS, or the copy_cap_cells test override

    // Sweep position within the selection.
    sel_row: u64 = 0, // next selection row (0..rect.row_count)
    sel_col: u32 = 0, // next column within the current row (0..rect.col_count)
    rows_done: u64 = 0, // selection rows fully framed (monotone)
    cells_done: u64 = 0, // cells framed (for the cap)
    budget_capped: bool = false,
    done: bool = false,

    // Framed-but-not-yet-delivered TSV bytes. Reused across cells; only a field
    // longer than one buf_len leaves a residual across ls_copy_next calls.
    pending: std.ArrayList(u8) = .empty,
    pending_off: usize = 0,

    // Grow-only scratch for one cell's lossless decode (grown to at most
    // copy_cell_output_max). Reused across every cell of the sweep.
    scratch: []u8 = &.{},

    fn progress(self: *StreamCopyJob, step: api.CopyStep, written: usize, stalled_row: u64) api.CopyProgress {
        return .{
            .step = step,
            .written = written,
            .rows_done = self.rows_done,
            .stalled_row = stalled_row,
            .budget_capped = if (step == .done) self.budget_capped else false,
        };
    }

    /// Read cell (view_row, phys_col) LOSSLESSLY into `self.scratch`, growing the
    /// scratch (grow-only, reused) until the cell fits or the oversized-row source
    /// cap is hit. Returns window.cellCopy's result verdict; on `.ok`, `out_len`
    /// is the served byte count (a bounded prefix only for a genuinely oversized
    /// row). OOM is reported as `.no_cell` (the sweep then stops — defensive).
    fn readCell(self: *StreamCopyJob, view_row: u64, phys_col: u32, out_len: *usize) api.CopyResult {
        out_len.* = 0;
        var cap: usize = if (self.scratch.len == 0) @min(64 * 1024, copy_cell_output_max) else self.scratch.len;
        while (true) {
            self.ensureScratch(cap) catch return .no_cell;
            var ol: usize = 0;
            var tr: bool = false;
            const res = window.cellCopy(self.doc, view_row, phys_col, self.scratch.ptr, self.scratch.len, &ol, &tr);
            if (res != .ok) return res;
            // Full cell, or the buffer already spans the source-cap bound -> the
            // truncation (if any) is the genuine oversized-row prefix: accept it.
            if (!tr or self.scratch.len >= copy_cell_output_max) {
                out_len.* = ol;
                return .ok;
            }
            cap = @min(self.scratch.len * 2, copy_cell_output_max);
        }
    }

    fn ensureScratch(self: *StreamCopyJob, n: usize) !void {
        if (self.scratch.len >= n) return;
        self.scratch = if (self.scratch.len == 0)
            try self.gpa.alloc(u8, n)
        else
            try self.gpa.realloc(self.scratch, n);
    }

    /// Frame ONE cell (the separator that precedes it, then the raw/quoted
    /// content) into `pending`, byte-identical to TSVCopyBuilder. Precondition:
    /// `pending` is empty. The separator depends on the CURRENT sel_row/sel_col
    /// (computed before the caller advances): the very first cell gets none, a
    /// new row (sel_col == 0) gets LF, otherwise TAB.
    fn frameCell(self: *StreamCopyJob, bytes: []const u8) !void {
        if (!(self.sel_row == 0 and self.sel_col == 0)) {
            try self.pending.append(self.gpa, if (self.sel_col == 0) '\n' else '\t');
        }
        if (self.single_cell) {
            try self.pending.appendSlice(self.gpa, bytes); // raw, never quoted
        } else if (needsQuoting(bytes)) {
            try self.pending.append(self.gpa, '"');
            for (bytes) |b| {
                try self.pending.append(self.gpa, b);
                if (b == '"') try self.pending.append(self.gpa, '"');
            }
            try self.pending.append(self.gpa, '"');
        } else {
            try self.pending.appendSlice(self.gpa, bytes);
        }
    }
};

/// Spreadsheet quoting trigger, byte-exact (TAB/CR/LF/quote are single-byte
/// ASCII; a UTF-8 continuation byte is always >= 0x80, so a raw byte scan is
/// exact) — mirrors TSVCopyBuilder.needsQuoting.
fn needsQuoting(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b == '\t' or b == '\r' or b == '\n' or b == '"') return true;
    }
    return false;
}

/// Largest cut <= `take` of `buf[start..]` that does not split a UTF-8 code
/// point: retreat off a continuation byte (0x80..0xBF) at the cut position. Only
/// meaningful for a PARTIAL cut (start + take < buf.len); returns `take`
/// unchanged for a full delivery.
fn codePointCut(buf: []const u8, start: usize, take: usize) usize {
    var t = take;
    while (t > 0 and (start + t) < buf.len and (buf[start + t] & 0xC0) == 0x80) : (t -= 1) {}
    return t;
}

/// See api/lesssheet.h `ls_copy_open`. Validates the rect synchronously (an
/// empty / out-of-range column range becomes a valid job that steps DONE with 0
/// bytes); returns a handle immediately (no scan, no file read), or null only on
/// handle-alloc failure. `rect` is copied; the caller keeps ownership.
pub export fn ls_copy_open(doc: *const api.Doc, rect: *const api.CopyRect) callconv(.c) ?*api.CopyJob {
    const d = asDocMut(doc);
    const r = rect.*;
    // Out-of-range column range or an empty rect -> nothing to serialize.
    const col_end: u64 = @as(u64, r.first_col) + r.col_count;
    const empty = r.row_count == 0 or r.col_count == 0 or
        d.column_count == 0 or col_end > d.column_count;
    const job = d.gpa.create(StreamCopyJob) catch return null;
    job.* = .{
        .gpa = d.gpa,
        .doc = d,
        .rect = r,
        .single_cell = (r.row_count == 1 and r.col_count == 1) and !empty,
        .empty_job = empty,
        .cap = if (d.copy_cap_cells != 0) d.copy_cap_cells else api.copy_max_cells,
    };
    return @ptrCast(job);
}

/// See api/lesssheet.h `ls_copy_next`. Frames the next TSV chunk into the
/// caller's buffer and returns progress. Pull-model row-major sweep over
/// window.cellCopy (rides its forward COPY CURSOR); COPIES into `buf` (no
/// borrow). See StreamCopyJob for the framing/boundary/STALLED model.
pub export fn ls_copy_next(job: *api.CopyJob, buf: ?[*]u8, buf_len: usize) callconv(.c) api.CopyProgress {
    const self: *StreamCopyJob = @ptrCast(@alignCast(job));
    if (self.done or self.empty_job) {
        self.done = true;
        return self.progress(.done, 0, 0);
    }
    const out: [*]u8 = buf orelse undefined; // buf may be null only when buf_len == 0
    var written: usize = 0;
    while (true) {
        // (1) Drain any framed-but-undelivered bytes first.
        const avail = self.pending.items.len - self.pending_off;
        if (avail > 0) {
            const room = buf_len - written;
            if (room == 0) return self.progress(.more, written, 0);
            if (avail <= room) {
                // Whole remaining field/row fits: deliver it, clear, keep going.
                @memcpy(out[written .. written + avail], self.pending.items[self.pending_off .. self.pending_off + avail]);
                written += avail;
                self.pending.clearRetainingCapacity();
                self.pending_off = 0;
                continue;
            }
            if (self.pending_off == 0 and written > 0) {
                // A FRESH whole cell that does not fully fit AND we already have
                // bytes this chunk: end the chunk at the previous field boundary,
                // keep the cell in `pending` for the next pull (contract: cut at a
                // field boundary except a field longer than buf_len).
                return self.progress(.more, written, 0);
            }
            // Split a field longer than the buffer at a UTF-8 code-point boundary
            // (either mid-field already, or a fresh cell alone bigger than buf_len).
            var take = codePointCut(self.pending.items, self.pending_off, room);
            if (take == 0) take = room; // buf_len smaller than one code point: force progress
            @memcpy(out[written .. written + take], self.pending.items[self.pending_off .. self.pending_off + take]);
            written += take;
            self.pending_off += take;
            return self.progress(.more, written, 0);
        }
        // (2) pending is empty: finish or produce the next cell.
        if (self.sel_row >= self.rect.row_count) {
            self.done = true;
            return self.progress(.done, written, 0);
        }
        if (self.cells_done >= self.cap) {
            self.done = true;
            self.budget_capped = true;
            return self.progress(.done, written, 0);
        }
        if (written == buf_len) return self.progress(.more, written, 0); // buffer full; frame next pull
        const view_row = self.rect.first_row + self.sel_row;
        const phys_col = self.rect.first_col + self.sel_col;
        var cell_len: usize = 0;
        switch (self.readCell(view_row, phys_col, &cell_len)) {
            .ok => {
                self.frameCell(self.scratch[0..cell_len]) catch {
                    self.done = true;
                    return self.progress(.done, written, 0);
                };
                self.cells_done += 1;
                self.sel_col += 1;
                if (self.sel_col == self.rect.col_count) {
                    self.sel_col = 0;
                    self.sel_row += 1;
                    self.rows_done += 1;
                }
                continue; // loop to deliver the freshly framed cell
            },
            .pending => {
                // The next row is at/beyond the frontier. If this pull already
                // delivered bytes, hand them over now (MORE); the caller's next
                // pull hits this same row again and gets a clean STALLED.
                if (written > 0) return self.progress(.more, written, 0);
                return self.progress(.stalled, 0, view_row);
            },
            .no_cell => {
                // Row past an EXACT row count (a rect clamped to the extent never
                // reaches here) -> nothing more to serialize.
                self.done = true;
                return self.progress(.done, written, 0);
            },
        }
    }
}

/// See api/lesssheet.h `ls_copy_close`. Frees the job + its buffers (call exactly
/// once). The job holds no background thread, so there is nothing to join;
/// cancel is "stop calling ls_copy_next, then ls_copy_close".
pub export fn ls_copy_close(job: *api.CopyJob) callconv(.c) void {
    const self: *StreamCopyJob = @ptrCast(@alignCast(job));
    self.pending.deinit(self.gpa);
    if (self.scratch.len > 0) self.gpa.free(self.scratch);
    self.gpa.destroy(self);
}

/// See contracts/api.zig `copyCapCellsForTest`. Zig-only test seam (NOT the C
/// ABI): force the per-job cell SAFETY CAP (0 == the natural api.copy_max_cells)
/// so the budget_capped path is testable without a 10M-cell fixture.
pub fn copyCapCellsForTest(doc: *api.Doc, cells: u64) void {
    asDocMut(doc).copy_cap_cells = cells;
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

// --- gz-filter-stream regression seams (Zig-only; NOT the C ABI) ---------
// Cumulative inflate WORK the gzip Source did for this document since the last
// gzInflateWorkReset: bytes produced, and produce() invocations. A streaming
// trailing scan is O(logical) bytes in O(logical/chunk) ops; the shipped
// livelocking trailing scan spins produce() without bound (ops -> infinity,
// bytes plateau). Both 0 on the mmap fast path. WIRED in the seed (source.zig),
// so the gzfs_* tests MEASURE the real defect.

/// See contracts/api.zig `gzInflatedBytes`.
pub fn gzInflatedBytes(doc: *const api.Doc) u64 {
    const d = asDoc(doc);
    if (d.source == .gzip) return d.source.gzip.inflated_total.load(.monotonic);
    return 0;
}
/// See contracts/api.zig `gzInflateOps`.
pub fn gzInflateOps(doc: *const api.Doc) u64 {
    const d = asDoc(doc);
    if (d.source == .gzip) return d.source.gzip.inflate_ops.load(.monotonic);
    return 0;
}
/// See contracts/api.zig `gzInflateWorkReset`.
pub fn gzInflateWorkReset(doc: *api.Doc) void {
    const d = asDocMut(doc);
    if (d.source == .gzip) {
        d.source.gzip.inflated_total.store(0, .monotonic);
        d.source.gzip.inflate_ops.store(0, .monotonic);
    }
}

// --- gz-filter-stream: deterministic single-threaded scan driver (TEST-ONLY;
// NOT the C ABI). The frozen gzfs_*_multiblock regression tests drive a gzip
// FILTER/SEARCH match-scan ONE 2048-row block at a time on the CALLING thread,
// with the background worker PARKED (gzScanParkWorker), so they can interleave
// behind-frontier ls_window_set/ls_cell_copy work between blocks and assert the
// document-owned replay lane keeps STREAMING (bounded inflate work) instead of
// re-inflating a 32 MiB checkpoint interval per perturbed block. Each step runs
// the EXACT chunk+commit the worker's do_search/do_filter branches run (see
// index.workerMain), only on the test thread -- exercising the production
// retention path (base.beginMatchScan) identically, with no wall-clock races.

/// See contracts/api.zig `gzScanParkWorker`.
pub fn gzScanParkWorker(doc: *api.Doc, parked: bool) void {
    asDocMut(doc).scan_park.store(parked, .release);
}

/// See contracts/api.zig `gzScanStep`.
pub fn gzScanStep(doc: *api.Doc) api.GzScanStep {
    const d = asDocMut(doc);
    d.lock();
    if (d.search_state == .scanning) {
        if (d.search_gen != d.w_gen) {
            if (search.refreshWorkerCtx(d)) d.w_gen = d.search_gen else search.failSearchLocked(d);
        }
        const filtered = d.filter_state != .idle;
        if (filtered and d.filter_gen != d.wf_gen) {
            if (filter.refreshFilterWorkerCtx(d)) d.wf_gen = d.filter_gen else search.failSearchLocked(d);
        }
        if (d.search_state == .scanning) {
            const gen = d.search_gen;
            const start_pos = d.search_pos;
            const start_row = d.search_rows;
            d.unlock();
            const res = search.searchScanChunk(d, start_pos, start_row, filtered, gen);
            d.lock();
            if (d.search_gen == gen and d.search_state == .scanning) {
                search.commitSearch(d, res, filtered);
                search.resolveNavLocked(d);
                if (d.search_state == .scanning and !d.search_to_eof and !d.nav_pending) d.search_state = .cancelled;
            }
        }
        const st = d.search_state;
        d.unlock();
        return if (st == .scanning) .scanning else .done;
    }
    if (d.filter_state == .scanning) {
        if (d.filter_gen != d.wf_gen) {
            if (filter.refreshFilterWorkerCtx(d)) d.wf_gen = d.filter_gen else filter.failFilterLocked(d);
        }
        if (d.filter_state == .scanning) {
            const gen = d.filter_gen;
            const start_pos = d.filter_pos;
            const start_row = d.filter_rows;
            d.unlock();
            const res = filter.filterScanChunk(d, start_pos, start_row, gen);
            d.lock();
            if (d.filter_gen == gen and d.filter_state == .scanning) filter.commitFilter(d, res);
        }
        const st = d.filter_state;
        d.unlock();
        return if (st == .scanning) .scanning else .done;
    }
    d.unlock();
    return .idle;
}

/// See contracts/api.zig `gzTouchReplayLane`. Model one behind-frontier replay
/// cursor (an ls_window_set / ls_cell_copy / nav read at a trailing row): grab a
/// replay lane at `logical` via the SAME primitive a trailing read uses
/// (source.scanCursorAt), force it to serve a byte there (repositioning that
/// lane's inflater session), then release. Interleaved between scan blocks it
/// perturbs the OTHER replay lane; the whole-job-retained scan lane is
/// untouched, but a per-block-leased scan re-grabs the repositioned lane and
/// must re-inflate a checkpoint interval.
pub fn gzTouchReplayLane(doc: *api.Doc, logical: u64) void {
    const d = asDocMut(doc);
    if (d.source != .gzip) return;
    var cur = source_mod.scanCursorAt(d.source, logical);
    defer cur.deinit();
    _ = cur.peek(4);
}

// ===========================================================================
// window-budget instrumentation seams (ARCH-window-budget). Zig-only test
// instrumentation (NOT the C ABI -- like copyAdvances / gz*), reading DEFAULTED
// base.Document state, so api/lesssheet.h stays BYTE-IDENTICAL (AC1) and a
// document that has not performed source work on the corresponding synchronous
// lane reports zero. Filtered navigation source resolution runs off-main, so its
// synchronous latch remains independent of giant-row length.
// ===========================================================================

/// See contracts/api.zig `windowChargedBytes` (AC2/AC3/AC4/AC8).
pub fn windowChargedBytes(doc: *const api.Doc) u64 {
    return asDoc(doc).window_charged_bytes;
}

/// See contracts/api.zig `navChargedBytes` (AC11/AC12, backlog #6).
pub fn navChargedBytes(doc: *const api.Doc) u64 {
    return asDoc(doc).nav_charged_bytes;
}

// ===========================================================================
// column-config slice (ARCH-column-config) — additive column-metadata C ABI.
// See api/lesssheet.h "COLUMN METADATA EXTENSION". These `export fn`s delegate
// to src/column.zig (implementer-owned); the RED SEED there validates every
// argument and synthesizes generation-0 unknown metadata but stores/publishes
// nothing, so every behavioral column-config AC is RED while conformance
// (layout + signature pins in contracts/api.zig) stays green. api/lesssheet.h
// is APPENDED-to, byte-identical above the extension block (AC1).
// ===========================================================================

const column = @import("column.zig");

/// See api/lesssheet.h `ls_column_inference_request`.
pub export fn ls_column_inference_request(doc: *api.Doc, ids: ?[*]const u32, count: u32) callconv(.c) api.ColumnResult {
    const d: *Document = @ptrCast(@alignCast(doc));
    return column.inferenceRequest(d, ids, count);
}

/// See api/lesssheet.h `ls_column_inference_cancel`.
pub export fn ls_column_inference_cancel(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    column.inferenceCancel(d);
}

/// See api/lesssheet.h `ls_column_metadata_poll`.
pub export fn ls_column_metadata_poll(doc: *const api.Doc, out_status: *api.ColumnInferenceStatus) callconv(.c) api.ColumnResult {
    return column.metadataPoll(asDocMut(doc), out_status);
}

/// See api/lesssheet.h `ls_column_metadata_get_many`.
pub export fn ls_column_metadata_get_many(doc: *const api.Doc, ids: ?[*]const u32, count: u32, out_items: ?[*]api.ColumnMetadata, capacity: u32, out_generation: *u64) callconv(.c) api.ColumnResult {
    return column.metadataGetMany(asDocMut(doc), ids, count, out_items, capacity, out_generation);
}

/// See api/lesssheet.h `ls_column_override_set`.
pub export fn ls_column_override_set(doc: *api.Doc, col: u32, ty: *const api.ColumnType) callconv(.c) api.ColumnResult {
    const d: *Document = @ptrCast(@alignCast(doc));
    return column.overrideSet(d, col, ty);
}

/// See api/lesssheet.h `ls_column_override_clear`.
pub export fn ls_column_override_clear(doc: *api.Doc, col: u32) callconv(.c) api.ColumnResult {
    const d: *Document = @ptrCast(@alignCast(doc));
    return column.overrideClear(d, col);
}

/// See api/lesssheet.h `ls_column_null_sentinel_set`.
pub export fn ls_column_null_sentinel_set(doc: *api.Doc, col: u32, bytes: ?[*]const u8, len: usize) callconv(.c) api.ColumnResult {
    const d: *Document = @ptrCast(@alignCast(doc));
    return column.nullSentinelSet(d, col, bytes, len);
}

/// See api/lesssheet.h `ls_column_null_sentinel_clear`.
pub export fn ls_column_null_sentinel_clear(doc: *api.Doc, col: u32) callconv(.c) api.ColumnResult {
    const d: *Document = @ptrCast(@alignCast(doc));
    return column.nullSentinelClear(d, col);
}

/// See api/lesssheet.h `ls_column_inference_accept_proposal`.
pub export fn ls_column_inference_accept_proposal(doc: *api.Doc, col: u32) callconv(.c) api.ColumnResult {
    const d: *Document = @ptrCast(@alignCast(doc));
    return column.acceptProposal(d, col);
}

/// See api/lesssheet.h `ls_column_labels_copy_many`.
pub export fn ls_column_labels_copy_many(doc: *const api.Doc, ids: ?[*]const u32, count: u32, out_spans: ?[*]api.ColumnLabelSpan, capacity: u32, arena: ?[*]u8, arena_capacity: usize, out_required: *usize) callconv(.c) api.ColumnResult {
    return column.labelsCopyMany(asDocMut(doc), ids, count, out_spans, capacity, arena, arena_capacity, out_required);
}

/// See api/lesssheet.h `ls_column_null_sentinel_copy`.
pub export fn ls_column_null_sentinel_copy(doc: *const api.Doc, col: u32, buf: ?[*]u8, buf_capacity: usize, out_required: *usize) callconv(.c) api.ColumnResult {
    return column.nullSentinelCopy(asDocMut(doc), col, buf, buf_capacity, out_required);
}

/// See api/lesssheet.h `ls_column_conflict_example_copy`.
pub export fn ls_column_conflict_example_copy(doc: *const api.Doc, col: u32, buf: ?[*]u8, buf_capacity: usize, out_required: *usize) callconv(.c) api.ColumnResult {
    return column.conflictExampleCopy(asDocMut(doc), col, buf, buf_capacity, out_required);
}

// ===========================================================================
// network-source slice (ARCH-network-source) — additive network-open C ABI
// (ls_open_url_start / ls_net_open_poll / ls_net_open_cancel /
// ls_net_open_release) + Zig-only test seams. See api/lesssheet.h "NETWORK
// SOURCE EXTENSION" and src/net.zig. The C exports and Zig seams below are the
// FROZEN entry points contracts/api.zig pins as `core.*`; src/net.zig holds the
// job logic (SEED: validates scheme/options, then fails UNREACHABLE — no
// transport wired). The instrumentation seams read DEFAULTED base.Document
// net_* state, so a non-network document reports zero/false and every
// transport-dependent AC is RED until the http_range Source is built + wired.
// api/lesssheet.h is byte-identical above its appended block (AC2).
// ===========================================================================

const net = @import("net.zig");

/// See api/lesssheet.h `ls_open_url_start`. Returns NULL only on handle-alloc
/// failure; an invalid scheme/URL/option is a valid job that polls FAILED with
/// LS_NET_ERROR_INVALID_ARGUMENT (net.startJob).
pub export fn ls_open_url_start(url: [*]const u8, url_len: usize, options: ?*const api.OpenOptions) callconv(.c) ?*api.NetOpenJob {
    const job = net.startJob(default_gpa, url, url_len, options, null) orelse return null;
    return @ptrCast(job);
}

/// See api/lesssheet.h `ls_net_open_poll`. Zero-alloc; total; never blocks.
pub export fn ls_net_open_poll(job: *const api.NetOpenJob) callconv(.c) api.NetOpenStatus {
    return net.poll(@ptrCast(@alignCast(job)));
}

/// See api/lesssheet.h `ls_net_open_cancel`.
pub export fn ls_net_open_cancel(job: *api.NetOpenJob) callconv(.c) void {
    net.cancel(@ptrCast(@alignCast(job)));
}

/// See api/lesssheet.h `ls_net_open_release`.
pub export fn ls_net_open_release(job: *api.NetOpenJob) callconv(.c) void {
    net.release(@ptrCast(@alignCast(job)));
}

// --- Zig-only test seams (NOT the C ABI — like openWithAllocator / gz*), so
// api/lesssheet.h stays BYTE-IDENTICAL. See contracts/api.zig for each. --------

/// See contracts/api.zig `openUrlStartFake`: the injected-transport twin of
/// ls_open_url_start (production uses std.http.Client; tests describe the
/// transport with a NetFixture). SEED: ignores the fixture, fails UNREACHABLE.
pub fn openUrlStartFake(fixture: *const api.NetFixture, url: [*]const u8, url_len: usize, options: ?*const api.OpenOptions) ?*api.NetOpenJob {
    const job = net.startJob(default_gpa, url, url_len, options, fixture) orelse return null;
    return @ptrCast(job);
}

/// See contracts/api.zig `netRangeMode` (AC3/AC4).
pub fn netRangeMode(doc: *const api.Doc) api.NetRangeMode {
    return @enumFromInt(asDoc(doc).net_range_mode);
}
/// See contracts/api.zig `netFetchCount` (AC6/AC13). Reads live off the
/// http_range provider (whether the Source IS the http_range or a gzip composed
/// over it, TD4); a non-network document reports 0.
pub fn netFetchCount(doc: *const api.Doc) u64 {
    const d = asDoc(doc);
    if (source_mod.netProviderOf(d.source)) |hr| {
        hr.lock();
        defer hr.unlock();
        return hr.fetch_count;
    }
    return d.net_fetch_count;
}
/// See contracts/api.zig `netResidentBytes` (AC15).
pub fn netResidentBytes(doc: *const api.Doc) u64 {
    const d = asDoc(doc);
    if (source_mod.netProviderOf(d.source)) |hr| {
        hr.lock();
        defer hr.unlock();
        return hr.resident_bytes;
    }
    return d.net_resident_bytes;
}
/// See contracts/api.zig `netSpoolStore` (AC14).
pub fn netSpoolStore(doc: *const api.Doc) api.NetSpoolStore {
    const d = asDoc(doc);
    if (source_mod.netProviderOf(d.source)) |hr| {
        hr.lock();
        defer hr.unlock();
        return .{ .present = hr.spool_fd != null, .bytes = hr.spool_bytes, .mode = if (hr.spool_fd != null) 0o600 else 0, .unlinked = hr.spool_fd != null };
    }
    return .{ .present = d.net_spool_present, .bytes = d.net_spool_bytes, .mode = d.net_spool_mode, .unlinked = d.net_spool_unlinked };
}
/// See contracts/api.zig `netForceCacheBytes` (AC6).
pub fn netForceCacheBytes(doc: *api.Doc, n: u64) void {
    const d = asDocMut(doc);
    if (source_mod.netProviderOf(d.source)) |hr| {
        hr.setCacheCap(n);
        return;
    }
    d.net_force_cache_bytes = n;
}
/// See contracts/api.zig `netJobProbe` (AC8).
pub fn netJobProbe(job: *const api.NetOpenJob) api.NetJobProbe {
    return net.jobProbe(@ptrCast(@alignCast(job)));
}

/// See contracts/api.zig `decideProbe` / `parseContentRangeTotal`
/// (never-full-download-streaming AC17 unit seams). Re-exported from
/// net_source so the pure probe classification is unit-testable without a
/// live HTTP server.
pub const decideProbe = net_source.decideProbe;
pub const parseContentRangeTotal = net_source.parseContentRangeTotal;
