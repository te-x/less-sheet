//! Frozen behavior tests — walking-skeleton slice (planner-owned).
//! Every backend acceptance criterion of ARCH-walking-skeleton (1–11) maps to
//! at least one test below. Tests exercise the PUBLIC C ABI through the
//! contract module (`@import("api")`) only — never internal Zig APIs.
const std = @import("std");
const api = @import("api");

// ---------------------------------------------------------------------------
// Helpers (fixtures are inline byte strings written to per-test temp files).
// ---------------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

/// Write `bytes` to a fresh temp file with `mode` permissions; returns the
/// absolute, NUL-terminated path expected by ls_open.
fn makeFixture(bytes: []const u8, mode: u9) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "fixture.csv",
        .data = bytes,
        .flags = .{ .permissions = .fromMode(mode) },
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ buf[0..n], "fixture.csv" });
    return .{ .tmp = tmp, .path = path };
}

const OpenedDoc = struct {
    fx: Fixture,
    doc: *api.Doc,

    fn deinit(self: *OpenedDoc) void {
        api.ls_close(self.doc);
        self.fx.deinit();
    }
};

/// Open `bytes` as a document via the public C ABI; fails the test on error.
fn openBytes(bytes: []const u8) !OpenedDoc {
    var fx = try makeFixture(bytes, 0o644);
    errdefer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &doc));
    try std.testing.expect(doc != null);
    return .{ .fx = fx, .doc = doc.? };
}

fn expectCell(doc: *const api.Doc, row: u32, col: u32, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, api.ls_cell(doc, row, col).slice());
}

fn expectHeaderCell(doc: *const api.Doc, col: u32, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, api.ls_header_cell(doc, col).slice());
}

fn expectDims(doc: *const api.Doc, data_rows: u32, cols: u32) !void {
    try std.testing.expectEqual(data_rows, api.ls_data_row_count(doc));
    try std.testing.expectEqual(cols, api.ls_column_count(doc));
}

test "toolchain baseline" {
    try std.testing.expect(true);
}

// ---------------------------------------------------------------------------
// Criterion 1 — plain CSV lexing.
// ---------------------------------------------------------------------------

test "c1: plain CSV lexes into the expected 2x2 grid" {
    var od = try openBytes("1,2\n3,4\n");
    defer od.deinit();
    try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 2, 2);
    try expectCell(od.doc, 0, 0, "1");
    try expectCell(od.doc, 0, 1, "2");
    try expectCell(od.doc, 1, 0, "3");
    try expectCell(od.doc, 1, 1, "4");
}

