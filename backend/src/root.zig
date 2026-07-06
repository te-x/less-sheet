//! less-sheet core — file access, parsing, and windowed row access.
//! Implements api/lesssheet.h exactly (see it and contracts/api.zig for the
//! full semantics: format neutrality, ownership & the eviction-safe borrow
//! rule, O(head) open cost, the scan frontier, threading lanes, dialect
//! grammar, sniffing, header rule). contracts/ and tests/ are planner-owned.
//!
//! STATUS: viewer-ui SEED. The walking-skeleton head parser was superseded by
//! the windowed v2 surface; this file currently contains conformance-true
//! STUBS (plus the real open/error-mapping path) so the component compiles
//! while the frozen behavior tests are red. The build cell implements:
//!   - dialect option validation + sniffer (separator/quote candidates over
//!     the head sample only; pinned tie-breaks) + header grammar (isNumeric
//!     below is the pinned grammar, kept for reuse),
//!   - the parameterized quote-aware lexer (RFC-4180 generalized; quote NONE),
//!   - the sparse row index + scan frontier (mmap; checkpoints at record
//!     boundaries; files <= head budget fully indexed at open),
//!   - windowed materialization with eviction (ls_window_set) and zero-alloc
//!     cell serving,
//!   - the AUTO background indexer thread and the async jump-scan machinery
//!     (std.Thread; cancel keeps the frontier; close cancels + joins).

const std = @import("std");
const api = @import("api");

const posix = std.posix;
const c = std.c;

/// Default allocator behind `ls_open` (thread-safe). `ls_close` returns all
/// document storage here.
const default_gpa = std.heap.smp_allocator;

