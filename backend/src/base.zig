//! Shared document state: the `Document` aggregate, the small value types its
//! fields embed (`CellRef`, `Checkpoint`, `OversizedMatch`, `MatchCtx`,
//! `Decimal`), the api.Doc<->Document casts, and the cross-module tunables.
//! Every sibling module that touches parsing builds on this one PLUS the
//! Reader/Source seam (src/reader.zig, src/source.zig — see docs/
//! architecture/ARCH-reader-interface.md): `Document` holds a `Reader` (+ a
//! `Source`) instead of raw content/dialect fields, so window/index/nav/
//! search/filter never import `lexer.zig` directly (see src/root.zig's
//! module-boundary note).

const std = @import("std");
const api = @import("api");
const reader_mod = @import("reader.zig");
const source_mod = @import("source.zig");

const posix = std.posix;
const c = std.c;

/// Re-exported so sibling modules can keep writing `base.Pos` (matching how
/// they already reference `base.CellRef`/`base.Checkpoint`) without a
/// separate import of reader.zig. See reader.zig's module doc for what
/// "opaque" means here.
pub const Pos = reader_mod.Pos;
const Source = source_mod.Source;
const Reader = reader_mod.Reader;

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

/// A sparse row-index entry: data row `row` begins at (opaque) position `pos`.
pub const Checkpoint = struct { row: u64, pos: Pos };

/// ARCH-huge-row-filtered: the FULL-cell filter-match result the background
/// filter-scan already decided for OVERSIZED row `row` (source extent >
/// LS_WINDOW_ROW_SCAN_MAX_BYTES) — see filter.filterScanChunk and Document's
/// `filter_oversized_matches`. Lets the FILTERED window path (window.
/// windowSetFiltered / nav.nthMatchInBlock) honor that already-decided FULL-
/// cell match without re-scanning the row. Backend-internal only — never
/// crosses the ABI.
pub const OversizedMatch = struct { row: u64, matched: bool };

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
    failure: []const usize = &.{}, // TEXT KMP prefix table, one entry/query byte
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

/// View discriminant for the copy cursor (ARCH-stream-copy FR4): identity
/// (window.cellCopy) and filtered (window.cellCopyFiltered) occupy disjoint
/// coordinate spaces, so a switch between them must never reuse the other
/// view's cursor state.
pub const CopyView = enum { identity, filtered };