test "c1: plain CSV with a header row" {
    var od = try openBytes("a,b\n1,2\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 1, 2);
    try expectHeaderCell(od.doc, 0, "a");
    try expectHeaderCell(od.doc, 1, "b");
    try expectCell(od.doc, 0, 0, "1");
    try expectCell(od.doc, 0, 1, "2");
}

// ---------------------------------------------------------------------------
// Criterion 2 — quote-aware boundaries: embedded comma and newline.
// ---------------------------------------------------------------------------

test "c2: quoted fields carry embedded comma and newline in single cells" {
    var od = try openBytes("\"x,y\",q\n\"line1\nline2\",w\n");
    defer od.deinit();
    // Quote-aware record boundaries: exactly 1 header record + 1 data record,
    // even though the bytes contain three '\n'.
    try std.testing.expectEqual(true, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 1, 2);
    try expectHeaderCell(od.doc, 0, "x,y");
    try expectHeaderCell(od.doc, 1, "q");
    try expectCell(od.doc, 0, 0, "line1\nline2");
    try expectCell(od.doc, 0, 1, "w");
}

// ---------------------------------------------------------------------------
// Criterion 3 — "" escape inside quoted fields.
// ---------------------------------------------------------------------------

test "c3: doubled quote inside a quoted field is a literal quote" {
    var od = try openBytes("\"a\"\"b\",1\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 0, 2);
    try expectHeaderCell(od.doc, 0, "a\"b");
    try expectHeaderCell(od.doc, 1, "1");
}

test "c3: quote escape in a data cell" {
    var od = try openBytes("9,8\n\"x\"\"y\",2\n");
    defer od.deinit();
    try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 2, 2);
    try expectCell(od.doc, 1, 0, "x\"y");
    try expectCell(od.doc, 1, 1, "2");
}

// ---------------------------------------------------------------------------
// Criterion 4 — CRLF == LF; trailing newline changes nothing.
// ---------------------------------------------------------------------------

test "c4: CRLF and LF produce identical grids; trailing newline is irrelevant" {
    const variants = [_][]const u8{
        "1,2\r\n3,4\r\n",
        "1,2\r\n3,4",
        "1,2\n3,4\n",
        "1,2\n3,4",
    };
    for (variants) |bytes| {
        errdefer std.debug.print("variant: {f}\n", .{std.zig.fmtString(bytes)});
        var od = try openBytes(bytes);
        defer od.deinit();
        try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
        try expectDims(od.doc, 2, 2);
        try expectCell(od.doc, 0, 0, "1");
        try expectCell(od.doc, 0, 1, "2");
        try expectCell(od.doc, 1, 0, "3");
        try expectCell(od.doc, 1, 1, "4");
    }
}

// ---------------------------------------------------------------------------
// Criterion 5 — leading UTF-8 BOM is stripped.
// ---------------------------------------------------------------------------

test "c5: leading UTF-8 BOM is absent from the first cell" {
    var od = try openBytes("\xEF\xBB\xBFname,age\n1,2\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_header_suggested(od.doc));
    try expectHeaderCell(od.doc, 0, "name");
    try expectCell(od.doc, 0, 0, "1");
}

test "c5: BOM-only file is an empty document" {
    var od = try openBytes("\xEF\xBB\xBF");
    defer od.deinit();
    try expectDims(od.doc, 0, 0);
    try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
}

// ---------------------------------------------------------------------------
// Criterion 6 — head cap N (= head_max_data_rows = 200) and shorter files.
// ---------------------------------------------------------------------------

// 250 data records "i,i*2\n" built at comptime (inline fixture, no files).
const big_csv = blk: {
    @setEvalBranchQuota(400_000);
    var s: []const u8 = "";
    for (0..250) |i| {
        s = s ++ std.fmt.comptimePrint("{d},{d}\n", .{ i, i * 2 });
    }
    break :blk s;
};

test "c6: a headerless file beyond the cap loads exactly N data rows" {
    var od = try openBytes(big_csv);
    defer od.deinit();
    try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, api.head_max_data_rows, 2);
    try expectCell(od.doc, 0, 0, "0");
    try expectCell(od.doc, 199, 0, "199");
    try expectCell(od.doc, 199, 1, "398");
    // beyond the loaded head: out of range, empty
    try expectCell(od.doc, 200, 0, "");
}

test "c6: the cap counts data rows, not the header record" {
    var od = try openBytes("h1,h2\n" ++ big_csv);
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, api.head_max_data_rows, 2);
    try expectHeaderCell(od.doc, 0, "h1");
    try expectCell(od.doc, 0, 0, "0");
    try expectCell(od.doc, 199, 1, "398");
}

test "c6: a file with fewer rows loads them all" {
    var od = try openBytes("1,2\n3,4\n5,6\n");
    defer od.deinit();
    try expectDims(od.doc, 3, 2);
    try expectCell(od.doc, 2, 1, "6");
}

// ---------------------------------------------------------------------------
// Criterion 7 — ragged rule: truncate wider, pad narrower.
// ---------------------------------------------------------------------------

test "c7: rows are truncated or padded to the header's column count" {
    var od = try openBytes("a,b,c\n1,2\n4,5,6,7\n");
    defer od.deinit();
    try expectDims(od.doc, 2, 3);
    // narrower row pads with empty cells
    try expectCell(od.doc, 0, 0, "1");
    try expectCell(od.doc, 0, 1, "2");
    try expectCell(od.doc, 0, 2, "");
    // wider row truncates; the extra field is unreachable
    try expectCell(od.doc, 1, 0, "4");
    try expectCell(od.doc, 1, 2, "6");
    try expectCell(od.doc, 1, 3, ""); // out-of-range col
}

test "c7: headerless ragged rows follow row 1's field count" {
    var od = try openBytes("1,2\n3\n");
    defer od.deinit();
    try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 2, 2);
    try expectCell(od.doc, 1, 0, "3");
    try expectCell(od.doc, 1, 1, "");
}

