//! Shared document state: the `Document` aggregate, the small value types its
//! fields embed (`CellRef`, `Checkpoint`, `MatchCtx`, `Decimal`), the
//! api.Doc<->Document casts, and the cross-module tunables. Every other
//! sibling module builds on this one; this module imports no siblings (see
//! src/root.zig's module-boundary note).

const std = @import("std");
const api = @import("api");

const posix = std.posix;
const c = std.c;

// --- Tunables shared across modules (implementation detail; not ABI) -------

/// One index checkpoint every this many data rows (binary-searched by
/// window_set / jump). Bounds index memory to O(rows / interval) and the
/// re-lex distance of any window to O(interval + window).
pub const checkpoint_interval: u64 = 2048;

pub const head_budget: u64 = api.open_head_max_bytes;

// --- Small value types ------------------------------------------------------

/// A decoded cell: byte range into an owning buffer (window or header).
/// `truncated` is set when LS_CELL_MAX_BYTES cut the cell's stored bytes, or
/// when a bounded record-1 decode stopped mid-field (see `lexInto`).
pub const CellRef = struct { start: usize, len: usize, truncated: bool = false };

/// A sparse row-index entry: data row `row` begins at content offset `offset`.
pub const Checkpoint = struct { row: u64, offset: u64 };

/// A resolved request, evaluated against a decoded record. Built from the
/// document under the lock (nav) or from the worker's lock-free snapshot (scan).
pub const MatchCtx = struct {
    kind: api.SearchKind = .text,
    op: api.SearchOp = .eq,
    column: u32 = 0,
    fold: bool = false, // TEXT: fold ASCII case (all-lowercase query)
    value: []const u8 = &.{},
    value_dec: Decimal = .{}, // pre-parsed value (ordering predicates)
    scope_mask: []const bool = &.{}, // empty == all columns; else len == column_count
    column_count: u32 = 0,
};

// ---------------------------------------------------------------------------
// EXACT decimal comparison (mathematical value; never through f64). The
// struct shape lives here (a Document field type); parse/compare logic is in
// matcher.zig — see it for the pinned grammar and comparison rules.
// ---------------------------------------------------------------------------

pub const Decimal = struct {
    valid: bool = false,
    negative: bool = false,
    zero: bool = false,
    /// Integer digits (may carry leading zeros) and fraction digits, borrowed
    /// from the parsed input; logically concatenated as the digit sequence.
    int_part: []const u8 = &.{},
    frac_part: []const u8 = &.{},
    /// Index (into int_part ++ frac_part) of the most-significant NONZERO digit.
    first: usize = 0,
    /// Count of significant digits (leading + trailing zeros stripped).
    sig_len: usize = 0,
    /// Base-10 exponent of the most-significant significant digit.
    msd_pos: i64 = 0,

    pub fn digitAt(self: Decimal, k: usize) u8 {
        return if (k < self.int_part.len) self.int_part[k] else self.frac_part[k - self.int_part.len];
    }
    pub fn sigDigit(self: Decimal, i: usize) u8 {
        return self.digitAt(self.first + i);
    }
};

// --- The document -----------------------------------------------------------

