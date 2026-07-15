//! Frozen Zig-side contract for the less-sheet core (viewer-ui + find-seek +
//! csv-hardening + filtered-views slices).
//!
//! This file is planner-owned. It mirrors the workspace-frozen C header
//! `api/lesssheet.h` EXACTLY — names, types, values, and semantics; the two
//! files are amended only together, by the planner. The comptime block below
//! pins every public signature: any drift in `src/` fails `zig build`.
//!
//! Tests (backend/tests/) import ONLY this module (`@import("api")`).
//!
//! Semantics are documented in full in api/lesssheet.h (format neutrality,
//! ownership & the eviction-safe borrow rule, O(head) open cost, the scan
//! frontier, the SEARCH job model, threading lanes, dialect grammar,
//! sniffing, header rule). Summary of the implementation obligations:
//!   - `ls_*` symbols are `pub export fn` with the C calling convention and
//!     implement the header exactly.
//!   - `ls_open` must behave exactly like `openWithAllocator` called with the
//!     implementation's default allocator.
//!   - Every heap allocation for a document goes through the allocator the
//!     document was opened with, and `ls_close` returns all of it to that
//!     allocator (after cancelling + joining core-owned threads — safe during
//!     jump-scans AND match-scans). Mapping the source file itself (mmap) is
//!     exempt.
//!   - Only `ls_open`, `ls_window_set`, `ls_search_start`, and
//!     `ls_search_nav` may allocate as calls (running background scans may
//!     allocate internally for index/count storage). All accessors and polls
//!     — including `ls_search_poll` — and the two cancels perform ZERO
//!     allocator calls and never fail; once every scan has reported a
//!     terminal state, no further internal allocation happens until the next
//!     mutating call.
//!   - `ls_open` consumes at most `open_head_max_bytes` of the file and
//!     leaves the frontier covering at least min(total rows,
//!     `open_ready_min_rows`) when they fit that budget. The search
//!     machinery is lazy: zero cost until the first `ls_search_start`.
//!   - `ls_window_set` never advances the frontier; the frontier is monotone
//!     and advances only via open's head scan, the AUTO background indexer,
//!     jump-scans, and match-scans. Search count storage is O(index
//!     checkpoints), independent of match density — never a match-row list.
//!   - Search jobs and jump jobs share the document's single background-scan
//!     slot; the pinned interaction (mutual cancellation, kept gains,
//!     terminal states, nav resume) is in api/lesssheet.h SEARCH.
//!   - A FILTER (ls_filter_set/clear/poll, ls_source_row) is a view mode over
//!     the same machinery: per-block match counters (O(index checkpoints),
//!     never a match-row list) make the row accessors, jump, and search all
//!     operate in filtered coordinates. Its filter-scan shares the single
//!     scan slot; the full model (slot contention, reset, source-row mapping,
//!     the filtered-coordinate reinterpretation) is in api/lesssheet.h
//!     FILTERED VIEWS.
//!   - The core may own background threads (std.Thread); tests pin
//!     observable behavior, never scheduling.

const std = @import("std");
const core = @import("core");

// ---------------------------------------------------------------------------
// Constants (mirror the LS_* defines in api/lesssheet.h).
// ---------------------------------------------------------------------------

/// Mirrors LS_SNIFF: detect this parameter from the file.
pub const sniff: i32 = -1;
/// Mirrors LS_QUOTE_NONE: quoting disabled, quote bytes are literal.
pub const quote_none: i32 = -2;
/// Mirror LS_HEADER_OFF / LS_HEADER_ON.
pub const header_off: i32 = 0;
pub const header_on: i32 = 1;
/// Mirror LS_INDEX_AUTO / LS_INDEX_MANUAL.
pub const index_auto: i32 = 0;
pub const index_manual: i32 = 1;
/// Mirrors LS_OPEN_READY_MIN_ROWS.
pub const open_ready_min_rows: u32 = 512;
/// Mirrors LS_OPEN_HEAD_MAX_BYTES.
pub const open_head_max_bytes: u64 = 4 * 1024 * 1024;
/// Mirrors LS_WINDOW_MAX_ROWS.
pub const window_max_rows: u32 = 4096;
/// Mirrors LS_NO_ROW: the ls_source_row sentinel for a view row that is not
/// currently servable (outside the materialized window / view range).
pub const no_row: u64 = std.math.maxInt(u64);

/// Mirror LS_ENCODING_*. `encoding_auto` (options only, detect sentinel — in
/// the LS_SNIFF / LS_QUOTE_NONE negative-sentinel style) is NEVER reported in
/// Dialect.encoding, which always names one concrete resolved encoding. See
/// the header's TEXT AND ENCODING section.
pub const encoding_auto: i32 = -1;
pub const encoding_utf8: u8 = 0;
pub const encoding_utf16le: u8 = 1;
pub const encoding_utf16be: u8 = 2;
pub const encoding_latin1: u8 = 3; // ISO-8859-1
pub const encoding_windows1252: u8 = 4;

/// Mirrors LS_CELL_MAX_BYTES: the per-cell UTF-8 DISPLAY CAP ls_cell /
/// ls_header_cell serve (cut at a code-point boundary; display-only — search
/// scans the full cell). Reported per cell by ls_cell_truncated /
/// ls_header_cell_truncated.
pub const cell_max_bytes: usize = 4096;

/// Mirrors LS_WINDOW_ROW_SCAN_MAX_BYTES: the per-row SOURCE-byte scan cap for
/// the SYNCHRONOUS window path (ls_window_set). A row whose source extent
/// exceeds this is served as a bounded PREFIX and flagged by ls_row_oversized;
/// this bounds ls_window_set to O(min(row bytes, this) * rows) — safe on the UI
/// thread for any row size. DISTINCT from `cell_max_bytes` (the per-cell OUTPUT
/// display cap, far smaller); both apply. See the header's TEXT AND ENCODING /
/// the LS_WINDOW_ROW_SCAN_MAX_BYTES comment.
pub const window_row_scan_max_bytes: u64 = 1024 * 1024;

/// Sniffer candidates in pinned tie-break preference order (see the header's
/// DIALECT SNIFFING section).
pub const separator_candidates: []const u8 = ",;\t|";
pub const quote_candidates: []const u8 = "\"'";
/// Sniff defaults (reported for empty documents / no-structure files).
pub const default_separator: u8 = ',';
pub const default_quote: u8 = '"';

// ---------------------------------------------------------------------------
// Types (mirror api/lesssheet.h exactly; all extern / C-ABI compatible).
// ---------------------------------------------------------------------------

/// Mirrors `ls_status`. Failure codes are distinct and stable.
pub const Status = enum(c_int) {
    ok = 0,
    not_found = 1,
    permission_denied = 2,
    io = 3,
    invalid_argument = 4,
};

/// Mirrors `ls_doc`: opaque document handle, core-owned.
pub const Doc = opaque {};

/// Mirrors `ls_str`: borrowed UTF-8 bytes, NOT NUL-terminated, `ptr` never
/// null, valid until the next `ls_window_set` on the owning document or
/// `ls_close`, whichever comes first.
pub const Str = extern struct {
    ptr: [*]const u8,
    len: usize,

    /// View the borrowed bytes as a slice (test/consumer convenience).
    pub fn slice(self: Str) []const u8 {
        return self.ptr[0..self.len];
    }
};

/// Mirrors `ls_open_options`. Field domains and the forced separator==quote
/// collision rule are documented in the header; violations make ls_open fail
/// with .invalid_argument before any file access.
pub const OpenOptions = extern struct {
    separator: i32 = sniff,
    quote: i32 = sniff,
    header: i32 = sniff,
    index_mode: i32 = index_auto,
    encoding: i32 = encoding_auto,
};

/// Mirrors `ls_dialect`: the effective dialect report. Field order matches the
/// C struct exactly (encoding after header; encoding_forced after
/// header_forced). encoding is a concrete resolved LS_ENCODING_* value, never
/// encoding_auto.
pub const Dialect = extern struct {
    separator: u8,
    quote: u8,
    has_quote: bool,
    header: bool,
    encoding: u8,
    separator_forced: bool,
    quote_forced: bool,
    header_forced: bool,
    encoding_forced: bool,
};

/// Mirrors `ls_row_count`: row-count knowledge (count + exact/estimated).
pub const RowCount = extern struct {
    count: u64,
    exact: bool,
};

/// Mirrors `ls_row_range`: half-open [first_row, first_row + row_count).
pub const RowRange = extern struct {
    first_row: u64,
    row_count: u64,
};

/// Mirrors `ls_scan_progress`: monotone bytes_scanned, file-size bytes_total,
/// complete iff every record is indexed.
pub const ScanProgress = extern struct {
    bytes_scanned: u64,
    bytes_total: u64,
    complete: bool,
};

/// Mirrors `ls_jump_state`.
pub const JumpState = enum(c_int) {
    idle = 0,
    scanning = 1,
    done = 2,
};

/// Mirrors `ls_jump_status`: progress in [0,1], monotone within a jump,
/// exactly 1.0 when done; landed_row valid only when done.
pub const JumpStatus = extern struct {
    state: JumpState,
    progress: f64,
    landed_row: u64,
};

/// Mirrors `ls_search_kind`.
pub const SearchKind = enum(c_int) {
    text = 0,
    predicate = 1,
};

/// Mirrors `ls_search_op`: eq/ne are byte-exact; lt/gt/le/ge are numeric
/// under the pinned grammar with EXACT mathematical comparison (see the
/// header's ls_search_request).
pub const SearchOp = enum(c_int) {
    eq = 0,
    ne = 1,
    lt = 2,
    gt = 3,
    le = 4,
    ge = 5,
};

/// Mirrors `ls_search_dir` (see `ls_search_nav` for the pinned anchor
/// semantics: forward = first match AT-OR-AFTER anchor; backward = last
/// match STRICTLY BEFORE anchor).
pub const SearchDir = enum(c_int) {
    forward = 0,
    backward = 1,
};

