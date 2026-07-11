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
}