/// The concrete storage behind an `ls_doc` handle (seed: facts only).
const Document = struct {
    gpa: std.mem.Allocator,
    file_size: u64,

    fn deinit(self: *Document) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// The empty borrowed string returned by every out-of-range / no-header access.
const empty_str: api.Str = .{ .ptr = "", .len = 0 };

fn asDoc(doc: *const api.Doc) *const Document {
    return @ptrCast(@alignCast(doc));
}

// ---------------------------------------------------------------------------
// Lifecycle (C ABI + explicit-allocator seam).
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_open`. Equals
/// `openWithAllocator(<default allocator>, path, options, out_doc)`.
pub export fn ls_open(path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) callconv(.c) api.Status {
    return openWithAllocator(default_gpa, path, options, out_doc);
}

/// See contracts/api.zig `openWithAllocator`. Every heap allocation for the
/// document goes through `gpa`; the file mapping itself (mmap) is exempt.
pub fn openWithAllocator(gpa: std.mem.Allocator, path: [*:0]const u8, options: ?*const api.OpenOptions, out_doc: *?*api.Doc) api.Status {
    out_doc.* = null;
    _ = options; // SEED: option validation + forced dialect are unimplemented.

    const fd = posix.openatZ(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| return switch (err) {
        error.FileNotFound => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        else => .io,
    };
    defer _ = c.close(fd);

    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return .io;
    // Only regular files are readable as documents; directories/devices/etc.
    // exist but "cannot be read as a file" -> the distinct I/O error code.
    if (!posix.S.ISREG(@as(u32, st.mode))) return .io;

    const doc = gpa.create(Document) catch return .io;
    doc.* = .{
        .gpa = gpa,
        .file_size = if (st.size > 0) @intCast(st.size) else 0,
    };
    out_doc.* = @ptrCast(doc);
    return .ok;
}

/// See api/lesssheet.h `ls_close`.
pub export fn ls_close(doc: *api.Doc) callconv(.c) void {
    const d: *Document = @ptrCast(@alignCast(doc));
    d.deinit();
}

// ---------------------------------------------------------------------------
// Document facts — zero allocation, total functions.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_dialect_get`.
pub export fn ls_dialect_get(doc: *const api.Doc) callconv(.c) api.Dialect {
    _ = asDoc(doc);
    return .{
        .separator = 0,
        .quote = 0,
        .has_quote = false,
        .header = false,
        .separator_forced = false,
        .quote_forced = false,
        .header_forced = false,
    };
}

/// See api/lesssheet.h `ls_column_count`.
pub export fn ls_column_count(doc: *const api.Doc) callconv(.c) u32 {
    _ = asDoc(doc);
    return 0;
}

// ---------------------------------------------------------------------------
// Row-count knowledge and index progress.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_row_count_get`.
pub export fn ls_row_count_get(doc: *const api.Doc) callconv(.c) api.RowCount {
    _ = asDoc(doc);
    // SEED: terminal placeholder so red-suite poll loops fail fast (no timeouts).
    return .{ .count = 0, .exact = true };
}

/// See api/lesssheet.h `ls_index_poll`.
pub export fn ls_index_poll(doc: *const api.Doc) callconv(.c) api.ScanProgress {
    const d = asDoc(doc);
    // SEED: terminal placeholder so red-suite poll loops fail fast (no timeouts).
    return .{ .bytes_scanned = 0, .bytes_total = d.file_size, .complete = true };
}

// ---------------------------------------------------------------------------
// Windowed row access.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_window_set`.
pub export fn ls_window_set(doc: *api.Doc, first_row: u64, row_count: u32) callconv(.c) api.RowRange {
    _ = doc;
    _ = row_count;
    return .{ .first_row = first_row, .row_count = 0 };
}

/// See api/lesssheet.h `ls_cell`. Zero allocation; total function.
pub export fn ls_cell(doc: *const api.Doc, row: u64, col: u32) callconv(.c) api.Str {
    _ = asDoc(doc);
    _ = row;
    _ = col;
    return empty_str;
}

/// See api/lesssheet.h `ls_header_cell`. Zero allocation; total function.
pub export fn ls_header_cell(doc: *const api.Doc, col: u32) callconv(.c) api.Str {
    _ = asDoc(doc);
    _ = col;
    return empty_str;
}

// ---------------------------------------------------------------------------
// Jump-scans.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_jump_start`.
pub export fn ls_jump_start(doc: *api.Doc, target_row: u64) callconv(.c) void {
    _ = doc;
    _ = target_row;
}

/// See api/lesssheet.h `ls_jump_cancel`.
pub export fn ls_jump_cancel(doc: *api.Doc) callconv(.c) void {
    _ = doc;
}

/// See api/lesssheet.h `ls_jump_poll`.
pub export fn ls_jump_poll(doc: *const api.Doc) callconv(.c) api.JumpStatus {
    _ = asDoc(doc);
    // SEED: terminal placeholder so red-suite poll loops fail fast (no timeouts).
    return .{ .state = .done, .progress = 1.0, .landed_row = 0 };
}

// ---------------------------------------------------------------------------
// Numeric-cell test (pinned grammar — see api/lesssheet.h HEADER RULE).
//   sign? ( digits ('.' digits?)? | '.' digits ) ( ('e'|'E') sign? digits )?
// after trimming ASCII whitespace (0x09..0x0D, 0x20); remainder must be
// non-empty and match fully. Decimal separator '.' only; ASCII digits only.
// Kept from the walking skeleton for the build cell to reuse in the v2
// header decision (currently unreferenced).
// ---------------------------------------------------------------------------

fn isAsciiWs(ch: u8) bool {
    return ch == 0x20 or (ch >= 0x09 and ch <= 0x0D);
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

pub fn isNumeric(raw: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = raw.len;
    while (lo < hi and isAsciiWs(raw[lo])) lo += 1;
    while (hi > lo and isAsciiWs(raw[hi - 1])) hi -= 1;
    const s = raw[lo..hi];
    if (s.len == 0) return false;

    var i: usize = 0;
    if (s[i] == '+' or s[i] == '-') i += 1;

    var int_digits: usize = 0;
    while (i < s.len and isDigit(s[i])) : (i += 1) int_digits += 1;

    var has_significand = int_digits > 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac_digits: usize = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) frac_digits += 1;
        if (int_digits == 0 and frac_digits == 0) return false; // lone '.'
        if (frac_digits > 0) has_significand = true;
    } else if (int_digits == 0) {
        return false; // needs the 'digits' form when there is no dot
    }
    if (!has_significand) return false;

    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < s.len and isDigit(s[i])) : (i += 1) exp_digits += 1;
        if (exp_digits == 0) return false; // dangling exponent
    }
    return i == s.len;
}