pub const Document = struct {
    gpa: std.mem.Allocator,

    // File mapping (immutable after open). `mapping` is null for an empty file.
    mapping: ?[]align(std.heap.page_size_min) const u8,
    content: []const u8, // mapping[bom_len..] (post-BOM SOURCE bytes; NOT UTF-8
    // unless `encoding` is UTF-8 -- every scan decodes it through `decodeUnit`)
    content_len: u64,
    file_size: u64,
    bom_len: u64,
    // The resolved source encoding (see TEXT AND ENCODING). Constant for the
    // document's lifetime; drives every `decodeUnit` call site (head scan,
    // background index, jump/search scans, window materialization).
    encoding: u8,

    // Dialect + shape (immutable after open).
    sep: u8,
    quote: ?u8, // null == quoting disabled (NONE)
    dialect: api.Dialect,
    column_count: u32,
    data_start: u64, // content offset of data row 0
    auto: bool,

    // Header cells (immutable after open; never evicted).
    has_header: bool,
    header_buf: []const u8,
    header_refs: []const CellRef,

    // BOUNDED RECORD 1 (see api/lesssheet.h DELIMITED-TEXT / requirement 9):
    // true iff record 1 did not terminate within the O(head) budget.
    // `row0_pinned_*` holds record 1's bounded decode when it is ALSO data
    // row 0 (header off): served by ls_cell/ls_window_set directly, bypassing
    // the frontier (which never claims a row whose true extent past the
    // budget is unknown) -- so row 0 stays instantly servable without ever
    // re-scanning the pathological record. Empty/unused otherwise.
    record1_capped: bool,
    row0_pinned_buf: []const u8,
    row0_pinned_refs: []const CellRef,

    // Frontier + index + jump slot (mutex-protected).
    mutex: c.pthread_mutex_t,
    cond: c.pthread_cond_t,
    checkpoints: std.ArrayList(Checkpoint),
    frontier_rows: u64,
    frontier_offset: u64,
    complete: bool,
    total_rows: u64,
    jump_state: api.JumpState,
    jump_target: u64,
    jump_start_rows: u64,
    jump_progress: f64,
    jump_landed: u64,

    // Search job + navigation slot (mutex-protected). All fields zero ==
    // LS_SEARCH_IDLE. See api/lesssheet.h SEARCH for the full model.
    search_state: api.SearchState,
    search_nav: api.SearchNavState,
    search_progress: f64,
    search_found_row: u64,
    search_found_col: u32,
    search_position: u64,
    search_total: u64,
    search_total_exact: bool,
    // Match-scan cursor: rows [0, search_rows) are counted (contiguous from 0);
    // search_offset is the content offset of the next data row to evaluate.
    search_offset: u64,
    search_rows: u64,
    search_to_eof: bool, // scan goal: full sweep to EOF (vs nav-limited resume)
    // Generation: bumped by every ls_search_start so an in-flight worker chunk
    // of a replaced search is discarded on commit (no stale counts / no UAF of
    // the request buffers the worker snapshots lock-free).
    search_gen: u64,
    // Pending navigation (mutex-protected).
    nav_pending: bool,
    nav_anchor: u64,
    nav_dir: api.SearchDir,
    // Active request (owned; set by ls_search_start).
    search_kind: api.SearchKind,
    search_op: api.SearchOp,
    search_column: u32,
    search_value: []u8, // owned query / comparison bytes
    search_value_dec: Decimal, // pre-parsed value (ordering predicates)
    search_fold: bool, // TEXT smart-case: fold ASCII case (all-lowercase query)
    scope_mask: []bool, // owned; empty == all columns (NULL scope); else len == column_count
    // Per-index-block match counters (owned): block b == rows
    // [b*checkpoint_interval, (b+1)*checkpoint_interval); O(checkpoints) always.
    block_counts: std.ArrayList(u64),
    // Worker match-scan scratch + request snapshot (worker-only; lock-free
    // during a chunk). Refreshed under the lock when search_gen changes.
    search_scratch: std.ArrayList(u8),
    search_refs: std.ArrayList(CellRef),
    w_value: std.ArrayList(u8),
    w_mask: std.ArrayList(bool),
    w_ctx: MatchCtx,
    w_gen: u64,
    // Nav-resolution scratch (only touched while holding the mutex).
    nav_scratch: std.ArrayList(u8),
    nav_refs: std.ArrayList(CellRef),

    // Filter (filtered-views slice) — a persistent VIEW MODE, not a transient
    // job: it PERSISTS (scanning/done/cancelled) until cleared or re-opened,
    // regardless of scan-slot contention (see api/lesssheet.h FILTERED VIEWS).
    // Mirrors the search job's per-block counting machinery with its OWN
    // predicate, cursor, and counters — never a materialized match-row list.
    filter_state: api.FilterState,
    filter_progress: f64,
    filter_total: u64,
    filter_total_exact: bool,
    // Filter-scan cursor: rows [0, filter_rows) are counted (contiguous from
    // row 0); filter_offset is the content offset of the next row to evaluate.
    filter_offset: u64,
    filter_rows: u64,
    // Generation: bumped by every ls_filter_set so a stale in-flight worker
    // chunk of a replaced filter is discarded on commit.
    filter_gen: u64,
    // Active filter request (owned; same shape as the search request fields).
    filter_kind: api.SearchKind,
    filter_op: api.SearchOp,
    filter_column: u32,
    filter_value: []u8,
    filter_value_dec: Decimal,
    filter_fold: bool,
    filter_scope_mask: []bool,
    // Per-index-block filter-match counters (owned): O(checkpoints) always,
    // aligned 1:1 with `checkpoints`, exactly like the search job's block_counts.
    filter_block_counts: std.ArrayList(u64),
    // Worker match-scan scratch + request snapshot (worker-only; lock-free
    // during a chunk; refreshed under the lock when filter_gen changes). Also
    // the lock-free snapshot a concurrent SEARCH chunk composes against while
    // filtered (see searchRowMatch).
    filter_scratch: std.ArrayList(u8),
    filter_refs: std.ArrayList(CellRef),
    wf_value: std.ArrayList(u8),
    wf_mask: std.ArrayList(bool),
    wf_ctx: MatchCtx,
    wf_gen: u64,

    // Worker control.
    worker: ?std.Thread,
    stop: bool,
    stop_atomic: std.atomic.Value(bool),

    // Materialized window (window lane only; no lock). win_source[i] is the
    // ORIGINAL data-row number of materialized row win_first+i (identity when
    // no filter is active; see ls_source_row / FILTERED VIEWS).
    win_buf: std.ArrayList(u8),
    win_refs: std.ArrayList(CellRef),
    win_source: std.ArrayList(u64),
    win_first: u64,
    win_rows: u64,

    pub fn lock(self: *Document) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    pub fn unlock(self: *Document) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    pub fn wakeWorker(self: *Document) void {
        _ = c.pthread_cond_broadcast(&self.cond);
    }
    pub fn waitWork(self: *Document) void {
        _ = c.pthread_cond_wait(&self.cond, &self.mutex);
    }
};

