//! Frozen Zig-side contract for the less-sheet core (walking-skeleton slice).
//!
//! This file is planner-owned. It mirrors the workspace-frozen C header
//! `api/lesssheet.h` EXACTLY — names, types, values, and semantics; the two
//! files are amended only together, by the planner. The comptime block below
//! pins every public signature: any drift in `src/` fails `zig build`.
//!
//! Tests (backend/tests/) import ONLY this module (`@import("api")`).
//!
//! Semantics are documented in full in api/lesssheet.h (ownership, validity,
//! threading, CSV dialect, header rule, pinned numeric grammar). Summary of
//! the implementation obligations:
//!   - `ls_*` symbols are `pub export fn` with the C calling convention and
//!     implement the header exactly.
//!   - `ls_open` must behave exactly like `openHeadWithAllocator` called with
//!     the implementation's default allocator.
//!   - Every heap allocation for a document's storage goes through the
//!     allocator the document was opened with, and `ls_close` returns all of
//!     it to that allocator. Mapping the source file itself (mmap) is exempt.
//!   - The accessor paths (`ls_data_row_count`, `ls_column_count`,
//!     `ls_header_suggested`, `ls_cell`, `ls_header_cell`) perform ZERO
//!     allocator calls and never fail; out-of-range access returns the empty
//!     string. `Str.ptr` is never null.
//!   - Open reads O(loaded head) bytes: at most one header record plus
//!     `head_max_data_rows` data records are materialized, independent of
//!     file size. Source files are never modified, locked, or copied.

const std = @import("std");
const core = @import("core");

/// Mirrors LS_HEAD_MAX_DATA_ROWS in api/lesssheet.h: the maximum number of
/// DATA rows this slice materializes on open (the loaded head window).
pub const head_max_data_rows: u32 = 200;

/// Mirrors `ls_status`. Failure codes are distinct and stable.
pub const Status = enum(c_int) {
    ok = 0,
    not_found = 1,
    permission_denied = 2,
    io = 3,
};

/// Mirrors `ls_doc`: opaque document handle, core-owned.
pub const Doc = opaque {};

/// Mirrors `ls_str`: borrowed UTF-8 bytes, NOT NUL-terminated, `ptr` never
/// null, valid until `ls_close` on the owning document.
pub const Str = extern struct {
    ptr: [*]const u8,
    len: usize,

    /// View the borrowed bytes as a slice (test/consumer convenience).
    pub fn slice(self: Str) []const u8 {
        return self.ptr[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Public surface (re-exported from the implementation; tests use only these).
// ---------------------------------------------------------------------------

/// C ABI — see api/lesssheet.h for the full contract of each.
pub const ls_open = core.ls_open;
pub const ls_close = core.ls_close;
pub const ls_data_row_count = core.ls_data_row_count;
pub const ls_column_count = core.ls_column_count;
pub const ls_header_suggested = core.ls_header_suggested;
pub const ls_cell = core.ls_cell;
pub const ls_header_cell = core.ls_header_cell;

/// Zig-level seam for tests: identical to `ls_open` but with an explicit
/// allocator. `ls_open` == `openHeadWithAllocator(default allocator, ...)`.
/// All heap allocation for the document goes through `gpa` (file mapping is
/// exempt) and `ls_close` returns it to the same allocator — so tests can
/// count allocations (zero-allocation cell access) and detect leaks.
pub const openHeadWithAllocator = core.openHeadWithAllocator;

// ---------------------------------------------------------------------------
// Conformance pins — signature drift in src/ fails `zig build` right here.
// ---------------------------------------------------------------------------
comptime {
    if (@TypeOf(core.ls_open) != fn ([*:0]const u8, *?*Doc) callconv(.c) Status)
        @compileError("signature drift: ls_open");
    if (@TypeOf(core.ls_close) != fn (*Doc) callconv(.c) void)
        @compileError("signature drift: ls_close");
    if (@TypeOf(core.ls_data_row_count) != fn (*const Doc) callconv(.c) u32)
        @compileError("signature drift: ls_data_row_count");
    if (@TypeOf(core.ls_column_count) != fn (*const Doc) callconv(.c) u32)
        @compileError("signature drift: ls_column_count");
    if (@TypeOf(core.ls_header_suggested) != fn (*const Doc) callconv(.c) bool)
        @compileError("signature drift: ls_header_suggested");
    if (@TypeOf(core.ls_cell) != fn (*const Doc, u32, u32) callconv(.c) Str)
        @compileError("signature drift: ls_cell");
    if (@TypeOf(core.ls_header_cell) != fn (*const Doc, u32) callconv(.c) Str)
        @compileError("signature drift: ls_header_cell");
    if (@TypeOf(core.openHeadWithAllocator) != fn (std.mem.Allocator, [*:0]const u8, *?*Doc) Status)
        @compileError("signature drift: openHeadWithAllocator");
}
