//! less-sheet core — file access, parsing, and windowed row access.
//! Implementation lands here via the aidev pipeline; contracts/ and tests/ are
//! planner-owned. The public surface is pinned by contracts/api.zig and must
//! implement api/lesssheet.h exactly (see both for the full semantics).
//!
//! SEED STATE: every function below is an unimplemented stub — it compiles
//! (conformance green) and fails every behavior test (suite red). Replace the
//! bodies; do not change the signatures (the contract pins them).

const std = @import("std");
const api = @import("api");

const empty_str: api.Str = .{ .ptr = "", .len = 0 };

/// See api/lesssheet.h `ls_open`. Must equal
/// `openHeadWithAllocator(<default allocator>, path, out_doc)`.
pub export fn ls_open(path: [*:0]const u8, out_doc: *?*api.Doc) callconv(.c) api.Status {
    _ = path;
    out_doc.* = null;
    return .io; // stub: unimplemented
}

/// Zig-level seam pinned by the contract: identical to `ls_open` but every
/// heap allocation for the document goes through `gpa` (file mapping exempt);
/// `ls_close` returns it all to the same allocator.
pub fn openHeadWithAllocator(gpa: std.mem.Allocator, path: [*:0]const u8, out_doc: *?*api.Doc) api.Status {
    _ = gpa;
    _ = path;
    out_doc.* = null;
    return .io; // stub: unimplemented
}

/// See api/lesssheet.h `ls_close`.
pub export fn ls_close(doc: *api.Doc) callconv(.c) void {
    _ = doc; // stub: unimplemented
}

/// See api/lesssheet.h `ls_data_row_count`.
pub export fn ls_data_row_count(doc: *const api.Doc) callconv(.c) u32 {
    _ = doc;
    return 0; // stub: unimplemented
}

/// See api/lesssheet.h `ls_column_count`.
pub export fn ls_column_count(doc: *const api.Doc) callconv(.c) u32 {
    _ = doc;
    return 0; // stub: unimplemented
}

/// See api/lesssheet.h `ls_header_suggested`.
pub export fn ls_header_suggested(doc: *const api.Doc) callconv(.c) bool {
    _ = doc;
    return false; // stub: unimplemented
}

/// See api/lesssheet.h `ls_cell`. Zero allocation; total function.
pub export fn ls_cell(doc: *const api.Doc, row: u32, col: u32) callconv(.c) api.Str {
    _ = doc;
    _ = row;
    _ = col;
    return empty_str; // stub: unimplemented
}

/// See api/lesssheet.h `ls_header_cell`. Zero allocation; total function.
pub export fn ls_header_cell(doc: *const api.Doc, col: u32) callconv(.c) api.Str {
    _ = doc;
    _ = col;
    return empty_str; // stub: unimplemented
}