/// Mirrors `ls_search_state`.
pub const SearchState = enum(c_int) {
    idle = 0,
    scanning = 1,
    done = 2,
    cancelled = 3,
};

/// Mirrors `ls_search_nav_state`.
pub const SearchNavState = enum(c_int) {
    none = 0,
    searching = 1,
    found = 2,
    exhausted = 3,
};

/// Mirrors `ls_search_request`. Borrowed only for the duration of
/// `ls_search_start` (the core copies what it keeps). Validity rules and the
/// pinned per-kind matching semantics (smart case, byte-exact eq/ne, exact
/// numeric ordering, scope) are in api/lesssheet.h.
pub const SearchRequest = extern struct {
    kind: SearchKind,
    op: SearchOp = .eq,
    column: u32 = 0,
    value_ptr: ?[*]const u8 = null,
    value_len: usize = 0,
    scope_ptr: ?[*]const u32 = null,
    scope_len: usize = 0,
};

/// Mirrors `ls_search_status` (see it for every field's validity rule).
/// IDLE means "no search since open": every other field is zero.
pub const SearchStatus = extern struct {
    state: SearchState,
    nav: SearchNavState,
    progress: f64,
    found_row: u64,
    found_col: u32,
    position: u64,
    total: u64,
    total_exact: bool,
};

/// Mirrors `ls_filter_state`: the (single) filter's scan-slot occupancy.
/// idle == no filter active (the identity view); scanning/done/cancelled all
/// mean a filter IS active (the view is filtered). See FILTERED VIEWS.
pub const FilterState = enum(c_int) {
    idle = 0,
    scanning = 1,
    done = 2,
    cancelled = 3,
};

/// Mirrors `ls_filter_status`: like SearchStatus without the navigation slot.
/// idle means "no filter active" (every other field zero). progress is in
/// [0,1], monotone within one filter, exactly 1.0 at done, frozen when
/// cancelled. total is matching rows counted so far (m; exact for the counted
/// region, monotone) and equals ls_row_count_get().count while filtered;
/// total_exact iff the filter-scan completed (done).
pub const FilterStatus = extern struct {
    state: FilterState,
    progress: f64,
    total: u64,
    total_exact: bool,
};

/// Mirrors `ls_copy_result`: the result of `ls_cell_copy` (the bounded full-cell
/// read — see api/lesssheet.h FULL-CELL READ). Distinct, stable values.
///   ok      — the cell was read (out_len bytes written, out_truncated valid).
///   pending — `row` is at/beyond the scan frontier and not yet servable;
///             advance the frontier (ls_jump_start) and retry. Never scans.
///   no_cell — no such cell (col out of range, row at/past an EXACT end, or an
///             empty document); retrying will not help.
pub const CopyResult = enum(c_int) {
    ok = 0,
    pending = 1,
    no_cell = 2,
};

// ---------------------------------------------------------------------------
// csv-gz internal Source/Reader SEAM value types (ARCH-csv-gz "Internal
// Source/Reader contract"). Planner-owned + FROZEN: the OBSERVABLE vocabulary
// the repaired, bounded-streaming Source/Reader seam speaks + the result shapes
// the Zig-only test seams below hand back. The seam's OWN types (source.Source,
// reader.Reader, reader.Pos, source.Cursor) and the checkpoint/cache/lexer/
// matcher MECHANISM stay implementer-owned in src/ (the af83db9 reader-
// interface ownership boundary is preserved -- Decision 1-C); the comptime
// block at the bottom pins that `core` PROVIDES the enumerated capabilities in
// THIS vocabulary. NONE of these cross the C ABI -- api/lesssheet.h is unchanged.
// ---------------------------------------------------------------------------

/// The Source's END-KNOWLEDGE (ARCH req2/req8/AC9): a bounded logical-byte
/// provider must never conflate "the currently inflated prefix ends here" with
/// EOF. `inflating` is NOT an end (the decoder can still advance); the other
/// four are the terminal/stop outcomes the recovery matrix (AC9/AC10) and the
/// dual-bounded open (AC5) depend on. Zig-only (never crosses the C ABI).
pub const SourceEnd = enum(u8) {
    /// More output may follow; NOT end (the Reader must keep going).
    inflating = 0,
    /// The stream ended cleanly (all members validated / mmap true end).
    clean_eof = 1,
    /// A salvaged terminal prefix (footer/structural damage after >=1 payload
    /// byte); the logical end is IMMUTABLE from here (ARCH req8/AC10).
    damaged_eof = 2,
    /// Stopped at a caller DualLimit ceiling; more data may exist and must
    /// never be mistaken for EOF (ARCH req2/AC5).
    budget_stop = 3,
    /// Bounded backward access can no longer be guaranteed (checkpoint store
    /// unavailable within the resident ceiling) -> becomes damaged_eof for the
    /// presented stream (ARCH req7/AC18).
    unavailable = 4,
};

/// A cursor request's DUAL ceilings (ARCH req2): an independent logical
/// inflated-output limit and an optional physical compressed-input limit.
/// `null` == unbounded on that axis. Window/copy pass only `logical`; open
/// passes BOTH (AC5); unbounded worker scans pass neither. Zig-only, so `?u64`
/// is fine. This replaces `Source.len()` / `Source.slice(0, len())` -- no
/// operation may require a total logical length or a slice from byte zero.
pub const DualLimit = struct {
    logical: ?u64 = null,
    physical: ?u64 = null,
};

/// AC5/AC6/AC7 test-seam result: the two open-budget axes actually CONSUMED by
/// the last `ls_open` -- physical compressed input read + inflated output
/// produced -- so a test proves open stopped within BOTH 4 MiB ceilings AND did
/// real work (see `gzOpenBudget`).
pub const OpenBudget = struct {
    physical_in: u64,
    inflated_out: u64,
};

/// AC15 test-seam result: the last behind-frontier landing's restored inflate
/// checkpoint (logical offset) + inflated bytes replayed to reach the target,
/// so a test proves replay resumed from a NONZERO nearest checkpoint and stayed
/// <= 32 MiB (see `gzReplayStats`).
pub const ReplayStats = struct {
    landed: bool,
    restored_checkpoint_logical: u64,
    inflated_replay: u64,
};

/// AC17/AC21 test-seam result: the private checkpoint spill file's state, so a
/// test proves it is mode-0600, already unlinked while open, bounded, and
/// absent after close (see `gzCheckpointStore`). `present == false` == no spill
/// file exists (memory-only mode / plain CSV).
pub const CheckpointStore = struct {
    present: bool,
    bytes: u64,
    mode: u32,
    unlinked: bool,
};

/// AC14 test-seam result: round-tripping a gzip stream through a FORCED inflate-
/// checkpoint snapshot+restore at a probe offset. `restored` proves a snapshot
/// was actually taken AND restored (not a no-op); `identical` proves the
/// restored decoder produced byte-identical output+integrity to uninterrupted
/// Zig-0.16 `.gzip` decoding (see `gzSnapshotProbe`).
pub const SnapshotProbe = struct {
    restored: bool,
    identical: bool,
};

// ---------------------------------------------------------------------------
// Public surface (re-exported from the implementation; tests use only these).
// ---------------------------------------------------------------------------

/// C ABI — see api/lesssheet.h for the full contract of each.
pub const ls_open = core.ls_open;
pub const ls_close = core.ls_close;
pub const ls_dialect_get = core.ls_dialect_get;
pub const ls_column_count = core.ls_column_count;
pub const ls_row_count_get = core.ls_row_count_get;
pub const ls_index_poll = core.ls_index_poll;
pub const ls_window_set = core.ls_window_set;
pub const ls_cell = core.ls_cell;
pub const ls_cell_truncated = core.ls_cell_truncated;
pub const ls_header_cell = core.ls_header_cell;
pub const ls_header_cell_truncated = core.ls_header_cell_truncated;
pub const ls_jump_start = core.ls_jump_start;
pub const ls_jump_cancel = core.ls_jump_cancel;
pub const ls_jump_poll = core.ls_jump_poll;
pub const ls_search_start = core.ls_search_start;
pub const ls_search_nav = core.ls_search_nav;
pub const ls_search_cancel = core.ls_search_cancel;
pub const ls_search_poll = core.ls_search_poll;
pub const ls_filter_set = core.ls_filter_set;
pub const ls_filter_clear = core.ls_filter_clear;
pub const ls_filter_poll = core.ls_filter_poll;
pub const ls_source_row = core.ls_source_row;
pub const ls_row_oversized = core.ls_row_oversized;
/// C ABI — the bounded, window-INDEPENDENT full-cell read (select-copy). Poll/
/// control lane; copies into the caller buffer (no borrow). See api/lesssheet.h.
pub const ls_cell_copy = core.ls_cell_copy;

/// Zig-level seam for tests: identical to `ls_open` but with an explicit
/// allocator. `ls_open` == `openWithAllocator(default allocator, ...)`.
/// All heap allocation for the document — including its background scan
/// threads' document-owned state and all search/count storage — goes through
/// `gpa` (file mapping is exempt) and `ls_close` returns it to the same
/// allocator, so tests can count allocations (zero-allocation access paths),
/// measure search memory (O(checkpoints) count storage), and detect leaks.
pub const openWithAllocator = core.openWithAllocator;