pub const Document = struct {
    gpa: std.mem.Allocator,

    // File mapping (immutable after open). `mapping` is null for an empty file.
    mapping: ?[]align(std.heap.page_size_min) const u8,
    content_len: u64, // == source.len(); cached (see api/lesssheet.h byte-progress fields)
    file_size: u64,
    bom_len: u64,

    // The Reader (+ its Source) this document was opened with -- see
    // docs/architecture/ARCH-reader-interface.md. `source` wraps the mmap'd,
    // post-BOM SOURCE bytes (identity, zero-copy); `reader` is the CSV Reader
    // today, holding the resolved dialect (sep/quote/encoding — see TEXT AND
    // ENCODING) that drove every `decodeUnit` call site (head scan,
    // background index, jump/search scans, window materialization) BEHIND
    // the Reader interface. window/index/nav/search/filter never touch
    // either field's payload directly -- they pass both opaquely into
    // `reader.<op>(source, pos, ...)` calls.
    source: Source,
    reader: Reader,

    // Shape (immutable after open).
    dialect: api.Dialect,
    column_count: u32,
    data_start: Pos, // position of data row 0
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
    // ARCH-huge-row-budget: an extra checkpoint dropped immediately AFTER
    // every row whose source extent exceeded LS_WINDOW_ROW_SCAN_MAX_BYTES
    // (row `r+1` at oversized row `r`'s true end), found by whichever scan
    // (headScan / index's background scanChunk / a search or filter scan)
    // FIRST advances the shared frontier past it. Row-ascending, but NOT
    // aligned to checkpoint_interval like `checkpoints` (nav.zig's block-
    // direct-indexing must not see these) -- nav.zig's bestCheckpoint
    // consults BOTH lists so ls_window_set's skip-from-checkpoint loop (and,
    // under a filter, nav.nthMatchInBlock's) can reach a row after a huge row
    // without re-scanning the huge row's bytes. O(oversized rows), never
    // O(rows): drainOversized's dedup guard keeps exactly one entry per
    // oversized row, never a re-drained duplicate.
    oversized_checkpoints: std.ArrayList(Checkpoint),
    // Lock-free staging area for the ONE scan chunk currently executing (see
    // stageOversized/drainOversized below): never two chunks run concurrently
    // for the same document (a single worker thread, or a degraded caller
    // holding the document mutex throughout its own synchronous loop), so
    // this needs no lock while a chunk runs. The chunk's caller drains it into
    // `oversized_checkpoints` under the mutex at commit time -- mirroring the
    // `search_scratch`-style worker-scratch pattern already used below.
    oversized_stage: std.ArrayList(Checkpoint),
    frontier_rows: u64,
    frontier_pos: Pos,
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
    // search_pos is the position of the next data row to evaluate.
    search_pos: Pos,
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
    search_failure: []usize,
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
    w_failure: std.ArrayList(usize),
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
    // row 0); filter_pos is the position of the next row to evaluate.
    filter_pos: Pos,
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
    filter_failure: []usize,
    filter_scope_mask: []bool,
    // Per-index-block filter-match counters (owned): O(checkpoints) always,
    // aligned 1:1 with `checkpoints`, exactly like the search job's block_counts.
    filter_block_counts: std.ArrayList(u64),
    // ARCH-huge-row-filtered: per-OVERSIZED-row filter-match record (see
    // OversizedMatch) -- lets the FILTERED window path (window.
    // windowSetFiltered / nav.nthMatchInBlock) honor the background filter-
    // scan's FULL-cell match decision for a giant row without re-scanning it.
    // `filter_oversized_stage` is lock-free staging exclusive to the ONE
    // filter-scan chunk currently executing (mirrors `oversized_stage`, but
    // filter-only: no other scan tests the filter predicate). At commit time
    // (filter.commitFilter) it drains into `filter_oversized_matches`, the
    // persistent, FILTER-GENERATION-scoped list (reset in setFilter alongside
    // filter_block_counts) -- UNCONDITIONALLY, since the filter's own counted
    // region always grows on every commit, unlike the shared
    // oversized_checkpoints (gated on which scan first advanced the shared
    // frontier). Row-ascending (the filter-scan's own cursor is monotonic,
    // contiguous, and single-owner, so it can never re-stage or reorder a
    // row). O(oversized rows), never O(rows)/O(matches).
    filter_oversized_stage: std.ArrayList(OversizedMatch),
    filter_oversized_matches: std.ArrayList(OversizedMatch),
    // Worker match-scan scratch + request snapshot (worker-only; lock-free
    // during a chunk; refreshed under the lock when filter_gen changes). Also
    // the lock-free snapshot a concurrent SEARCH chunk composes against while
    // filtered (see searchRowMatch).
    filter_scratch: std.ArrayList(u8),
    filter_refs: std.ArrayList(CellRef),
    wf_value: std.ArrayList(u8),
    wf_mask: std.ArrayList(bool),
    wf_failure: std.ArrayList(usize),
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
    // win_oversized[i] mirrors win_source[i]: true iff materialized row
    // win_first+i's SOURCE extent exceeded LS_WINDOW_ROW_SCAN_MAX_BYTES, so it
    // was served as a bounded prefix (see ls_row_oversized / ARCH-huge-row-
    // budget). Set by windowSet alongside win_refs/win_source.
    win_oversized: std.ArrayList(bool),
    win_first: u64,
    win_rows: u64,

    // --- Copy cursor + test instrumentation (ARCH-stream-copy) --------------
    // The forward, view-scoped COPY CURSOR that accelerates consecutive,
    // monotonically-non-decreasing ls_cell_copy calls (window.cellCopy /
    // window.cellCopyFiltered) to O(1) per row-major step: the implementer adds
    // the cursor state itself here ({ row, pos, view-generation, filtered
    // match-walk state }, reset on open / filter set-clear per FR4). The two
    // fields below are the TEST-ONLY instrumentation seam behind that work
    // (ARCH-stream-copy AC1-AC5), reached ONLY through the Zig-level seams in
    // contracts/api.zig (copyCursorSetEnabled / copyAdvances / copyAdvancesReset,
    // via root.zig) — NEVER across the C ABI. Both are DEFAULTED so the
    // openWithAllocator construction literal need not mention them.
    //
    //   * copy_cursor_enabled — when false the copy path bypasses the cursor and
    //     locates every cell from scratch (today's behavior): the byte-identical
    //     REFERENCE for the AC1/AC2 equivalence sweeps and the interval-costly
    //     BASELINE for the AC3/AC4/AC5 advance counts. Defaults TRUE (production
    //     copies THROUGH the cursor once it lands).
    //   * copy_advances — a monotone count of SOURCE ROW-ADVANCES taken on the
    //     copy path (a boundsAfter skip in cursor-OFF mode; one cursor forward
    //     step in cursor-ON mode), in BOTH the identity and filtered paths.
    //     Reset/read by the test seam; pure instrumentation, irrelevant to the
    //     copied bytes. SEED: never incremented (== 0) — see root.zig's seam
    //     comment for why that makes the AC3/AC4/AC5 counts RED until built.
    //     TEST-ONLY and measured single-threaded (a sweep resets it, then
    //     reads it back once the sweep is done) — the plain, un-guarded `+=`
    //     below is fine as a simple additive aggregate; no reader ever
    //     depends on it being linearizable across concurrent copies.
    copy_cursor_enabled: bool = true,
    copy_advances: u64 = 0,

    // The REAL cursor state (FR1/FR2/FR4), all DEFAULTED so a freshly opened
    // Document (openWithAllocator's literal, unedited) starts with an invalid
    // cursor -- "reset on open" (FR4) falls out for free. `copy_cursor_valid`
    // gates every field below: false means "absent", so window.cellCopy /
    // cellCopyFiltered always re-anchor (FR3). Tagged with the VIEW it was
    // captured under (`copy_cursor_view`) and the `filter_gen` in effect at
    // capture (`copy_cursor_gen`) -- together, FR4's "view identity + filter
    // generation" tag: a view switch (tag mismatch) OR any filter set/clear
    // (filter_gen always bumps -- filter.setFilter/clearFilter -- so even a
    // same-view round-trip back to identity sees a stale gen) invalidates the
    // cursor without an explicit reset call. Positions themselves are never
    // invalidated (stable once scanned, per FR4) -- only the tag is compared.
    // `copy_cursor_row` is the coordinate the cursor last served, in ITS OWN
    // space (identity: physical row; filtered: filtered index);
    // `copy_cursor_pos` the SOURCE position where that row/match begins (a
    // repeat column read costs zero advances: window.zig's forward-advance
    // loops are `while (r < row)`, 0 iterations when `row` is unchanged).
    // `copy_cursor_source_row` is filtered-only: the ORIGINAL/source data-row
    // number of `copy_cursor_row`'s match; `copy_cursor_block_consumed` (also
    // filtered-only) is the 1-based count of matches from THAT row's own
    // per-block-index block start up to and including it -- together they let
    // window.cellCopyFiltered decide in O(1) (one filter_block_counts lookup,
    // no re-lex) whether the next `gap` matches still fit in the SAME block
    // (nav.nthMatchForwardFrom safely resumes, provably no costlier than a
    // fresh block-indexed locate for that row) or spill into a later block
    // (skip the row-walk entirely and go straight to the fresh locate) --
    // never both (ARCH-stream-copy FR3 "never slower than today", for ANY
    // match distribution, not just a dense/monotonic one).
    //
    // Thread-safety: every FIELD READ/WRITE above happens under `d.lock()`,
    // but window.cellCopy drops the lock across its (potentially long) walk
    // between reading the cursor and committing it, so it is NOT a strict
    // read-lock-walk-write-unlock critical section -- two concurrent identity
    // copies are not linearizable against each other. This is memory-safe
    // (no field is ever touched outside the lock) and never changes a
    // returned byte (the commit only affects how fast a LATER call locates
    // its row) -- cellCopy's commit additionally guards against a slower
    // caller's stale commit regressing an already-further-along cursor
    // backwards. window.cellCopyFiltered holds the lock for its entire call
    // (no drop), so it has no such race to begin with.
    copy_cursor_valid: bool = false,
    copy_cursor_view: CopyView = .identity,
    copy_cursor_gen: u64 = 0,
    copy_cursor_row: u64 = 0,
    copy_cursor_pos: Pos = .{ .logical = 0, .physical = 0 },
    copy_cursor_source_row: u64 = 0,
    copy_cursor_block_consumed: u64 = 0,

    // --- csv-gz instrumentation state (ARCH-csv-gz) -------------------------
    // All DEFAULTED (like copy_cursor_* above), so openWithAllocator's literal
    // need not mention them AND a plain-CSV document reports zeros -> the mmap
    // fast path is unaffected (AC20). The implementer sets these as the gzip
    // Source consumes the dual open budget, spills/reads checkpoints, replays a
    // behind-frontier landing, and streaming-matches. In the SEED they stay
    // zero, which is exactly what makes every csv-gz quantitative AC RED (each
    // asserts the counter did REAL work, e.g. `> 0 and <= bound`) -- mirroring
    // stream-copy's `copy_advances == 0` RED seed. Read/reset only via the
    // Zig-level seams in contracts/api.zig (gz* -> root.zig), NEVER the C ABI.
    gz_physical_in: u64 = 0, // AC5/6/7: compressed input consumed at open
    gz_inflated_out: u64 = 0, // AC5/6/7: inflated output produced at open
    gz_replay_landed: bool = false, // AC15: a behind-frontier landing occurred
    gz_replay_restored_logical: u64 = 0, // AC15: restored checkpoint's logical offset
    gz_replay_inflated: u64 = 0, // AC15: inflated bytes replayed for that landing
    gz_resident_bytes: u64 = 0, // AC17: gzip-specific resident state (bound 16 MiB)
    gz_ckpt_present: bool = false, // AC17/21: a checkpoint spill file exists
    gz_ckpt_bytes: u64 = 0, // AC17: its size (bound 0.25% of inflated + overhead)
    gz_ckpt_mode: u32 = 0, // AC17/21: its permission bits (must be 0o600)
    gz_ckpt_unlinked: bool = false, // AC17/21: already unlinked while open
    gz_ckpt_fail_after: u64 = std.math.maxInt(u64), // AC18: inject store failure after N ops
    gz_force_chunk_bytes: u64 = 0, // AC12: force cursor spans to <=N bytes (0 == natural)
    gz_match_resident_bytes: u64 = 0, // AC13: peak per-row matcher residency
    gz_cache_copy_bytes: u64 = 0, // AC20: bytes copied THROUGH a cache (0 for mmap)

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
    source_mod.sourceShutdown(&doc.source);
    doc.checkpoints.deinit(doc.gpa);
    doc.oversized_checkpoints.deinit(doc.gpa);
    doc.oversized_stage.deinit(doc.gpa);
    doc.win_buf.deinit(doc.gpa);
    doc.win_refs.deinit(doc.gpa);
    doc.win_source.deinit(doc.gpa);
    doc.win_oversized.deinit(doc.gpa);
    doc.block_counts.deinit(doc.gpa);
    doc.search_scratch.deinit(doc.gpa);
    doc.search_refs.deinit(doc.gpa);
    doc.w_value.deinit(doc.gpa);
    doc.w_mask.deinit(doc.gpa);
    doc.w_failure.deinit(doc.gpa);
    doc.nav_scratch.deinit(doc.gpa);
    doc.nav_refs.deinit(doc.gpa);
    doc.filter_block_counts.deinit(doc.gpa);
    doc.filter_oversized_stage.deinit(doc.gpa);
    doc.filter_oversized_matches.deinit(doc.gpa);
    doc.filter_scratch.deinit(doc.gpa);
    doc.filter_refs.deinit(doc.gpa);
    doc.wf_value.deinit(doc.gpa);
    doc.wf_mask.deinit(doc.gpa);
    doc.wf_failure.deinit(doc.gpa);
    if (doc.search_value.len > 0) doc.gpa.free(doc.search_value);
    if (doc.scope_mask.len > 0) doc.gpa.free(doc.scope_mask);
    if (doc.search_failure.len > 0) doc.gpa.free(doc.search_failure);
    if (doc.filter_value.len > 0) doc.gpa.free(doc.filter_value);
    if (doc.filter_scope_mask.len > 0) doc.gpa.free(doc.filter_scope_mask);
    if (doc.filter_failure.len > 0) doc.gpa.free(doc.filter_failure);
    if (doc.header_buf.len > 0) doc.gpa.free(doc.header_buf);
    if (doc.header_refs.len > 0) doc.gpa.free(doc.header_refs);
    if (doc.row0_pinned_buf.len > 0) doc.gpa.free(doc.row0_pinned_buf);
    if (doc.row0_pinned_refs.len > 0) doc.gpa.free(doc.row0_pinned_refs);
    source_mod.sourceDeinit(&doc.source);
    if (doc.mapping) |m| posix.munmap(m);
    _ = c.pthread_cond_destroy(&doc.cond);
    _ = c.pthread_mutex_destroy(&doc.mutex);
    doc.gpa.destroy(doc);
}