// ---------------------------------------------------------------------------
// Criterion 8 — header suggestion and the pinned numeric grammar.
// ---------------------------------------------------------------------------

fn expectSuggested(bytes: []const u8, expected: bool) !void {
    errdefer std.debug.print("fixture: {f}\n", .{std.zig.fmtString(bytes)});
    var od = try openBytes(bytes);
    defer od.deinit();
    try std.testing.expectEqual(expected, api.ls_header_suggested(od.doc));
}

test "c8: header suggestion on the ARCH cases" {
    try expectSuggested("name,age\n1,2\n", true);
    try expectSuggested("1,2.5\n3,4\n", false);
    try expectSuggested("1,,3\n", true); // empty cell is NOT numeric
    try expectSuggested("+1e5,-2\n", false);
}

test "c8: pinned numeric grammar — accepted forms (row 1 all numeric)" {
    try expectSuggested("1e5,2\n", false); // exponent without fraction
    try expectSuggested(" 12 ,3\n", false); // ASCII whitespace trimmed
    try expectSuggested("\t7\t,8\n", false); // tabs trimmed
    try expectSuggested(".5,5.\n", false); // leading/trailing dot forms
    try expectSuggested("-0.0,+42\n", false); // signs
    try expectSuggested("1.5e-3,2E+4\n", false); // signed exponents, e or E
}

test "c8: pinned numeric grammar — rejected forms (suggest header)" {
    try expectSuggested("0x1F,2\n", true); // no hex
    try expectSuggested("\"1,000\",2\n", true); // no thousands separators
    try expectSuggested("1e,2\n", true); // dangling exponent
    try expectSuggested("e5,2\n", true); // no digits before exponent
    try expectSuggested("--1,2\n", true); // double sign
    try expectSuggested("1.2.3,4\n", true); // two dots
    try expectSuggested("NaN,1\n", true); // no nan
    try expectSuggested("inf,1\n", true); // no inf
    try expectSuggested("1 2,3\n", true); // inner whitespace survives trim
    try expectSuggested("١٢,3\n", true); // ASCII digits only
}

test "c8: an empty-line record is a single empty, non-numeric cell" {
    var od = try openBytes("\n");
    defer od.deinit();
    try std.testing.expectEqual(true, api.ls_header_suggested(od.doc));
    try expectDims(od.doc, 0, 1);
    try expectHeaderCell(od.doc, 0, "");
}

// ---------------------------------------------------------------------------
// Criterion 9 — empty file is not an error.
// ---------------------------------------------------------------------------

test "c9: empty file opens as a 0x0 document" {
    var od = try openBytes("");
    defer od.deinit();
    try expectDims(od.doc, 0, 0);
    try std.testing.expectEqual(false, api.ls_header_suggested(od.doc));
    // total functions: out-of-range access returns the empty string
    try expectCell(od.doc, 0, 0, "");
    try expectHeaderCell(od.doc, 0, "");
}

// ---------------------------------------------------------------------------
// Criterion 10 — distinct error codes.
// ---------------------------------------------------------------------------

test "c10: missing path yields not_found and a null handle" {
    var fx = try makeFixture("x\n", 0o644); // only to obtain a real temp dir
    defer fx.deinit();
    const missing = try std.fs.path.joinZ(std.testing.allocator, &.{ std.fs.path.dirname(fx.path).?, "does-not-exist.csv" });
    defer std.testing.allocator.free(missing);
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.not_found, api.ls_open(missing.ptr, &doc));
    try std.testing.expectEqual(@as(?*api.Doc, null), doc);
}

test "c10: unreadable file yields permission_denied" {
    var fx = try makeFixture("secret\n", 0o000);
    defer fx.deinit();
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.permission_denied, api.ls_open(fx.path.ptr, &doc));
    try std.testing.expectEqual(@as(?*api.Doc, null), doc);
}