// --- Test-only instrumentation seam (ARCH-stream-copy AC1-AC5) --------------
// Zig-level seams (NOT C ABI — like `openWithAllocator`), so api/lesssheet.h and
// the `ls_cell_copy` ABI stay BYTE-IDENTICAL: ARCH-stream-copy accelerates the
// copy path (window.cellCopy / cellCopyFiltered) behind the UNCHANGED ABI with
// an internal forward COPY CURSOR, and these let the frozen tests prove it.
//   * copyCursorSetEnabled — flip the cursor OFF to force today's locate-from-
//     scratch on every ls_cell_copy: the byte-identical REFERENCE for the
//     equivalence sweeps (AC1/AC2) and the interval-costly BASELINE for the
//     advance-count sweeps (AC3/AC4/AC5). Defaults ON (what production ships).
//   * copyAdvances / copyAdvancesReset — read/zero the count of SOURCE ROW-
//     ADVANCES the copy path took (boundsAfter skips + cursor forward steps),
//     so a row-major sweep's cost is measured directly: O(rows) with the cursor
//     (≈ N, interval-INDEPENDENT), O(rows x checkpoint-distance) without it.
/// Enable/disable the forward copy cursor for THIS document (default enabled).
pub const copyCursorSetEnabled = core.copyCursorSetEnabled;
/// Count of source row-advances taken on the copy path since the last reset.
pub const copyAdvances = core.copyAdvances;
/// Zero the copy-path source-row-advance counter.
pub const copyAdvancesReset = core.copyAdvancesReset;

// --- Test-only instrumentation seams (ARCH-csv-gz) --------------------------
// Zig-level seams (NOT C ABI -- like `openWithAllocator`/`copyAdvances`), so
// api/lesssheet.h stays BYTE-IDENTICAL: csv-gz adds transparent, checkpointed
// gzip BEHIND the unchanged ABI, and these let the frozen tests prove the
// bounded/streaming/recovery/replay properties the C ABI cannot express
// directly. Each reads implementer-owned base.Document state that is DEFAULTED
// to zero, so a plain-CSV document reports zeros and the mmap fast path is
// unaffected (AC20); the SEED leaves them zero, which is what makes every
// csv-gz quantitative AC RED until the gzip Source is built + wired.
//
/// AC5/AC6/AC7: physical-in / inflated-out consumed by the last ls_open.
pub const gzOpenBudget = core.gzOpenBudget;
/// AC15: the last behind-frontier landing's restored-checkpoint + replay bytes.
pub const gzReplayStats = core.gzReplayStats;
/// Zero the replay-stats latch (before a measured landing).
pub const gzReplayStatsReset = core.gzReplayStatsReset;
/// AC17: gzip-specific resident state bytes for THIS document (bound: 16 MiB).
pub const gzResidentBytes = core.gzResidentBytes;
/// AC17/AC21: the private checkpoint spill file's size/mode/unlinked/present.
pub const gzCheckpointStore = core.gzCheckpointStore;
/// AC18: inject checkpoint-store create/write failure after `ops` successful
/// store operations (0 == fail immediately; maxInt == never, the default).
pub const gzCheckpointStoreFailAfter = core.gzCheckpointStoreFailAfter;
/// AC12: force the gzip Source cursor to yield spans of at most `n` bytes
/// (1 == one byte at a time; 0 == natural chunking, the default) so a test can
/// split every CSV/encoding/query/decimal token boundary.
pub const gzForceChunkBytes = core.gzForceChunkBytes;
/// AC13: peak per-row matcher resident bytes since the last reset (must stay
/// O(query + fixed state), never O(cell)/O(file)).
pub const gzStreamMatcherResidentBytes = core.gzStreamMatcherResidentBytes;
/// Zero the matcher-residency peak (before a measured match-scan).
pub const gzStreamMatcherResidentReset = core.gzStreamMatcherResidentReset;
/// AC20 regression proxy: bytes the parse path copied THROUGH a cache for this
/// document (0 for the mmap fast path -> proves direct spans, never via the
/// gzip cache).
pub const gzCacheCopyBytes = core.gzCacheCopyBytes;
/// AC14: snapshot+restore a gzip stream at `probe_logical` and report whether a
/// checkpoint was taken/restored and the restart was byte-identical.
pub const gzSnapshotProbe = core.gzSnapshotProbe;

// --- Test-only instrumentation seam (gz-filter-stream regression) -----------
// Zig-only (NOT the C ABI -- like the gz*/wb* seams above), so api/lesssheet.h
// stays BYTE-IDENTICAL. A REGRESSION seam for a diagnosed csv-gz defect: a
// background FILTER or SEARCH scan that TRAILS the index frontier must reuse ONE
// live inflater and STREAM forward (ARCH-csv-gz req6: "Sequential forward work
// reuses its live inflater and never restarts per row") -- inflating O(logical)
// bytes in O(logical/chunk) inflate ops. The shipped trailing scan instead reuses
// the forward lane past the point its session has over-produced (cursor peek-
// ahead + chunk over-production race s.logical ahead of the cursor); the forward
// lane cannot serve a byte BEHIND its position, so the scan LIVELOCKS -- spinning
// 0-byte produce() calls forever (never terminating; wrong/frozen count). So the
// INFLATE-OP count (produce invocations) grows UNBOUNDED while inflated BYTES
// plateau at ~1x logical -- ops is the deterministic regression signal, bytes the
// complementary O(logical) work witness (+ a guard against a future pure-re-
// inflation regression). UNLIKE the other gz_*/wb_* seeds these are WIRED to real
// inflate work in the SEED (source.produce), so the gzfs_* tests FAIL on the
// current behavior and pass only once the fix streams. 0 for a plain mmap document.
/// Cumulative inflated-OUTPUT bytes the gzip Source produced for this document
/// since the last gzInflateWorkReset (0 for a plain mmap document).
pub const gzInflatedBytes = core.gzInflatedBytes;
/// Cumulative inflate OPERATIONS (produce invocations) the gzip Source performed
/// since the last gzInflateWorkReset. A streaming pass is O(logical/chunk); a
/// livelocking/re-inflating scan grows this without bound (the RED signal).
pub const gzInflateOps = core.gzInflateOps;
/// Zero both inflate-work counters (before a measured trailing scan).
pub const gzInflateWorkReset = core.gzInflateWorkReset;

/// TEST-ONLY (Zig; NOT the C ABI): outcome of one `gzScanStep` block.
pub const GzScanStep = enum(u8) { idle = 0, scanning = 1, done = 2 };

// gzScanParkWorker + gzScanStep let the frozen gzfs_*_multiblock regressions
// deterministically drive a gzip FILTER/SEARCH match-scan ONE 2048-row block at
// a time on the TEST thread (the worker parked) and interleave behind-frontier
// ls_window_set/ls_cell_copy work between blocks -- witnessing the retained
// replay lane STREAMING (bounded inflate work) under contention rather than
// re-inflating a 32 MiB checkpoint interval per perturbed block. See root.zig.
/// Park (true) / unpark (false) the background worker's match-scan slot so a
/// test can drive the scan single-threaded, block by block.
pub const gzScanParkWorker = core.gzScanParkWorker;
/// Run one 2048-row block of whichever gzip match-scan is .scanning (SEARCH has
/// slot priority, like the worker) on the calling thread; report continuation.
pub const gzScanStep = core.gzScanStep;
/// TEST-ONLY (Zig): touch a behind-frontier gzip replay lane at logical byte
/// `logical` (grab via scanCursorAt, serve one byte, release) -- models one
/// interleaved behind-frontier window/copy/nav read that grabs a replay lane.
pub const gzTouchReplayLane = core.gzTouchReplayLane;

// --- Test-only instrumentation seams (ARCH-window-budget) -------------------
// Zig-level seams (NOT C ABI -- like openWithAllocator/copyAdvances/gz*), so
// api/lesssheet.h AND every ls_* signature stay BYTE-IDENTICAL (AC1): window-
// budget bounds the SYNCHRONOUS work of ls_window_set to a fixed 8 MiB aggregate
// charged-work ceiling and repairs the filtered ls_search_nav lane (backlog #6),
// BOTH behind the unchanged ABI. A budget-truncated window is signalled ONLY by
// the EXISTING short ls_row_range (a shorter contiguous prefix; suffix pending) --
// never a new flag, and ls_row_oversized keeps its narrower per-row (>1 MiB)
// meaning. These seams let the frozen tests prove the byte/work model the C ABI
// cannot express. Each reads implementer-owned base.Document state DEFAULTED to
// zero, so the SEED reports zero -> every quantitative window-budget/#6 AC
// (">0 and <=bound", plus the #6 deferred-nav behavioral flip) is RED until the
// aggregate meter + the bounded/off-main nav are built + wired (mirroring
// copyAdvances==0 / the gz* seeds). Neither crosses the C ABI.

/// The fixed aggregate charged-work ceiling of ONE ls_window_set call:
/// 8 MiB == 8,388,608 charged source-byte visits (ARCH-window-budget Decision 2 /
/// FR1 / non-functional "Work"). NOT an ABI constant (ARCH non-goal: no
/// aggregate-budget constant in api/lesssheet.h) -- a Zig-only contract pin so the
/// tests AND the frozen number stay DRY and cannot silently drift. A hard MAXIMUM
/// per call, never a per-call target; also the responsiveness proxy the #6 proof
/// holds the SYNCHRONOUS ls_search_nav portion under (the wall-clock <500 ms /
/// target <=100 ms half is a target-host reviewer probe -- see the wb_* notes).
pub const window_budget_max_bytes: u64 = 8 * 1024 * 1024;

/// AC2/AC3/AC4/AC8: charged SOURCE-byte visits performed by the LAST ls_window_set
/// on this document -- a per-call latch (each call overwrites it at entry; no
/// reset seam needed, so a test reads one call's cost directly and sums across a
/// retry loop itself). One unit == one source byte VISITED by synchronous window
/// work, charged EVERY visit (never deduplicated by offset): checkpoint-to-target
/// skip bytes (charged even when the call returns no new row), filtered match-test
/// bytes, the filtered display re-materialize (a matched row is charged twice),
/// and any Reader/Source replay all count. Measured at the LOGICAL-source-byte
/// layer, so it is identical in meaning across the mmap and gzip Source paths
/// (ARCH "Exact byte/work model"). GREEN keeps it in (0, window_budget_max_bytes];
/// SEED == 0 (RED).
pub const windowChargedBytes = core.windowChargedBytes;