/// Fraction of the data region covered by position `pos`, clamped to 1.0.
/// Shared progress calculation for the search match-scan and the filter scan
/// (both report progress over the same [data_start, content_len) span).
/// `bytesConsumed` is the ONLY place a position is turned back into a byte
/// count here (see reader.zig's module doc) -- the ABI's progress fields are
/// byte-denominated regardless of Reader.
pub fn searchProgress(doc: *Document, pos: Pos) f64 {
    const start_bytes = doc.reader.physicalBytes(doc.source, doc.data_start);
    if (doc.file_size <= start_bytes) return 1.0;
    const span = doc.file_size - start_bytes;
    const at_bytes = doc.reader.physicalBytes(doc.source, pos);
    const covered = at_bytes -| start_bytes;
    const p = @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(span));
    return if (p > 1.0) 1.0 else p;
}

// ---------------------------------------------------------------------------
// ARCH-huge-row-budget: oversized-row checkpoint staging. Every scan loop
// that may advance the shared frontier past a row's true end (index.zig's
// headScan / scanChunk, search.searchScanChunk, filter.filterScanChunk) calls
// beginOversizedChunk once before its loop and stageOversized per row; the
// loop's caller (already holding the mutex at commit time -- see
// index.workerMain's plain-chunk commit, search.commitSearch,
// filter.commitFilter) calls drainOversized once. nav.zig's
// checkpointAtOrBefore/bestCheckpoint are the only readers of
// `oversized_checkpoints` (always under the mutex; called from window.zig's
// ls_window_set paths and from nav.zig's own nthMatchInBlock).
// ---------------------------------------------------------------------------

