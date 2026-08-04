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
const column_state = @import("column_state.zig");
// Only for `netIo()` (the one process-global network executor) in
// `startWorker`/`joinWorker`. Not a new module cycle: base -> source_mod ->
// net_source -> base already exists.
const net_source = @import("net_source.zig");

const posix = std.posix;
const sysio = @import("sysio.zig");

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

/// The LOCAL (mmap/gzip) open-head budget — the full 4 MiB (disk-cheap; the
/// exact-count corpus + the ABI determinism-pin ACs depend on it byte-identically).
pub const head_budget: u64 = api.open_head_max_bytes;
/// The NETWORK open-head budget — deliberately small (the author: "256 KiB, row
/// estimation secondary to speed") so a slow-link open FETCHES + INDEXES only
/// this much (~4x faster open). SINGLE SOURCE OF TRUTH for the network head size:
/// net_source's open prefetch reads it directly (that module is always the
/// network path) and index.zig's headBudget() selects it when doc.net — no other
/// site hardcodes the size or re-decides net-vs-local.
pub const net_head_budget: u64 = 256 * 1024;

// --- Small value types ------------------------------------------------------

/// A decoded cell: byte range into an owning buffer (window or header).
/// `truncated` is set when LS_CELL_MAX_BYTES cut the cell's stored bytes, or
/// when a decode bounded by an ARTIFICIAL limit (the record-1 head budget, a
/// per-row window scan budget) stopped mid-field. Running out of bytes at the
/// content's TRUE end is not a truncation — a final record with no terminator
/// is complete (see `lexInto`).
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
    fold: bool = false, // fold ASCII case for TEXT substring + predicate EQ/NE (== !case_sensitive)
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
pub const MatchScanOwner = enum { none, filter, search };
pub const ColumnSampleKind = enum { head, window };
pub const ColumnWindowRow = struct { row: u64, pos: Pos, oversized: bool };