test "c10: a path that is not a readable file yields the distinct io code" {
    var fx = try makeFixture("x\n", 0o644);
    defer fx.deinit();
    const dir_path = try std.testing.allocator.dupeZ(u8, std.fs.path.dirname(fx.path).?);
    defer std.testing.allocator.free(dir_path);
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.io, api.ls_open(dir_path.ptr, &doc));
    try std.testing.expectEqual(@as(?*api.Doc, null), doc);
    // ABI stability: the three failure codes are distinct and pinned to the header
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(api.Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(api.Status.not_found));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(api.Status.permission_denied));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(api.Status.io));
    // ... and .io is not a catch-all: the sibling readable file still opens.
    var ok_doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(fx.path.ptr, &ok_doc));
    api.ls_close(ok_doc.?);
}

// ---------------------------------------------------------------------------
// Criterion 11 — public C ABI (exported symbols, C calling convention) and
// zero allocation on the cell-access path.
// ---------------------------------------------------------------------------

// Extern C declarations resolved by the LINKER against the exported symbols:
// this proves symbol names and C-ABI types end-to-end, exactly as a frontend
// links them. (Signature drift additionally fails `zig build` via the
// contract's comptime pins.)
const c_linked = struct {
    extern fn ls_open(path: [*:0]const u8, out_doc: *?*api.Doc) api.Status;
    extern fn ls_close(doc: *api.Doc) void;
    extern fn ls_data_row_count(doc: *const api.Doc) u32;
    extern fn ls_column_count(doc: *const api.Doc) u32;
    extern fn ls_header_suggested(doc: *const api.Doc) bool;
    extern fn ls_cell(doc: *const api.Doc, row: u32, col: u32) api.Str;
    extern fn ls_header_cell(doc: *const api.Doc, col: u32) api.Str;
};

test "c11: the exported C symbols are callable through extern linkage" {
    var fx = try makeFixture("a,b\n1,2\n", 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, c_linked.ls_open(fx.path.ptr, &doc_opt));
    const doc = doc_opt.?;
    defer c_linked.ls_close(doc);
    try std.testing.expectEqual(@as(u32, 1), c_linked.ls_data_row_count(doc));
    try std.testing.expectEqual(@as(u32, 2), c_linked.ls_column_count(doc));
    try std.testing.expect(c_linked.ls_header_suggested(doc));
    try std.testing.expectEqualStrings("1", c_linked.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("b", c_linked.ls_header_cell(doc, 1).slice());
}

/// Counts every allocating call (alloc/resize/remap) while delegating to a
/// parent allocator; frees are delegated uncounted.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        return self_of(ctx).parent.vtable.free(self_of(ctx).parent.ptr, memory, alignment, ret_addr);
    }
    fn self_of(ctx: *anyopaque) *CountingAllocator {
        return @ptrCast(@alignCast(ctx));
    }
};

test "c11: zero allocation on the cell-access path" {
    // Open through the contract's allocator seam (std.testing.allocator also
    // leak-checks the document's full lifecycle), then hammer every accessor
    // through the C ABI and require the allocation count to stay flat.
    var counting: CountingAllocator = .{ .parent = std.testing.allocator };
    var fx = try makeFixture("a,b,c\n\"x,1\",2\n3\n", 0o644);
    defer fx.deinit();
    var doc_opt: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.openHeadWithAllocator(counting.allocator(), fx.path.ptr, &doc_opt));
    const doc = doc_opt.?;
    defer api.ls_close(doc);

    const allocs_after_open = counting.count;

    try std.testing.expectEqual(@as(u32, 2), api.ls_data_row_count(doc));
    try std.testing.expectEqual(@as(u32, 3), api.ls_column_count(doc));
    try std.testing.expectEqual(true, api.ls_header_suggested(doc));
    try expectHeaderCell(doc, 0, "a");
    try expectHeaderCell(doc, 1, "b");
    try expectHeaderCell(doc, 2, "c");
    try expectCell(doc, 0, 0, "x,1");
    try expectCell(doc, 0, 1, "2");
    try expectCell(doc, 0, 2, "");
    try expectCell(doc, 1, 0, "3");
    try expectCell(doc, 1, 1, "");
    try expectCell(doc, 1, 2, "");
    // out-of-range accesses are also allocation-free total functions
    try expectCell(doc, 99, 0, "");
    try expectCell(doc, 0, 99, "");
    try expectHeaderCell(doc, 99, "");

    try std.testing.expectEqual(allocs_after_open, counting.count);
}