/// Reset the lock-free oversized-row staging area (see stageOversized) before
/// a NEW scan chunk begins accumulating into it. Guarantees a clean slate
/// even when a PREVIOUS chunk's drain was skipped (an unrelated OOM guard
/// returning early elsewhere) — a stale entry could otherwise leak into a
/// later, unrelated chunk's drain and break `oversized_checkpoints`'s row-
/// ascending invariant (see drainOversized).
pub fn beginOversizedChunk(doc: *Document) void {
    doc.oversized_stage.clearRetainingCapacity();
}

/// If the record spanning positions [start, end) exceeded the per-row
/// window-scan cap (LS_WINDOW_ROW_SCAN_MAX_BYTES), stage a checkpoint
/// immediately AFTER it (row `row + 1` at position `end`) — see ARCH-huge-row-
/// budget decision 2. Lock-free: exclusive to whichever single chunk is
/// currently executing (never two concurrently for the same document — one
/// worker thread, or a degraded caller holding the document mutex throughout;
/// see `oversized_stage`'s doc comment on Document). A normal-sized row
/// returns before touching anything. `bytesConsumed` is the size test's only
/// look at a position's byte meaning (see reader.zig's module doc); the cap
/// itself is a plain, format-agnostic byte budget pinned by the ABI.
pub fn stageOversized(doc: *Document, row: u64, start: Pos, end: Pos) void {
    const size = doc.reader.bytesConsumed(doc.source, end) - doc.reader.bytesConsumed(doc.source, start);
    if (size <= api.window_row_scan_max_bytes) return;
    doc.oversized_stage.append(doc.gpa, .{ .row = row + 1, .pos = end }) catch {};
}