/// AC11/AC12 (backlog #6): charged SYNCHRONOUS SOURCE-byte visits performed by the
/// LAST ls_search_nav call BEFORE it returned -- the filtered-navigation work
/// proof. A per-call latch, same charging rule as windowChargedBytes. The ARCH
/// freezes this proof FIRST (Decision 5): today's filtered nav re-lexes a whole
/// checkpoint block (up to checkpoint_interval == 2048 rows) of possibly-giant
/// rows SYNCHRONOUSLY under the document lock (nav.relexBlock / countInBlockUpTo,
/// with an unbounded DualLimit), so the lane has NO finite synchronous bound. The
/// frozen branch is therefore the criterion-12 REPAIR: the synchronous portion
/// stays bounded (this counter <= window_budget_max_bytes and INDEPENDENT of
/// giant-row length) and the expensive counted-region resolution runs OFF-MAIN on
/// the existing search worker, reporting LS_SEARCH_NAV_SEARCHING until it publishes
/// the exact FOUND/EXHAUSTED result (FR11/FR12). SEED == 0, and the seed resolves
/// nav SYNCHRONOUSLY -> the #6 tests are RED via that deferred-nav flip, with this
/// counter supplying the bound/independence work evidence on GREEN.
pub const navChargedBytes = core.navChargedBytes;