/// The document's single background scan worker, in the two shapes it can take.
/// `Document.startWorker` is the ONE place that decides between them and
/// `Document.joinWorker` the ONE place that tears either down; no other module
/// re-derives the policy (every other site only null-tests `doc.worker`).
///
///   * `.thread` — a raw `std.Thread`, the shape every document used before.
///     Shut down by `stop` + `wakeWorker` + `join`: the worker observes `stop`
///     between chunks and returns on its own.
///   * `.task` — an `io.concurrent` task of the process-global network executor
///     (`net_source.netIo`). Identical code on a DIFFERENT kind of thread: one
///     the executor owns, so `Thread.current` is set and every blocking socket
///     syscall it makes becomes a cancellation point (`Threaded.Syscall.start`,
///     Io/Threaded.zig:1345-1366) instead of the uncancellable
///     `.{ .thread = null }` a raw thread gets at :1348. `Future.cancel` then
///     interrupts a parked read with `pthread_kill(handle, .IO)` until the
///     thread acknowledges, which is what makes `ls_close` terminate against a
///     peer that accepts the connection and then answers nothing.
pub const Worker = union(enum) {
    thread: std.Thread,
    task: std.Io.Future(void),
};

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
    mutex: sysio.Mutex,
    cond: sysio.Condition,
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
    search_fold: bool, // fold ASCII case (== !request.case_sensitive): TEXT substring + predicate EQ/NE
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
    filter_fold: bool, // fold ASCII case (== !request.case_sensitive): TEXT substring + predicate EQ/NE
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
    worker: ?Worker,
    stop: bool,
    stop_atomic: std.atomic.Value(bool),

    // Materialized window (window lane only; no lock). win_source[i] is the
    // ORIGINAL data-row number of materialized row win_first+i (identity when
    // no filter is active; see ls_source_row / FILTERED VIEWS).
    win_buf: std.ArrayList(u8),
    win_refs: std.ArrayList(CellRef),
    win_source: std.ArrayList(u64),
    // Source position corresponding to each win_source row. This is copied
    // into the bounded inference event queue after materialization, so the
    // worker never borrows the evictable window buffers.
    win_pos: std.ArrayList(Pos) = .empty,
    // win_oversized[i] mirrors win_source[i]: true iff materialized row
    // win_first+i's SOURCE extent exceeded LS_WINDOW_ROW_SCAN_MAX_BYTES, so it
    // was served as a bounded prefix (see ls_row_oversized / ARCH-huge-row-
    // budget). Set by windowSet alongside win_refs/win_source.
    win_oversized: std.ArrayList(bool),
    win_first: u64,
    win_rows: u64,
    // Window MATERIALIZATION EPOCH (thin-frontend-shared-core Phase 1): bumped
    // by window.windowSet on EVERY call (a re-request may EXTEND win_rows, so
    // win_first/win_rows alone can't tell a stale window from a grown one, and
    // an identical first_row/count under a new filter holds different content).
    // window.matchFlags keys its memo on it so the flags buffer is invalidated
    // by the next ls_window_set exactly like the ls_cell borrow. DEFAULTED so
    // openWithAllocator's literal need not mention it.
    win_gen: u64 = 0,

    // Aggregate-window request identity and continuation. The materialized
    // prefix stays in win_* above; these fields retain only the O(1) source
    // cursor needed to extend an identical request without replaying it.
    win_request_valid: bool = false,
    win_request_count: u64 = 0,
    win_request_filtered: bool = false,
    win_request_filter_gen: u64 = 0,
    win_cursor_valid: bool = false,
    win_cursor_pos: Pos = .{ .logical = 0, .physical = 0 },
    win_cursor_row: u64 = 0,
    win_filter_locating: bool = false,
    win_filter_skip: u64 = 0,
    win_candidate_tested: bool = false,
    win_candidate_matched: bool = false,
    win_candidate_capped: bool = false,
    win_candidate_next_pos: Pos = .{ .logical = 0, .physical = 0 },
    win_candidate_next_row: u64 = 0,

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

    // --- Streaming-copy cap test seam (thin-frontend-shared-core Phase 2) ----
    // DEFAULTED (like copy_cursor_* above), so openWithAllocator's literal is
    // undisturbed. 0 == the natural LS_COPY_MAX_CELLS (api.copy_max_cells); a
    // Zig-only test seam (copyCapCellsForTest) forces a small value so the
    // ls_copy_* budget_capped behavior is testable without a 10M-cell fixture.
    // Read only by the ls_copy_* job path; never crosses the C ABI.
    copy_cap_cells: u64 = 0,

    // --- Match-flags memo (thin-frontend-shared-core Phase 1) ----------------
    // One flag byte per visible cell (1 = matches the active search request,
    // 0 = not), row-major over the materialized window x the requested column
    // range, computed by window.matchFlags (ls_window_match_flags) from the
    // bytes already in win_buf/win_refs — never a scan. MEMOIZED: recomputed
    // lazily only on the first call after a window (win_gen) or search
    // (search_gen) change, or a change to the requested column range, and
    // reused across repaints with zero further allocation. BORROWED like
    // win_buf: the returned ls_str points into `mf_flags` and stays valid until
    // the next ls_window_set / ls_close. All DEFAULTED (like the copy cursor),
    // so openWithAllocator's literal need not mention them and a doc that never
    // paints highlights pays nothing. mf_flags is freed in freeDoc.
    mf_flags: std.ArrayList(u8) = .empty,
    mf_valid: bool = false,
    mf_win_gen: u64 = 0,
    mf_search_gen: u64 = 0,
    mf_first_col: u32 = 0,
    mf_col_count: u32 = 0,

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

    // The worker's active FILTER/SEARCH gzip cursor.  It deliberately stays
    // leased across 2048-row commit boundaries so unrelated replay cursors
    // cannot perturb the sequential inflater session between blocks.  Only
    // the single scan worker (or the mutex-held degraded fallback) touches it.
    match_scan_cursor: ?source_mod.Cursor = null,
    match_scan_owner: MatchScanOwner = .none,
    match_scan_gen: u64 = 0,

    // TEST-ONLY seam (gz-filter-stream regression; contracts/api.zig
    // gzScanParkWorker): when set, the background worker declines the
    // FILTER/SEARCH match-scan slot so a test can drive that scan ONE 2048-row
    // block at a time on its own thread and deterministically interleave
    // behind-frontier window/copy work between blocks. DEFAULTED false, so
    // production behavior is byte-identical; only test code ever sets it.
    scan_park: std.atomic.Value(bool) = .init(false),

    // --- window-budget instrumentation state (ARCH-window-budget) -----------
    // DEFAULTED (like copy_cursor_* / gz_* above) so openWithAllocator's literal
    // need not mention them. Read ONLY via contracts/api.zig's
    // windowChargedBytes / navChargedBytes (Zig-only seams -> root.zig), NEVER the
    // C ABI. Per-call latches: ls_window_set / ls_search_nav each reset their OWN
    // field at entry and add every charged source-byte visit to it (checkpoint
    // skips, the filtered test+display double pass, any replay -- see the seam doc
    // comments). Navigation replacement uses nav_gen so a worker result from a
    // superseded/cancelled request cannot publish. The counters are pure
    // instrumentation, irrelevant to any returned byte.
    window_charged_bytes: u64 = 0, // AC2/AC3/AC4/AC8: last ls_window_set charged work
    nav_charged_bytes: u64 = 0, // AC11/AC12 (#6): last ls_search_nav SYNCHRONOUS charged work
    nav_charge_active: bool = false,
    nav_gen: u64 = 0, // replacement/cancel guard for off-main filtered navigation

    // --- network-source instrumentation state (ARCH-network-source) ---------
    // DEFAULTED (like gz_* / window-budget above) so openWithAllocator's literal
    // need not mention them AND a non-network document reports zeros. Read ONLY
    // via contracts/api.zig's Zig-only seams (netRangeMode / netFetchCount /
    // netResidentBytes / netSpoolStore / netForceCacheBytes -> root.zig), NEVER
    // the C ABI. The implementer populates these from the http_range Source it
    // adds (peer to mmap/gzip in source.zig): net_range_mode when the probe
    // resolves, net_fetch_count per network fetch issued, net_resident_bytes to
    // the Source's live resident RAM (bound 16 MiB), and the spool fields from
    // the private spool file. In the SEED they stay zero, which makes every
    // network-source quantitative AC RED until the Source is built + wired
    // (mirroring the gz_* seed).
    // never-full-download-streaming (TD1): the lazy-frontier gate. True for a
    // network-sourced document (http_range, or gzip composed over http_range);
    // false for every LOCAL mmap/gzip doc, so local behavior is byte-identical.
    // When set, the worker suppresses the AUTO background frontier indexer and
    // the filter auto-drive-to-completion, and search starts parked — the
    // frontier advances only on concrete demand (viewport jump / search nav /
    // filter demand). Set in open.buildDocument, keyed strictly on source kind.
    net: bool = false,
    net_range_mode: u8 = 0, // AC3/AC4: 0 unknown, 1 random-access, 2 sequential-fallback
    net_fetch_count: u64 = 0, // AC6/AC13: network fetches issued by this doc's Source
    net_resident_bytes: u64 = 0, // AC15: network Source resident RAM (bound 16 MiB)
    net_spool_present: bool = false, // AC14: a private spool file exists
    net_spool_bytes: u64 = 0, // AC14: its size
    net_spool_mode: u32 = 0, // AC14: its permission bits (must be 0o600)
    net_spool_unlinked: bool = false, // AC14: already unlinked while open
    // AC6 test control: cap the resident RAM cache to N bytes (0 == evict all);
    // maxInt == no cap (the default / natural behavior, mirroring the
    // gz_ckpt_fail_after "maxInt == never" idiom).
    net_force_cache_bytes: u64 = std.math.maxInt(u64),

    // ARCH-column-config: entirely empty at open. Dynamic storage remains
    // sparse and is first allocated only by an explicit column request or
    // configuration mutation.
    column_store: column_state.Store = .{},
    // Lazily allocated inference worker/event storage. Empty ArrayList
    // headers add no inference payload allocation to cold open.
    column_buf: std.ArrayList(u8) = .empty,
    column_refs: std.ArrayList(CellRef) = .empty,
    column_worker_ids: std.ArrayList(u32) = .empty,
    column_changed_ids: std.ArrayList(u32) = .empty,
    column_window_events: std.ArrayList(ColumnWindowRow) = .empty,
    column_event_index: usize = 0,
    column_event_decoded_bytes: u64 = 0,
    column_window_generation: u64 = 0,
    column_work_generation: u64 = 0,
    column_head_pos: Pos = .{ .logical = 0, .physical = 0 },
    column_head_row: u64 = 0,
    column_head_target: u64 = 0,
    column_head_exact: bool = false,
    column_head_active: bool = false,
    column_parsed: bool = false,
    column_parsed_kind: ColumnSampleKind = .head,
    column_parsed_source_row: u64 = 0,
    column_parsed_next_pos: Pos = .{ .logical = 0, .physical = 0 },
    column_parsed_oversized: bool = false,
    column_commit_index: usize = 0,
    column_scanner: ?reader_mod.SelectedScanner = null,
    column_scan_start_pos: Pos = .{ .logical = 0, .physical = 0 },
    column_scan_accounted_bytes: u64 = 0,
    column_parsed_source_bytes: u64 = 0,
    column_parsed_request_gen: u64 = 0,
    column_parsed_window_gen: u64 = 0,
    column_parsed_work_gen: u64 = 0,

    pub fn lock(self: *Document) void {
        self.mutex.lockUncancelable(sysio.io());
    }
    pub fn unlock(self: *Document) void {
        self.mutex.unlock(sysio.io());
    }
    pub fn wakeWorker(self: *Document) void {
        self.cond.broadcast(sysio.io());
    }
    pub fn waitWork(self: *Document) void {
        self.cond.waitUncancelable(sysio.io(), &self.mutex);
    }

    /// Start the single background scan worker. THE decision point for
    /// `Worker`'s two shapes, and it keys on `self.net` — the ONE
    /// already-computed network resolver (set once in `open.buildDocument`
    /// from `source_mod.sourceIsNetwork`, and the same field the lazy-frontier
    /// gate reads). No new policy, no second predicate.
    ///
    /// Only a NETWORK document becomes an executor task, because only a
    /// network document can park in a syscall that `stop` cannot reach: an
    /// in-flight `fetchInto` on a silent peer. A local mmap/gzip scan makes no
    /// interruptible blocking syscall — it faults pages in and checks `stop`
    /// between chunks — so for it the task shape would buy nothing and cost
    /// three things: `Threaded.init`'s process-wide SIGIO/SIGPIPE handlers
    /// (Io/Threaded.zig:1652-1664) installed in hosts that never touch the
    /// network, an executor thread that is never retired, and a brand-new
    /// `error.Canceled` path through the local scan. The local path therefore
    /// stays a raw `std.Thread`, byte-identical to before.
    ///
    /// Degraded fallback preserved: on failure `worker` stays null and the
    /// callers that null-test it drive the scan inline under the mutex.
    pub fn startWorker(self: *Document, comptime entry: fn (*Document) void) void {
        if (self.net) {
            const future = net_source.netIo().concurrent(entry, .{self}) catch return;
            self.worker = .{ .task = future };
        } else {
            const thread = std.Thread.spawn(.{}, entry, .{self}) catch return;
            self.worker = .{ .thread = thread };
        }
    }

    /// Stop and join the worker. Caller must ALREADY have published `stop`,
    /// called `source_mod.sourceShutdown`, woken the worker and dropped the
    /// mutex (see `ls_close`) — this only performs the join half.
    ///
    /// The two halves compose, and both are required for a network document:
    ///   * `shutdown` (stored by `sourceShutdown`) is what stops the source
    ///     from entering ANOTHER blocking fetch — every net_source wait loop
    ///     re-reads it at the top of each iteration. It cannot interrupt the
    ///     fetch already in flight.
    ///   * `Future.cancel` is what unblocks the fetch already in flight. It is
    ///     request-plus-await; 0.16's `Io` vtable has no request-without-await
    ///     primitive (`Io.zig:1190`), which is why the teardown lands here.
    ///     Cancellation is ONE-SHOT, not sticky — only the next cancellation
    ///     point returns `error.Canceled` (Io.zig:1183-1188, and
    ///     Threaded.zig:1363-1364 where a `.canceled` thread goes back to
    ///     uninterruptible syscalls) — so it could not on its own stop a retry
    ///     loop from re-blocking. `shutdown` is what guarantees there is no
    ///     next fetch to re-block on.
    /// A worker parked in `waitWork` instead of a socket read needs neither:
    /// the caller's `wakeWorker` broadcast already returned it to the loop
    /// head, where `stop` ends it. `lock`/`waitWork` use the UNCANCELABLE
    /// Mutex/Condition variants, so a pending cancel request cannot break the
    /// teardown path itself.
    pub fn joinWorker(self: *Document) void {
        if (self.worker) |*w| switch (w.*) {
            .thread => |t| t.join(),
            // In place, never a copy: cancel writes the task's result through
            // this pointer.
            .task => |*future| future.cancel(net_source.netIo()),
        };
        self.worker = null;
    }

    /// Return the whole-job FILTER/SEARCH cursor, replacing a stale cursor
    /// only when scan ownership/generation changes or its continuation no
    /// longer agrees with the caller's opaque position.
    pub fn beginMatchScan(self: *Document, owner: MatchScanOwner, generation: u64, pos: Pos) ?*source_mod.Cursor {
        if (self.source != .gzip) {
            self.endMatchScan();
            return null;
        }
        const logical = self.reader.logicalBytes(self.source, pos);
        if (self.match_scan_owner != owner or self.match_scan_gen != generation or
            self.match_scan_cursor == null or self.match_scan_cursor.?.logical != logical)
        {
            self.endMatchScan();
            self.match_scan_cursor = source_mod.scanCursorAt(self.source, logical);
            self.match_scan_owner = owner;
            self.match_scan_gen = generation;
        }
        return &self.match_scan_cursor.?;
    }

    pub fn endMatchScan(self: *Document) void {
        if (self.match_scan_cursor) |*cur| cur.deinit();
        self.match_scan_cursor = null;
        self.match_scan_owner = .none;
        self.match_scan_gen = 0;
    }

    /// Release only the lease owned by the worker snapshot that completed.
    /// A stale chunk must never tear down a different generation's cursor.
    pub fn endMatchScanIf(self: *Document, owner: MatchScanOwner, generation: u64) void {
        if (self.match_scan_owner == owner and self.match_scan_gen == generation) self.endMatchScan();
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
    doc.endMatchScan();
    if (doc.column_scanner) |*scanner| scanner.deinit();
    source_mod.sourceShutdown(&doc.source);
    doc.checkpoints.deinit(doc.gpa);
    doc.oversized_checkpoints.deinit(doc.gpa);
    doc.oversized_stage.deinit(doc.gpa);
    doc.win_buf.deinit(doc.gpa);
    doc.win_refs.deinit(doc.gpa);
    doc.win_source.deinit(doc.gpa);
    doc.win_pos.deinit(doc.gpa);
    doc.win_oversized.deinit(doc.gpa);
    doc.mf_flags.deinit(doc.gpa);
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
    doc.column_store.deinit(doc.gpa);
    doc.column_buf.deinit(doc.gpa);
    doc.column_refs.deinit(doc.gpa);
    doc.column_worker_ids.deinit(doc.gpa);
    doc.column_changed_ids.deinit(doc.gpa);
    doc.column_window_events.deinit(doc.gpa);
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
    // std.Io.Mutex/Condition need no explicit destroy (unlike pthread_*_destroy).
    doc.gpa.destroy(doc);
}

/// security-hardening (e) AC-e3: the ONE stall predicate shared by all three
/// frontier drivers (index.scanChunk's jump/plain-index branch,
/// search.searchScanChunk, filter.filterScanChunk) — a row lex that consumed
/// ZERO logical bytes.
///
/// `logical` is the exact test, not a proxy: for a NETWORK GZIP source many
/// distinct logical positions share one physical (compressed) offset, so a
/// physical-byte comparison both misses real progress and reports false stalls.
///
/// A zero-byte row can only mean the bytes at `from` are NOT PRESENT: a short or
/// failed ranged fetch left them un-fetched BELOW the source's advertised end, so
/// the span is empty while `atEnd` (which only knows the advertised end) is still
/// false. Counting a row there would fabricate a phantom row with no bytes behind
/// it — silently wrong data — and re-entering would spin at 100% CPU forever.
///
/// Restricted to `doc.net` deliberately: a local mmap/gzip source always has its
/// bytes, so a zero-byte lex there is a genuine terminus that the existing
/// `atEnd`/`spanTerminal` paths already classify correctly, and only the network
/// source can park indefinitely.
pub fn scanStalled(doc: *const Document, from: Pos, to: Pos) bool {
    return doc.net and to.logical == from.logical;
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