/// Fold this chunk's staged oversized-row checkpoints into the persistent
/// `oversized_checkpoints` list `ls_window_set`/`ls_row_oversized` consult,
/// IFF this chunk was the one ADVANCING the shared frontier (computed exactly
/// like the sibling `checkpoints` append at each call site — see
/// index.scanChunk / search.commitSearch / filter.commitFilter): a chunk
/// re-walking already-frontier-covered ground (search/filter catching up to
/// an index that got there first) would otherwise re-stage rows out of the
/// row-ascending order nav.checkpointAtOrBefore's binary search relies on —
/// discarding it is safe because whichever scan advanced the frontier through
/// those rows FIRST already staged+drained them. Each staged entry is only
/// appended if its `.row` strictly exceeds the current last entry's `.row`
/// (REVIEW-huge-row-budget-1 finding 2): keeps the list sorted BY
/// CONSTRUCTION, robust even if a future change let a second mid-block
/// frontier overlap occur (today there is at most one — left mid-block only
/// by headScan at open, so at most one straddling chunk can ever re-walk
/// already-drained rows). Caller holds the document mutex (or is headScan
/// during open, provably uncontended: the worker has not spawned yet).
/// Best-effort: an OOM here only costs a future re-scan of the affected row,
/// never correctness.
pub fn drainOversized(doc: *Document, advancing: bool) void {
    if (!advancing) return;
    for (doc.oversized_stage.items) |cp| {
        const n = doc.oversized_checkpoints.items.len;
        if (n > 0 and cp.row <= doc.oversized_checkpoints.items[n - 1].row) continue;
        doc.oversized_checkpoints.append(doc.gpa, cp) catch {};
    }
}