// ---------------------------------------------------------------------------
// Conformance pins — signature drift in src/ fails `zig build` right here.
// ---------------------------------------------------------------------------
comptime {
    if (@TypeOf(core.ls_open) != fn ([*:0]const u8, ?*const OpenOptions, *?*Doc) callconv(.c) Status)
        @compileError("signature drift: ls_open");
    if (@TypeOf(core.ls_close) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_close");
    if (@TypeOf(core.ls_dialect_get) != fn (*const Doc) callconv(.c) Dialect)
        @compileError("signature drift: ls_dialect_get");
    if (@TypeOf(core.ls_column_count) != fn (*const Doc) callconv(.c) u32)
        @compileError("signature drift: ls_column_count");
    if (@TypeOf(core.ls_row_count_get) != fn (*const Doc) callconv(.c) RowCount)
        @compileError("signature drift: ls_row_count_get");
    if (@TypeOf(core.ls_index_poll) != fn (*const Doc) callconv(.c) ScanProgress)
        @compileError("signature drift: ls_index_poll");
    if (@TypeOf(core.ls_window_set) != fn (*Doc, u64, u32) callconv(.c) RowRange)
        @compileError("signature drift: ls_window_set");
    if (@TypeOf(core.ls_cell) != fn (*const Doc, u64, u32) callconv(.c) Str)
        @compileError("signature drift: ls_cell");
    if (@TypeOf(core.ls_cell_truncated) != fn (*const Doc, u64, u32) callconv(.c) bool)
        @compileError("signature drift: ls_cell_truncated");
    if (@TypeOf(core.ls_header_cell) != fn (*const Doc, u32) callconv(.c) Str)
        @compileError("signature drift: ls_header_cell");
    if (@TypeOf(core.ls_header_cell_truncated) != fn (*const Doc, u32) callconv(.c) bool)
        @compileError("signature drift: ls_header_cell_truncated");
    if (@TypeOf(core.ls_jump_start) != fn (*Doc, u64) callconv(.c) void)
        @compileError("signature drift: ls_jump_start");
    if (@TypeOf(core.ls_jump_cancel) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_jump_cancel");
    if (@TypeOf(core.ls_jump_poll) != fn (*const Doc) callconv(.c) JumpStatus)
        @compileError("signature drift: ls_jump_poll");
    if (@TypeOf(core.ls_search_start) != fn (*Doc, *const SearchRequest) callconv(.c) bool)
        @compileError("signature drift: ls_search_start");
    if (@TypeOf(core.ls_search_nav) != fn (*Doc, u64, SearchDir) callconv(.c) void)
        @compileError("signature drift: ls_search_nav");
    if (@TypeOf(core.ls_search_cancel) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_search_cancel");
    if (@TypeOf(core.ls_search_poll) != fn (*const Doc) callconv(.c) SearchStatus)
        @compileError("signature drift: ls_search_poll");
    if (@TypeOf(core.openWithAllocator) != fn (std.mem.Allocator, [*:0]const u8, ?*const OpenOptions, *?*Doc) Status)
        @compileError("signature drift: openWithAllocator");
    if (@TypeOf(core.ls_filter_set) != fn (*Doc, *const SearchRequest) callconv(.c) bool)
        @compileError("signature drift: ls_filter_set");
    if (@TypeOf(core.ls_filter_clear) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_filter_clear");
    if (@TypeOf(core.ls_filter_poll) != fn (*const Doc) callconv(.c) FilterStatus)
        @compileError("signature drift: ls_filter_poll");
    if (@TypeOf(core.ls_source_row) != fn (*const Doc, u64) callconv(.c) u64)
        @compileError("signature drift: ls_source_row");
    if (@TypeOf(core.ls_row_oversized) != fn (*const Doc, u64) callconv(.c) bool)
        @compileError("signature drift: ls_row_oversized");
    if (@TypeOf(core.ls_cell_copy) != fn (*const Doc, u64, u32, ?[*]u8, usize, *usize, *bool) callconv(.c) CopyResult)
        @compileError("signature drift: ls_cell_copy");
    // ARCH-stream-copy test seams (Zig-only, NOT C ABI — no callconv).
    if (@TypeOf(core.copyCursorSetEnabled) != fn (*Doc, bool) void)
        @compileError("signature drift: copyCursorSetEnabled");
    if (@TypeOf(core.copyAdvances) != fn (*const Doc) u64)
        @compileError("signature drift: copyAdvances");
    if (@TypeOf(core.copyAdvancesReset) != fn (*Doc) void)
        @compileError("signature drift: copyAdvancesReset");

    // === csv-gz: internal Source/Reader SEAM capabilities (ARCH "Internal
    // Source/Reader contract"). Decision 1-C: pin the enumerated CAPABILITIES
    // against `core.*` -- the frozen SourceEnd/DualLimit vocabulary via @TypeOf,
    // the rest via @hasDecl existence (their BEHAVIOR is pinned by the 22-AC
    // suite + the instrumentation seams below, and the seam TYPE INTERNALS stay
    // implementer-owned). "No operation may require a total logical length or a
    // slice from logical byte zero" is honored by the unknown-end query +
    // dual-limit cursor REPLACING len()/slice(0,len()).
    // (1) Source construction from a mapping + a selected mmap|gzip kind.
    if (!@hasDecl(core, "SourceKind")) @compileError("csv-gz seam: core.SourceKind (mmap|gzip) missing");
    if (!@hasDecl(core, "sourceFromMapping")) @compileError("csv-gz seam: core.sourceFromMapping missing");
    // (2) Unknown-end query in the frozen SourceEnd vocabulary.
    if (@TypeOf(core.sourceEndAt) != fn (core.Source, core.Pos) SourceEnd)
        @compileError("csv-gz seam drift: sourceEndAt must be fn(Source, Pos) SourceEnd");
    // (3) Bounded cursor acquisition by opaque logical position + DUAL limits.
    if (@TypeOf(core.sourceCursorAt) != fn (core.Source, core.Pos, DualLimit) core.Cursor)
        @compileError("csv-gz seam drift: sourceCursorAt must be fn(Source, Pos, DualLimit) Cursor");
    // (4) Logical + physical measurement of an actual position.
    if (@TypeOf(core.posLogicalBytes) != fn (core.Source, core.Pos) u64)
        @compileError("csv-gz seam drift: posLogicalBytes must be fn(Source, Pos) u64");
    if (@TypeOf(core.posPhysicalBytes) != fn (core.Source, core.Pos) u64)
        @compileError("csv-gz seam drift: posPhysicalBytes must be fn(Source, Pos) u64");
    // (5) Source rebase after the ONE leading BOM.
    if (!@hasDecl(core, "sourceRebaseBom")) @compileError("csv-gz seam: core.sourceRebaseBom missing");
    // (6) Reader bounds/materialize/cell/MATCH over cursors -- the streaming
    //     row-match (req4/AC13) replacing unbounded materialize(cap=null).
    if (!@hasDecl(core, "readerMatchRow")) @compileError("csv-gz seam: core.readerMatchRow (streaming match) missing");
    // (7) Explicit Source shutdown + deinitialization.
    if (!@hasDecl(core, "sourceShutdown")) @compileError("csv-gz seam: core.sourceShutdown missing");
    if (!@hasDecl(core, "sourceDeinit")) @compileError("csv-gz seam: core.sourceDeinit missing");

    // === csv-gz: instrumentation seam signatures (Zig-only test teeth). ======
    if (@TypeOf(core.gzOpenBudget) != fn (*const Doc) OpenBudget)
        @compileError("signature drift: gzOpenBudget");
    if (@TypeOf(core.gzReplayStats) != fn (*const Doc) ReplayStats)
        @compileError("signature drift: gzReplayStats");
    if (@TypeOf(core.gzReplayStatsReset) != fn (*Doc) void)
        @compileError("signature drift: gzReplayStatsReset");
    if (@TypeOf(core.gzResidentBytes) != fn (*const Doc) u64)
        @compileError("signature drift: gzResidentBytes");
    if (@TypeOf(core.gzCheckpointStore) != fn (*const Doc) CheckpointStore)
        @compileError("signature drift: gzCheckpointStore");
    if (@TypeOf(core.gzCheckpointStoreFailAfter) != fn (*Doc, u64) void)
        @compileError("signature drift: gzCheckpointStoreFailAfter");
    if (@TypeOf(core.gzForceChunkBytes) != fn (*Doc, u64) void)
        @compileError("signature drift: gzForceChunkBytes");
    if (@TypeOf(core.gzStreamMatcherResidentBytes) != fn (*const Doc) u64)
        @compileError("signature drift: gzStreamMatcherResidentBytes");
    if (@TypeOf(core.gzStreamMatcherResidentReset) != fn (*Doc) void)
        @compileError("signature drift: gzStreamMatcherResidentReset");
    if (@TypeOf(core.gzCacheCopyBytes) != fn (*const Doc) u64)
        @compileError("signature drift: gzCacheCopyBytes");
    if (@TypeOf(core.gzSnapshotProbe) != fn (std.mem.Allocator, []const u8, u64) SnapshotProbe)
        @compileError("signature drift: gzSnapshotProbe");

    // === gz-filter-stream: regression seam signatures (Zig-only test teeth). =
    if (@TypeOf(core.gzInflatedBytes) != fn (*const Doc) u64)
        @compileError("signature drift: gzInflatedBytes");
    if (@TypeOf(core.gzInflateOps) != fn (*const Doc) u64)
        @compileError("signature drift: gzInflateOps");
    if (@TypeOf(core.gzInflateWorkReset) != fn (*Doc) void)
        @compileError("signature drift: gzInflateWorkReset");
    if (@TypeOf(core.gzScanParkWorker) != fn (*Doc, bool) void)
        @compileError("signature drift: gzScanParkWorker");
    if (@TypeOf(core.gzScanStep) != fn (*Doc) GzScanStep)
        @compileError("signature drift: gzScanStep");
    if (@TypeOf(core.gzTouchReplayLane) != fn (*Doc, u64) void)
        @compileError("signature drift: gzTouchReplayLane");

    // === window-budget: instrumentation seam signatures (Zig-only test teeth,
    // NOT C ABI -- no callconv). Their BEHAVIOR is pinned by the wb_* suite +
    // the seam doc comments; drift in src/ fails `zig build` right here. =======
    if (@TypeOf(core.windowChargedBytes) != fn (*const Doc) u64)
        @compileError("signature drift: windowChargedBytes");
    if (@TypeOf(core.navChargedBytes) != fn (*const Doc) u64)
        @compileError("signature drift: navChargedBytes");

    // === csv-gz AC14: compile-proven snapshot-adapter SHAPE assertion on the
    // installed Zig-0.16 std gzip decoder. A future std layout change that would
    // break the value-copy inflate-checkpoint adapter fails the build HERE,
    // loudly (ARCH req6 "compile-proven snapshot adapter"). Frozen in the
    // contract so the implementer cannot silently drop the guard. The fields
    // below are exactly the checkpoint state (input pointer repaired on restore;
    // consumed_bits sub-byte alignment; reader = the <=64 KiB history window;
    // container_metadata = member CRC/ISIZE; state = DEFLATE block/pending) --
    // all value-copyable (no allocator/slice-owning field), verified against the
    // installed std on 0.16.0.
    const Dz = std.compress.flate.Decompress;
    if (!@hasField(Dz, "input")) @compileError("flate.Decompress: no `input` field (checkpoint repairs this pointer on restore)");
    if (!@hasField(Dz, "consumed_bits")) @compileError("flate.Decompress: no `consumed_bits` field (sub-byte bit alignment)");
    if (!@hasField(Dz, "reader")) @compileError("flate.Decompress: no `reader` field (output history window to snapshot)");
    if (!@hasField(Dz, "container_metadata")) @compileError("flate.Decompress: no `container_metadata` field (member CRC/ISIZE state)");
    if (!@hasField(Dz, "state")) @compileError("flate.Decompress: no `state` field (DEFLATE block/pending state)");
    if (@TypeOf(@as(Dz, undefined).consumed_bits) != u3) @compileError("flate.Decompress.consumed_bits must be u3 (bit alignment)");
}

// ===========================================================================
// column-config slice (ARCH-column-config) — additive column-metadata ABI.
// Mirrors api/lesssheet.h "COLUMN METADATA EXTENSION" EXACTLY: the frozen
// constants/flags/enums, the four FIXED-LAYOUT snapshot structs, the 12 new
// `ls_column_*` export fns, and — in the comptime block at the very bottom —
// the authoritative LAYOUT (size/align/offset) + SIGNATURE pins. api/lesssheet.h
// is byte-identical above its appended extension block (AC1); the C
// LS_COLUMN_STATIC_ASSERTs and these Zig pins together freeze the layout on
// every supported target. Planner-owned; amended only with the C header.
//
// Enum-valued snapshot fields are `enum(u32)` (layout-identical to the C
// `uint32_t` the header stores); the RESULT enum is `enum(c_int)` (the C enum
// return type). Nothing here allocates; nothing borrows an ls_str.
// ===========================================================================

/// Mirrors LS_COLUMN_METADATA_ABI_VERSION.
pub const column_metadata_abi_version: u32 = 1;
/// Mirrors LS_COLUMN_BATCH_MAX.
pub const column_batch_max: u32 = 1024;
/// Mirrors LS_COLUMN_INFERENCE_HEAD_MAX_ROWS (byte ceiling is open_head_max_bytes).
pub const column_inference_head_max_rows: u64 = 256;
/// Mirrors LS_COLUMN_INFERENCE_WINDOW_MAX_BYTES.
pub const column_inference_window_max_bytes: u64 = 262144;
/// Mirrors LS_COLUMN_SENTINEL_MAX_BYTES (0 valid — empty sentinel).
pub const column_sentinel_max_bytes: usize = 256;
/// Mirrors LS_COLUMN_CONFLICT_EXAMPLE_MAX_BYTES.
pub const column_conflict_example_max_bytes: usize = 256;
/// Mirrors LS_COLUMN_TYPE_PRECISION_UNSPECIFIED.
pub const column_type_precision_unspecified: u64 = std.math.maxInt(u64);
/// Mirrors LS_COLUMN_TYPE_SCALE_UNSPECIFIED.
pub const column_type_scale_unspecified: i64 = std.math.minInt(i64);
/// Mirrors LS_COLUMN_TYPE_FRACTION_DIGITS_UNSPECIFIED.
pub const column_type_fraction_digits_unspecified: u32 = std.math.maxInt(u32);

/// ls_column_metadata.presence_flags bits (LS_COLUMN_HAS_*).
pub const column_has_declared: u32 = 1 << 0;
pub const column_has_inferred: u32 = 1 << 1;
pub const column_has_override: u32 = 1 << 2;
pub const column_has_proposal: u32 = 1 << 3;
pub const column_has_null_sentinel: u32 = 1 << 4;
pub const column_has_conflict_example: u32 = 1 << 5;

/// ls_column_label_span.flags bits (LS_COLUMN_LABEL_*).
pub const column_label_present: u32 = 1 << 0;
pub const column_label_truncated: u32 = 1 << 1;

/// Mirrors `ls_column_result` (C enum return type; int-sized).
pub const ColumnResult = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    no_column = 2,
    no_value = 3,
    no_proposal = 4,
    buffer_too_small = 5,
    out_of_memory = 6,
};

/// Mirrors `ls_column_type_kind` (stored as uint32_t).
pub const ColumnTypeKind = enum(u32) {
    unknown = 0,
    unsupported = 1,
    text = 2,
    boolean = 3,
    integer = 4,
    decimal = 5,
    date = 6,
    datetime = 7,
};

/// Mirrors `ls_column_type_source` (stored as uint32_t).
pub const ColumnTypeSource = enum(u32) {
    none = 0,
    declared = 1,
    inferred = 2,
    override = 3,
};

/// Mirrors `ls_column_datetime_semantics` (stored as uint32_t).
pub const ColumnDatetimeSemantics = enum(u32) {
    none = 0,
    naive = 1,
    zoned = 2,
};

/// Mirrors `ls_column_inference_state` (stored as uint32_t).
pub const ColumnInferenceState = enum(u32) {
    unrequested = 0,
    queued = 1,
    sampling = 2,
    provisional = 3,
    published = 4,
};

/// Mirrors `ls_column_confidence` (stored as uint32_t).
pub const ColumnConfidence = enum(u32) {
    none = 0,
    low = 1,
    bounded = 2,
    exhaustive = 3,
};

/// Mirrors `ls_column_null_policy_kind` (stored as uint32_t).
pub const ColumnNullPolicyKind = enum(u32) {
    none = 0,
    sentinel = 1,
};

/// Mirrors `ls_column_conflict_state` (stored as uint32_t).
pub const ColumnConflictState = enum(u32) {
    none = 0,
    observed = 1,
    proposed = 2,
};

/// Mirrors `ls_column_inference_job_state` (stored as uint32_t).
pub const ColumnInferenceJobState = enum(u32) {
    idle = 0,
    queued = 1,
    running = 2,
    done = 3,
    cancelled = 4,
};

/// Mirrors `ls_column_type` (48 bytes, align 8). See api/lesssheet.h.
pub const ColumnType = extern struct {
    struct_size: u32,
    abi_version: u32,
    kind: ColumnTypeKind,
    flags: u32,
    decimal_precision: u64,
    decimal_scale: i64,
    datetime_semantics: ColumnDatetimeSemantics,
    datetime_fraction_digits: u32,
    reserved: u64,
};

/// Mirrors `ls_column_metadata` (384 bytes, align 8). `override` is not a Zig
/// keyword (it is a C++/Swift contextual one). See api/lesssheet.h.
pub const ColumnMetadata = extern struct {
    struct_size: u32,
    abi_version: u32,
    column: u32,
    presence_flags: u32,
    generation: u64,
    declared: ColumnType,
    inferred: ColumnType,
    override: ColumnType,
    effective: ColumnType,
    proposal: ColumnType,
    effective_source: ColumnTypeSource,
    inference_state: ColumnInferenceState,
    confidence: ColumnConfidence,
    null_policy: ColumnNullPolicyKind,
    conflict_state: ColumnConflictState,
    null_sentinel_bytes: u32,
    evidence_count: u64,
    sampled_row_count: u64,
    sampled_decoded_bytes: u64,
    empty_count: u64,
    null_count: u64,
    conflict_count: u64,
    conflict_source_row: u64,
    conflict_example_bytes: u32,
    conflict_example_truncated: u32,
    reserved: [4]u64,
};

/// Mirrors `ls_column_inference_status` (112 bytes, align 8). See api/lesssheet.h.
pub const ColumnInferenceStatus = extern struct {
    struct_size: u32,
    abi_version: u32,
    state: ColumnInferenceJobState,
    reserved0: u32,
    request_generation: u64,
    metadata_generation: u64,
    requested_column_count: u32,
    completed_column_count: u32,
    source_bytes_scanned: u64,
    source_bytes_budget: u64,
    rows_scanned: u64,
    rows_budget: u64,
    progress: f64,
    reserved: [4]u64,
};

/// Mirrors `ls_column_label_span` (48 bytes, align 8). See api/lesssheet.h.
pub const ColumnLabelSpan = extern struct {
    struct_size: u32,
    abi_version: u32,
    column: u32,
    flags: u32,
    offset: u64,
    len: u64,
    reserved: [2]u64,
};

// C ABI — see api/lesssheet.h COLUMN METADATA EXTENSION for the full contract.
pub const ls_column_inference_request = core.ls_column_inference_request;
pub const ls_column_inference_cancel = core.ls_column_inference_cancel;
pub const ls_column_metadata_poll = core.ls_column_metadata_poll;
pub const ls_column_metadata_get_many = core.ls_column_metadata_get_many;
pub const ls_column_override_set = core.ls_column_override_set;
pub const ls_column_override_clear = core.ls_column_override_clear;
pub const ls_column_null_sentinel_set = core.ls_column_null_sentinel_set;
pub const ls_column_null_sentinel_clear = core.ls_column_null_sentinel_clear;
pub const ls_column_inference_accept_proposal = core.ls_column_inference_accept_proposal;
pub const ls_column_labels_copy_many = core.ls_column_labels_copy_many;
pub const ls_column_null_sentinel_copy = core.ls_column_null_sentinel_copy;
pub const ls_column_conflict_example_copy = core.ls_column_conflict_example_copy;

comptime {
    // --- Layout pins: sizes/aligns/offsets identical to the C header's
    // LS_COLUMN_STATIC_ASSERTs (authoritative on every supported target). ------
    if (@sizeOf(ColumnType) != 48) @compileError("layout drift: ls_column_type size != 48");
    if (@alignOf(ColumnType) != 8) @compileError("layout drift: ls_column_type align != 8");
    if (@offsetOf(ColumnType, "struct_size") != 0) @compileError("layout drift: ColumnType.struct_size");
    if (@offsetOf(ColumnType, "abi_version") != 4) @compileError("layout drift: ColumnType.abi_version");
    if (@offsetOf(ColumnType, "kind") != 8) @compileError("layout drift: ColumnType.kind");
    if (@offsetOf(ColumnType, "flags") != 12) @compileError("layout drift: ColumnType.flags");
    if (@offsetOf(ColumnType, "decimal_precision") != 16) @compileError("layout drift: ColumnType.decimal_precision");
    if (@offsetOf(ColumnType, "decimal_scale") != 24) @compileError("layout drift: ColumnType.decimal_scale");
    if (@offsetOf(ColumnType, "datetime_semantics") != 32) @compileError("layout drift: ColumnType.datetime_semantics");
    if (@offsetOf(ColumnType, "datetime_fraction_digits") != 36) @compileError("layout drift: ColumnType.datetime_fraction_digits");
    if (@offsetOf(ColumnType, "reserved") != 40) @compileError("layout drift: ColumnType.reserved");

    if (@sizeOf(ColumnMetadata) != 384) @compileError("layout drift: ls_column_metadata size != 384");
    if (@alignOf(ColumnMetadata) != 8) @compileError("layout drift: ls_column_metadata align != 8");
    if (@offsetOf(ColumnMetadata, "struct_size") != 0) @compileError("layout drift: ColumnMetadata.struct_size");
    if (@offsetOf(ColumnMetadata, "abi_version") != 4) @compileError("layout drift: ColumnMetadata.abi_version");
    if (@offsetOf(ColumnMetadata, "column") != 8) @compileError("layout drift: ColumnMetadata.column");
    if (@offsetOf(ColumnMetadata, "presence_flags") != 12) @compileError("layout drift: ColumnMetadata.presence_flags");
    if (@offsetOf(ColumnMetadata, "generation") != 16) @compileError("layout drift: ColumnMetadata.generation");
    if (@offsetOf(ColumnMetadata, "declared") != 24) @compileError("layout drift: ColumnMetadata.declared");
    if (@offsetOf(ColumnMetadata, "inferred") != 72) @compileError("layout drift: ColumnMetadata.inferred");
    if (@offsetOf(ColumnMetadata, "override") != 120) @compileError("layout drift: ColumnMetadata.override");
    if (@offsetOf(ColumnMetadata, "effective") != 168) @compileError("layout drift: ColumnMetadata.effective");
    if (@offsetOf(ColumnMetadata, "proposal") != 216) @compileError("layout drift: ColumnMetadata.proposal");
    if (@offsetOf(ColumnMetadata, "effective_source") != 264) @compileError("layout drift: ColumnMetadata.effective_source");
    if (@offsetOf(ColumnMetadata, "inference_state") != 268) @compileError("layout drift: ColumnMetadata.inference_state");
    if (@offsetOf(ColumnMetadata, "confidence") != 272) @compileError("layout drift: ColumnMetadata.confidence");
    if (@offsetOf(ColumnMetadata, "null_policy") != 276) @compileError("layout drift: ColumnMetadata.null_policy");
    if (@offsetOf(ColumnMetadata, "conflict_state") != 280) @compileError("layout drift: ColumnMetadata.conflict_state");
    if (@offsetOf(ColumnMetadata, "null_sentinel_bytes") != 284) @compileError("layout drift: ColumnMetadata.null_sentinel_bytes");
    if (@offsetOf(ColumnMetadata, "evidence_count") != 288) @compileError("layout drift: ColumnMetadata.evidence_count");
    if (@offsetOf(ColumnMetadata, "sampled_row_count") != 296) @compileError("layout drift: ColumnMetadata.sampled_row_count");
    if (@offsetOf(ColumnMetadata, "sampled_decoded_bytes") != 304) @compileError("layout drift: ColumnMetadata.sampled_decoded_bytes");
    if (@offsetOf(ColumnMetadata, "empty_count") != 312) @compileError("layout drift: ColumnMetadata.empty_count");
    if (@offsetOf(ColumnMetadata, "null_count") != 320) @compileError("layout drift: ColumnMetadata.null_count");
    if (@offsetOf(ColumnMetadata, "conflict_count") != 328) @compileError("layout drift: ColumnMetadata.conflict_count");
    if (@offsetOf(ColumnMetadata, "conflict_source_row") != 336) @compileError("layout drift: ColumnMetadata.conflict_source_row");
    if (@offsetOf(ColumnMetadata, "conflict_example_bytes") != 344) @compileError("layout drift: ColumnMetadata.conflict_example_bytes");
    if (@offsetOf(ColumnMetadata, "conflict_example_truncated") != 348) @compileError("layout drift: ColumnMetadata.conflict_example_truncated");
    if (@offsetOf(ColumnMetadata, "reserved") != 352) @compileError("layout drift: ColumnMetadata.reserved");

    if (@sizeOf(ColumnInferenceStatus) != 112) @compileError("layout drift: ls_column_inference_status size != 112");
    if (@alignOf(ColumnInferenceStatus) != 8) @compileError("layout drift: ls_column_inference_status align != 8");
    if (@offsetOf(ColumnInferenceStatus, "state") != 8) @compileError("layout drift: ColumnInferenceStatus.state");
    if (@offsetOf(ColumnInferenceStatus, "reserved0") != 12) @compileError("layout drift: ColumnInferenceStatus.reserved0");
    if (@offsetOf(ColumnInferenceStatus, "request_generation") != 16) @compileError("layout drift: ColumnInferenceStatus.request_generation");
    if (@offsetOf(ColumnInferenceStatus, "metadata_generation") != 24) @compileError("layout drift: ColumnInferenceStatus.metadata_generation");
    if (@offsetOf(ColumnInferenceStatus, "requested_column_count") != 32) @compileError("layout drift: ColumnInferenceStatus.requested_column_count");
    if (@offsetOf(ColumnInferenceStatus, "completed_column_count") != 36) @compileError("layout drift: ColumnInferenceStatus.completed_column_count");
    if (@offsetOf(ColumnInferenceStatus, "source_bytes_scanned") != 40) @compileError("layout drift: ColumnInferenceStatus.source_bytes_scanned");
    if (@offsetOf(ColumnInferenceStatus, "source_bytes_budget") != 48) @compileError("layout drift: ColumnInferenceStatus.source_bytes_budget");
    if (@offsetOf(ColumnInferenceStatus, "rows_scanned") != 56) @compileError("layout drift: ColumnInferenceStatus.rows_scanned");
    if (@offsetOf(ColumnInferenceStatus, "rows_budget") != 64) @compileError("layout drift: ColumnInferenceStatus.rows_budget");
    if (@offsetOf(ColumnInferenceStatus, "progress") != 72) @compileError("layout drift: ColumnInferenceStatus.progress");
    if (@offsetOf(ColumnInferenceStatus, "reserved") != 80) @compileError("layout drift: ColumnInferenceStatus.reserved");

    if (@sizeOf(ColumnLabelSpan) != 48) @compileError("layout drift: ls_column_label_span size != 48");
    if (@alignOf(ColumnLabelSpan) != 8) @compileError("layout drift: ls_column_label_span align != 8");
    if (@offsetOf(ColumnLabelSpan, "column") != 8) @compileError("layout drift: ColumnLabelSpan.column");
    if (@offsetOf(ColumnLabelSpan, "flags") != 12) @compileError("layout drift: ColumnLabelSpan.flags");
    if (@offsetOf(ColumnLabelSpan, "offset") != 16) @compileError("layout drift: ColumnLabelSpan.offset");
    if (@offsetOf(ColumnLabelSpan, "len") != 24) @compileError("layout drift: ColumnLabelSpan.len");
    if (@offsetOf(ColumnLabelSpan, "reserved") != 32) @compileError("layout drift: ColumnLabelSpan.reserved");

    // --- Signature pins: C-ABI drift in src/ fails `zig build` right here. ----
    if (@TypeOf(core.ls_column_inference_request) != fn (*Doc, ?[*]const u32, u32) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_inference_request");
    if (@TypeOf(core.ls_column_inference_cancel) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_column_inference_cancel");
    if (@TypeOf(core.ls_column_metadata_poll) != fn (*const Doc, *ColumnInferenceStatus) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_metadata_poll");
    if (@TypeOf(core.ls_column_metadata_get_many) != fn (*const Doc, ?[*]const u32, u32, ?[*]ColumnMetadata, u32, *u64) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_metadata_get_many");
    if (@TypeOf(core.ls_column_override_set) != fn (*Doc, u32, *const ColumnType) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_override_set");
    if (@TypeOf(core.ls_column_override_clear) != fn (*Doc, u32) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_override_clear");
    if (@TypeOf(core.ls_column_null_sentinel_set) != fn (*Doc, u32, ?[*]const u8, usize) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_null_sentinel_set");
    if (@TypeOf(core.ls_column_null_sentinel_clear) != fn (*Doc, u32) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_null_sentinel_clear");
    if (@TypeOf(core.ls_column_inference_accept_proposal) != fn (*Doc, u32) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_inference_accept_proposal");
    if (@TypeOf(core.ls_column_labels_copy_many) != fn (*const Doc, ?[*]const u32, u32, ?[*]ColumnLabelSpan, u32, ?[*]u8, usize, *usize) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_labels_copy_many");
    if (@TypeOf(core.ls_column_null_sentinel_copy) != fn (*const Doc, u32, ?[*]u8, usize, *usize) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_null_sentinel_copy");
    if (@TypeOf(core.ls_column_conflict_example_copy) != fn (*const Doc, u32, ?[*]u8, usize, *usize) callconv(.c) ColumnResult)
        @compileError("signature drift: ls_column_conflict_example_copy");
}

// ===========================================================================
// network-source slice (ARCH-network-source) — additive network-open C ABI +
// Zig-only test seams. Mirrors api/lesssheet.h "NETWORK SOURCE EXTENSION"
// EXACTLY: the new error taxonomy, job-state enum, the opaque job handle, the
// job-status snapshot struct, and the four ls_open_url_* / ls_net_open_*
// export fns. api/lesssheet.h is byte-identical ABOVE its appended block (AC2);
// this section + the comptime pins at the bottom freeze the additive surface.
// Planner-owned; amended only with the C header.
//
// TEST VEHICLE (planner decision, ARCH-sanctioned). The ARCH delegated the
// choice of "fixture HTTP server OR injectable transport seam, whichever fits
// std.http.Client testability best." We freeze an INJECTABLE TRANSPORT seam:
// std.http.Client in Zig 0.16 is Io-coupled and awkward to point at an
// in-process server hermetically (TLS certs, ephemeral ports, timeout/hang and
// DNS/redirect simulation are all flaky or infeasible in a unit test), whereas
// the GENUINELY NOVEL logic of this slice — the async job lifecycle, the
// range-probe/fallback decision, the persist-once spool (never-refetch, 0600,
// unlinked), the bounded RAM cache, and the error-taxonomy mapping — is exactly
// what an injected transport exercises deterministically. std.http.Client's own
// job (real DNS/TCP/TLS/redirects) is std's responsibility; its faithful
// mapping to this taxonomy over a real localhost http:// AND https:// server is
// a REVIEWER/human target-host probe (mirroring this repo's StreamCopyWallClock
// and "heavy cases stay out of the gate" precedents), NOT a hermetic gate test.
//
// The seams below mirror the gz*/openWithAllocator precedent (Zig-only, NEVER
// the C ABI, so api/lesssheet.h stays BYTE-IDENTICAL): tests build a NetFixture
// value describing the server/transport behavior and start a job through
// `openUrlStartFake` (the injected-transport twin of the real ls_open_url_start,
// exactly as openWithAllocator twins ls_open); instrumentation seams
// (netRangeMode / netFetchCount / netResidentBytes / netSpoolStore /
// netForceCacheBytes on a DONE doc; netJobProbe on the job) read
// implementer-owned base.Document / job state DEFAULTED to zero, so the SEED
// reports zero/unwired and every transport-dependent AC is RED until the
// http_range Source + real transport are built + wired. The http_range Source
// TYPE INTERNALS stay implementer-owned in src/ (the af83db9 reader-interface
// ownership boundary / csv-gz Decision 1-C): tests bind only to this frozen
// vocabulary + the C ABI, never to a SourceKind variant or transport vtable.
// ===========================================================================

/// Mirrors LS_NET_PROGRESS_UNKNOWN: ls_net_open_status.progress sentinel for an
/// unknown total length (frontend shows an indeterminate spinner + byte count).
pub const net_progress_unknown: f64 = -1.0;

/// Mirrors LS_BYTES_TOTAL_UNKNOWN (never-full-download-streaming amendment a):
/// the ls_index_poll().bytes_total sentinel for an unknown-length network
/// stream whose total size is not yet known. While it holds,
/// ls_index_poll().complete stays false and bytes_scanned is the
/// fetched/indexed high-water; at stream EOF bytes_total becomes the final
/// size. DISTINCT from the empty document {0, 0, true}. Network-only. See
/// api/lesssheet.h NEVER-FULL-DOWNLOAD STREAMING EXTENSION.
pub const bytes_total_unknown: u64 = std.math.maxInt(u64);

/// Mirrors `ls_net_status`. Distinct, stable values; meaningful only when the
/// job state is `.failed`. `unreachable_` mirrors LS_NET_ERROR_UNREACHABLE
/// (`unreachable` is a Zig keyword — the trailing underscore is a Zig-side name
/// only; the enum VALUE (2) is what crosses the ABI).
pub const NetStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    unreachable_ = 2,
    timeout = 3,
    http_status = 4,
    too_many_redirects = 5,
    io = 6,
    cancelled = 7,
};

/// Mirrors `ls_net_open_state`: the async open-job state.
pub const NetOpenState = enum(c_int) {
    pending = 0,
    fetching = 1,
    done = 2,
    failed = 3,
    cancelled = 4,
};

/// Mirrors `ls_net_open_job`: opaque async open-job handle, core-owned. Distinct
/// from `Doc` — a `.done` job PRODUCES a `Doc` that outlives the job.
pub const NetOpenJob = opaque {};

/// Mirrors `ls_net_open_status` (poll snapshot). Field order matches the C
/// struct exactly (all 8-byte members first, then the two enums + http_status +
/// reserved). `err` mirrors C `error` (`error` is a Zig keyword; the field name
/// does not cross the ABI). See api/lesssheet.h for every field's validity rule.
pub const NetOpenStatus = extern struct {
    progress: f64,
    bytes_fetched: u64,
    bytes_total: u64,
    doc: ?*Doc,
    state: NetOpenState,
    err: NetStatus,
    http_status: i32,
    reserved: i32,
};

// --- Zig-only test-seam VALUE types (NEVER the C ABI) -----------------------

/// A transport/server FAULT the injected fake transport simulates (NetFixture.
/// fault), each mapping to one terminal NetStatus so the error taxonomy (AC7)
/// is reproducible hermetically:
///   none    — serve normally.
///   connect — DNS/TCP/TLS connection failure -> `.unreachable_`.
///   timeout — no forward progress within the timeout -> `.timeout`.
///   io      — local spool create/write failure -> `.io`.
pub const NetFault = enum(u8) {
    none = 0,
    connect = 1,
    timeout = 2,
    io = 3,
};

/// The Source's resolved access mode (netRangeMode), proving AC3 vs AC4:
///   unknown             — not yet resolved / not a network doc.
///   random_access       — the server honored Range (206/Content-Range).
///   sequential_fallback — the server ignored Range / gave no usable length, so
///                         the resource is STREAMED sequentially into the
///                         spool on demand (a forward-draining GET, or the
///                         gzip Source composed over that growing spool) and
///                         is NEVER fully downloaded (never-full-download-
///                         streaming slice re-documents this from the old
///                         download-all meaning; the enum VALUE is unchanged).
///                         Serves plain CSV over a no-range server and any
///                         unknown-length stream.
pub const NetRangeMode = enum(u8) {
    unknown = 0,
    random_access = 1,
    sequential_fallback = 2,
};

/// The fake transport / server description a test builds and hands to
/// `openUrlStartFake`. Borrowed only for that call (the job copies what it
/// keeps — `body` included, exactly like ls_search_start copies its request).
/// Defaults describe a well-behaved range server that serves `body`.
///   body            — the full resource bytes the "server" holds.
///   honor_ranges    — true: answer the probe with 206 + Content-Range (random
///                     access); false: ignore Range and answer 200 (fallback).
///   advertise_length— whether a usable Content-Length/Content-Range total is
///                     present (false forces the fallback path even with 206).
///   http_status     — the status to return (200/206 success; 404/401/403/… ->
///                     LS_NET_ERROR_HTTP_STATUS carrying this number).
///   redirect_hops   — redirect responses to emit before serving (exercises the
///                     cap / LS_NET_ERROR_TOO_MANY_REDIRECTS).
///   fault           — a transport fault to inject (see NetFault).
///   stall           — never complete the fetch until cancelled (for the cancel
///                     AC — lets a test observe a mid-flight FETCHING job).
/// STREAMING SEMANTICS (never-full-download-streaming slice): honor_ranges +
/// advertise_length select the FILL strategy, ALL streamed (never fully
/// downloaded -- TD3/TD4): {honor_ranges=true, advertise_length=true} -> 206 +
/// Content-Range total -> RANDOM fill (known total); {false, true} -> 200 +
/// Content-Length -> SEQUENTIAL fill (known total); {*, advertise_length=false}
/// -> no usable total -> SEQUENTIAL fill of an UNKNOWN-length stream
/// (ls_index_poll().bytes_total == bytes_total_unknown until EOF). A genuinely
/// EMPTY resource is {body="", advertise_length=true} (Content-Length: 0),
/// DISTINCT from an unknown stream. `withhold` gates incremental delivery.
pub const NetFixture = struct {
    body: []const u8 = &.{},
    honor_ranges: bool = true,
    advertise_length: bool = true,
    http_status: u16 = 200,
    redirect_hops: u32 = 0,
    fault: NetFault = .none,
    stall: bool = false,
    /// Withhold-then-release control (AC13): a released-byte high-water the
    /// TEST raises to model a server that has streamed only a prefix so far.
    /// When set, the (sequential) fake serves resource bytes only in
    /// [0, withhold.load(.acquire)); a demand beyond it fetches nothing past
    /// `released` and the frontier stays SCANNING (with visible progress)
    /// until the test raises it (e.g. `gate.store(body.len, .release)`),
    /// which advances the demand to completion. `null` == serve the whole
    /// body immediately (the default). The pointee is borrowed for the job's
    /// whole lifetime (the test owns it and must outlive the job). Zig-only.
    withhold: ?*std.atomic.Value(u64) = null,
    /// Post-open stream DROP (AC16, the gzip damaged-EOF analog — DISTINCT from
    /// `withhold`, which WAITS for more): the (sequential) fake serves resource
    /// bytes only in [0, drop_after) and then signals a hard stream END, so a
    /// demand past it TERMINATES the document at the received bytes (received
    /// rows stay servable; index/search/filter reach their terminal states over
    /// the received prefix). `null` == the stream delivers the whole body.
    drop_after: ?u64 = null,
};

/// netSpoolStore result: the private local spool file's state (AC14 spool
/// hygiene). Mirrors the gzip CheckpointStore seam shape. `present == false`
/// means no spool file exists (not a network doc, or already released).
pub const NetSpoolStore = struct {
    present: bool,
    bytes: u64,
    mode: u32,
    unlinked: bool,
};

/// netJobProbe result: an in-flight/cancelled JOB's resource state (AC8), read
/// directly off the job (the cancel path never produces a doc). After a
/// cancelled job settles, `spool_present` is false (all resources released).
pub const NetJobProbe = struct {
    spool_present: bool,
    fetch_count: u64,
};

/// `decideProbe` result (never-full-download-streaming AC17): the pure
/// fill-strategy / length classification from a successful (2xx) probe's raw
/// signals. Planner-owned Zig-only value type (like OpenBudget / NetSpoolStore
/// -- never the C ABI). Replaces the old net_source-private `Probe` verdict at
/// the seam: `range = !is_gz` is DROPPED (gzip composes over the spool, TD4)
/// and `length_known` is ADDED (splits Content-Length: 0 from an absent
/// length, TD5).
pub const ProbeDecision = struct {
    /// true -> RANDOM fill (206 + a usable Content-Range total); false ->
    /// SEQUENTIAL fill (200, or a 206 without a usable total). No longer
    /// forced false for a gzip resource.
    range: bool,
    /// The resource total when `length_known`; 0 / don't-care otherwise.
    total: u64,
    /// false -> an UNKNOWN-length stream (no Content-Length / chunked / a 206
    /// without a usable Content-Range total): the total firms only at EOF.
    /// A present Content-Length of 0 is length_known=true, total=0 (empty).
    length_known: bool,
    /// The leading-magic (1f 8b) verdict on the fetched head.
    is_gz: bool,
};

// --- C ABI re-exports (see api/lesssheet.h NETWORK SOURCE EXTENSION) ---------
pub const ls_open_url_start = core.ls_open_url_start;
pub const ls_net_open_poll = core.ls_net_open_poll;
pub const ls_net_open_cancel = core.ls_net_open_cancel;
pub const ls_net_open_release = core.ls_net_open_release;

// --- Zig-only test seams (NOT the C ABI — like openWithAllocator / gz*) ------

/// Injected-transport twin of `ls_open_url_start` (production uses the real
/// std.http.Client transport; tests use the NetFixture-described fake). Same
/// job handle, same lifecycle, same synchronous scheme/option validation; only
/// the byte provider differs. The fixture (and its body) is borrowed only for
/// this call. SEED: no transport is wired, so a valid-scheme open fails
/// `.unreachable_` and ignores the fixture -> every transport-dependent AC RED.
pub const openUrlStartFake = core.openUrlStartFake;

/// AC3/AC4: the DONE doc's resolved network access mode. `.unknown` for a
/// non-network doc. SEED: `.unknown`.
pub const netRangeMode = core.netRangeMode;
/// AC6/AC13: cumulative network fetches this doc's Source issued (never-refetch
/// and no-cross-open-cache proofs count these). 0 for a non-network doc. SEED: 0.
pub const netFetchCount = core.netFetchCount;
/// AC15: the network Source's current resident RAM state for this doc (bound:
/// 16 MiB; the spool is disk-resident, not counted). 0 for a non-network doc.
pub const netResidentBytes = core.netResidentBytes;
/// AC14: the private spool file's present/bytes/mode/unlinked state (see
/// NetSpoolStore). SEED: {false,0,0,false}.
pub const netSpoolStore = core.netSpoolStore;
/// AC6: cap the network Source's resident RAM cache to `n` bytes (0 == force
/// full eviction) so a test can prove a re-access after eviction is served from
/// the spool with zero new fetches. SEED: stored, unused.
pub const netForceCacheBytes = core.netForceCacheBytes;
/// AC8: an in-flight/cancelled JOB's resource state (see NetJobProbe), read off
/// the job (cancel produces no doc). SEED: {false,0}.
pub const netJobProbe = core.netJobProbe;

/// AC17 unit seam (never-full-download-streaming): the PURE fill-strategy /
/// length classification from a probe's raw signals -- `status` (2xx),
/// `content_length` (the 200 whole-resource length; null == header absent),
/// `content_range_total` (the 206 total; null == absent / unusable / `*`),
/// `is_gz` (1f 8b head magic). Exposed from net_source.zig so the two live
/// bugs it encodes are unit-testable without a real HTTP server (ARCH TD12).
/// SEED: the OLD logic (forces range=!is_gz; always length_known) -> RED.
pub const decideProbe = core.decideProbe;
/// AC17 unit seam: parses the resource's TRUE total out of a `Content-Range:
/// bytes start-end/total` response header; null when absent or `*`. Pure.
pub const parseContentRangeTotal = core.parseContentRangeTotal;

comptime {
    // --- C-ABI signature pins: drift in src/ fails `zig build` right here. ----
    if (@TypeOf(core.ls_open_url_start) != fn ([*]const u8, usize, ?*const OpenOptions) callconv(.c) ?*NetOpenJob)
        @compileError("signature drift: ls_open_url_start");
    if (@TypeOf(core.ls_net_open_poll) != fn (*const NetOpenJob) callconv(.c) NetOpenStatus)
        @compileError("signature drift: ls_net_open_poll");
    if (@TypeOf(core.ls_net_open_cancel) != fn (*NetOpenJob) callconv(.c) void)
        @compileError("signature drift: ls_net_open_cancel");
    if (@TypeOf(core.ls_net_open_release) != fn (*NetOpenJob) callconv(.c) void)
        @compileError("signature drift: ls_net_open_release");

    // --- Zig-only test-seam signature pins (no callconv). --------------------
    if (@TypeOf(core.openUrlStartFake) != fn (*const NetFixture, [*]const u8, usize, ?*const OpenOptions) ?*NetOpenJob)
        @compileError("signature drift: openUrlStartFake");
    if (@TypeOf(core.netRangeMode) != fn (*const Doc) NetRangeMode)
        @compileError("signature drift: netRangeMode");
    if (@TypeOf(core.netFetchCount) != fn (*const Doc) u64)
        @compileError("signature drift: netFetchCount");
    if (@TypeOf(core.netResidentBytes) != fn (*const Doc) u64)
        @compileError("signature drift: netResidentBytes");
    if (@TypeOf(core.netSpoolStore) != fn (*const Doc) NetSpoolStore)
        @compileError("signature drift: netSpoolStore");
    if (@TypeOf(core.netForceCacheBytes) != fn (*Doc, u64) void)
        @compileError("signature drift: netForceCacheBytes");
    if (@TypeOf(core.netJobProbe) != fn (*const NetOpenJob) NetJobProbe)
        @compileError("signature drift: netJobProbe");

    // never-full-download-streaming: decideProbe / parseContentRangeTotal
    // exposed as pure Zig-only unit seams (AC17). content_length is ?u64 so
    // decideProbe can split Content-Length: 0 (empty) from an absent length.
    if (@TypeOf(core.decideProbe) != fn (i32, ?u64, ?u64, bool) ProbeDecision)
        @compileError("signature drift: decideProbe");
    if (@TypeOf(core.parseContentRangeTotal) != fn ([]const u8) ?u64)
        @compileError("signature drift: parseContentRangeTotal");
}