pub fn asDoc(doc: *const api.Doc) *const Document {
    return @ptrCast(@alignCast(doc));
}

/// The document behind a handle is always in mutable memory; the `*const`
/// ABI parameter is advisory. Poll/control-lane calls take the mutex through
/// this so they see consistent frontier snapshots.
pub fn asDocMut(doc: *const api.Doc) *Document {
    return @ptrCast(@alignCast(@constCast(doc)));
}

/// Release all document storage. The worker is already joined (ls_close) or
/// was never spawned (open failure), so the sync primitives are quiescent and
/// safe to destroy.
pub fn freeDoc(doc: *Document) void {
    doc.checkpoints.deinit(doc.gpa);
    doc.win_buf.deinit(doc.gpa);
    doc.win_refs.deinit(doc.gpa);
    doc.win_source.deinit(doc.gpa);
    doc.block_counts.deinit(doc.gpa);
    doc.search_scratch.deinit(doc.gpa);
    doc.search_refs.deinit(doc.gpa);
    doc.w_value.deinit(doc.gpa);
    doc.w_mask.deinit(doc.gpa);
    doc.nav_scratch.deinit(doc.gpa);
    doc.nav_refs.deinit(doc.gpa);
    doc.filter_block_counts.deinit(doc.gpa);
    doc.filter_scratch.deinit(doc.gpa);
    doc.filter_refs.deinit(doc.gpa);
    doc.wf_value.deinit(doc.gpa);
    doc.wf_mask.deinit(doc.gpa);
    if (doc.search_value.len > 0) doc.gpa.free(doc.search_value);
    if (doc.scope_mask.len > 0) doc.gpa.free(doc.scope_mask);
    if (doc.filter_value.len > 0) doc.gpa.free(doc.filter_value);
    if (doc.filter_scope_mask.len > 0) doc.gpa.free(doc.filter_scope_mask);
    if (doc.header_buf.len > 0) doc.gpa.free(doc.header_buf);
    if (doc.header_refs.len > 0) doc.gpa.free(doc.header_refs);
    if (doc.row0_pinned_buf.len > 0) doc.gpa.free(doc.row0_pinned_buf);
    if (doc.row0_pinned_refs.len > 0) doc.gpa.free(doc.row0_pinned_refs);
    if (doc.mapping) |m| posix.munmap(m);
    _ = c.pthread_cond_destroy(&doc.cond);
    _ = c.pthread_mutex_destroy(&doc.mutex);
    doc.gpa.destroy(doc);
}

/// Fraction of the data region covered by content offset `off`, clamped to
/// 1.0. Shared progress calculation for the search match-scan and the filter
/// scan (both report progress over the same [data_start, content_len) span).
pub fn searchProgress(doc: *Document, off: u64) f64 {
    if (doc.content_len <= doc.data_start) return 1.0;
    const span = doc.content_len - doc.data_start;
    const covered = off - doc.data_start;
    const p = @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(span));
    return if (p > 1.0) 1.0 else p;
}
