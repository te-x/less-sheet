//! Frozen Zig-side contract for the less-sheet core (viewer-ui slice).
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
//! frontier, threading lanes, dialect grammar, sniffing, header rule).
//! Summary of the implementation obligations:
//!   - `ls_*` symbols are `pub export fn` with the C calling convention and
//!     implement the header exactly.
//!   - `ls_open` must behave exactly like `openWithAllocator` called with the
//!     implementation's default allocator.
//!   - Every heap allocation for a document goes through the allocator the
//!     document was opened with, and `ls_close` returns all of it to that
//!     allocator (after cancelling + joining core-owned threads). Mapping the
//!     source file itself (mmap) is exempt.
//!   - Only `ls_open` and `ls_window_set` may allocate. All accessors and
//!     polls perform ZERO allocator calls and never fail; once a scan has
//!     reported completion, no further internal allocation happens until the
//!     next mutating call.
//!   - `ls_open` consumes at most `open_head_max_bytes` of the file and
//!     leaves the frontier covering at least min(total rows,
//!     `open_ready_min_rows`) when they fit that budget.
//!   - `ls_window_set` never advances the frontier; the frontier is monotone
//!     and advances only via open's head scan, the AUTO background indexer,
//!     and jump-scans. The core may own background threads (std.Thread);
//!     tests pin observable behavior, never scheduling.

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
};

/// Mirrors `ls_dialect`: the effective dialect report.
pub const Dialect = extern struct {
    separator: u8,
    quote: u8,
    has_quote: bool,
    header: bool,
    separator_forced: bool,
    quote_forced: bool,
    header_forced: bool,
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
pub const ls_header_cell = core.ls_header_cell;
pub const ls_jump_start = core.ls_jump_start;
pub const ls_jump_cancel = core.ls_jump_cancel;
pub const ls_jump_poll = core.ls_jump_poll;

/// Zig-level seam for tests: identical to `ls_open` but with an explicit
/// allocator. `ls_open` == `openWithAllocator(default allocator, ...)`.
/// All heap allocation for the document — including its background scan
/// threads' document-owned state — goes through `gpa` (file mapping is
/// exempt) and `ls_close` returns it to the same allocator, so tests can
/// count allocations (zero-allocation access paths) and detect leaks.
pub const openWithAllocator = core.openWithAllocator;

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
    if (@TypeOf(core.ls_header_cell) != fn (*const Doc, u32) callconv(.c) Str)
        @compileError("signature drift: ls_header_cell");
    if (@TypeOf(core.ls_jump_start) != fn (*Doc, u64) callconv(.c) void)
        @compileError("signature drift: ls_jump_start");
    if (@TypeOf(core.ls_jump_cancel) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_jump_cancel");
    if (@TypeOf(core.ls_jump_poll) != fn (*const Doc) callconv(.c) JumpStatus)
        @compileError("signature drift: ls_jump_poll");
    if (@TypeOf(core.openWithAllocator) != fn (std.mem.Allocator, [*:0]const u8, ?*const OpenOptions, *?*Doc) Status)
        @compileError("signature drift: openWithAllocator");
}
