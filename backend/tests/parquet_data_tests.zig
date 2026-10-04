const std = @import("std");
const Data = @import("parquet_data").Data;
const gpa = std.testing.allocator;

const cases = .{
    @embedFile("fixtures/parquet/none-v1.parquet"),
    @embedFile("fixtures/parquet/none-v2.parquet"),
    @embedFile("fixtures/parquet/snappy-v1.parquet"),
    @embedFile("fixtures/parquet/snappy-v2.parquet"),
    @embedFile("fixtures/parquet/zstd-v1.parquet"),
    @embedFile("fixtures/parquet/zstd-v2.parquet"),
    @embedFile("fixtures/parquet/gzip-v1.parquet"),
    @embedFile("fixtures/parquet/gzip-v2.parquet"),
    @embedFile("fixtures/parquet/brotli-v1.parquet"),
    @embedFile("fixtures/parquet/brotli-v2.parquet"),
    @embedFile("fixtures/parquet/lz4-v1.parquet"),
    @embedFile("fixtures/parquet/lz4-v2.parquet"),
};

test "Parquet codecs, both page versions, types, nulls and row groups" {
    inline for (cases, 0..) |bytes, fixture_index| {
        errdefer std.debug.print("Parquet fixture {d}\n", .{fixture_index});
        const data = try Data.init(gpa, bytes);
        defer data.deinit();
        try std.testing.expectEqual(8, data.rows);
        try std.testing.expectEqual(8, data.columns);
        try std.testing.expectEqualStrings("name", data.header(1));
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        const checks = .{
            .{ 0, 0, "1" },                 .{ 1, 0, "-2" },                   .{ 0, 1, "Ada" },
            .{ 1, 1, "Ålan" },
            .{ 2, 1, "" },                  .{ 3, 1, "comma,quote\"" },        .{ 4, 1, "line\nfeed" },
            .{ 5, 1, "" },
            .{ 6, 1, "東京" },
            .{ 7, 1, "last" },              .{ 0, 2, "1.25" },                 .{ 1, 2, "-2.5" },
            .{ 2, 2, "" },                  .{ 0, 3, "true" },                 .{ 1, 3, "false" },
            .{ 0, 4, "1969-12-31" },        .{ 1, 4, "2026-10-04" },           .{ 3, 4, "2000-02-29" },
            .{ 6, 4, "1900-03-01" },        .{ 7, 4, "2100-03-01" },           .{ 0, 5, "2026-10-04T12:34:56.123456000Z" },
            .{ 0, 6, "123456789012.3456" }, .{ 1, 6, "-0.0012" },              .{ 2, 6, "" },
            .{ 3, 6, "0.0000" },            .{ 0, 7, "18446744073709551615" },
        };
        inline for (checks) |check| {
            text.clearRetainingCapacity();
            try std.testing.expect(!try data.appendCell(check[0], check[1], 512, &text, gpa));
            try std.testing.expectEqualStrings(check[2], text.items);
        }
        try std.testing.expect(data.budget.peak <= 64 * 1024 * 1024);
    }
}

test "Parquet empty files retain schema; nested input fails explicitly" {
    const data = try Data.init(gpa, @embedFile("fixtures/parquet/empty.parquet"));
    defer data.deinit();
    try std.testing.expectEqual(0, data.rows);
    try std.testing.expectEqualStrings("x", data.header(0));
    try std.testing.expectError(error.UnsupportedParquet, Data.init(gpa, @embedFile("fixtures/parquet/nested.parquet")));
}

test "Parquet truncated footer and corrupt page CRC fail safely" {
    const bytes = cases[2];
    try std.testing.expectError(error.InvalidParquet, Data.init(gpa, bytes[0 .. bytes.len - 5]));
    const corrupt = try gpa.dupe(u8, bytes);
    defer gpa.free(corrupt);
    corrupt[50] ^= 1;
    const data = try Data.init(gpa, corrupt);
    defer data.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try std.testing.expectError(error.InvalidParquet, data.appendCell(0, 0, 512, &text, gpa));
}

test "Parquet cell cap keeps UTF-8 boundaries and reports truncation" {
    const data = try Data.init(gpa, cases[2]);
    defer data.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try std.testing.expect(try data.appendCell(1, 1, 1, &text, gpa));
    try std.testing.expectEqualStrings("", text.items);
    try std.testing.expect(try data.appendCell(1, 1, 2, &text, gpa));
    try std.testing.expectEqualStrings("Å", text.items);
}

test "Parquet decimals stored as integers and time logical values" {
    inline for (.{ @embedFile("fixtures/parquet/logical-v1.parquet"), @embedFile("fixtures/parquet/logical-v2.parquet") }) |bytes| {
        const data = try Data.init(gpa, bytes);
        defer data.deinit();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        _ = try data.appendCell(0, 0, 512, &text, gpa);
        try std.testing.expectEqualStrings("-0.12", text.items);
        text.clearRetainingCapacity();
        _ = try data.appendCell(1, 0, 512, &text, gpa);
        try std.testing.expectEqualStrings("1234.56", text.items);
        text.clearRetainingCapacity();
        _ = try data.appendCell(0, 1, 512, &text, gpa);
        try std.testing.expectEqualStrings("12:34:56.789000000", text.items);
    }
}

threadlocal var remote_fetch_allowed: bool = true;
const RemoteFixture = struct {
    bytes: []const u8,
    fetched: u64 = 0,
    requests: u64 = 0,
    header_reads: u64 = 0,
    fetching_data: ?*Data = null,
    saw_active_pending: bool = false,
    fn canFetch() bool {
        return remote_fetch_allowed;
    }
    fn read(ctx: *anyopaque, offset: u64, length: u64) []const u8 {
        const self: *RemoteFixture = @ptrCast(@alignCast(ctx));
        std.debug.assert(remote_fetch_allowed);
        if (self.fetching_data) |data| self.saw_active_pending = data.hasPending();
        self.fetched += length;
        self.requests += 1;
        if (length == 4096) self.header_reads += 1;
        if (offset > self.bytes.len or length > self.bytes.len - offset) return &.{};
        return self.bytes[@intCast(offset)..][0..@intCast(length)];
    }
    fn source(self: *RemoteFixture) @import("parquet_data").RemoteSource {
        return .{ .ctx = self, .read = read, .can_fetch = canFetch };
    }
};

test "remote Parquet pages use ranges, yield without IO and retain navigation" {
    inline for (.{ @embedFile("fixtures/parquet/remote-indexed.parquet"), @embedFile("fixtures/parquet/remote-unindexed.parquet") }, 0..) |input, variant| {
        var fixture: RemoteFixture = .{ .bytes = input };
        const data = try Data.initRemote(gpa, input, fixture.source());
        defer data.deinit();
        try std.testing.expect(fixture.fetched < 16 * 1024);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        const before = fixture.requests;
        remote_fetch_allowed = false;
        defer remote_fetch_allowed = true;
        try std.testing.expectError(error.WouldBlock, data.appendCell(65535, 1, 64, &text, gpa));
        try std.testing.expect(!data.failed.load(.acquire));
        try std.testing.expectEqual(before, fixture.requests);
        try std.testing.expect(data.hasPending());
        remote_fetch_allowed = true;
        fixture.fetching_data = data;
        data.fetchPending();
        fixture.fetching_data = null;
        try std.testing.expect(fixture.saw_active_pending);
        try std.testing.expect(!data.failed.load(.acquire));
        try std.testing.expect(!data.hasPending());
        const headers_before = fixture.header_reads;
        _ = try data.appendCell(65535, 1, 64, &text, gpa);
        try std.testing.expectEqualStrings("12673362341216059938", text.items);
        if (variant == 0) try std.testing.expect(headers_before <= 2) else try std.testing.expect(headers_before > 50);
        text.clearRetainingCapacity();
        // Read a different, earlier page without scanning its predecessors again.
        _ = try data.appendCell(60000, 1, 64, &text, gpa);
        try std.testing.expect(fixture.header_reads <= headers_before + 1);
        try std.testing.expect(data.budget.peak <= 64 * 1024 * 1024);
        remote_fetch_allowed = false;
        const fetched = fixture.requests;
        text.clearRetainingCapacity();
        _ = try data.appendCell(60000, 1, 64, &text, gpa);
        try std.testing.expectEqual(fetched, fixture.requests);
        remote_fetch_allowed = true;
    }
}

test "remote Parquet codecs, dictionaries, page versions and logical types" {
    inline for (cases) |input| {
        var fixture: RemoteFixture = .{ .bytes = input };
        const data = try Data.initRemote(gpa, input, fixture.source());
        defer data.deinit();
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        _ = try data.appendCell(6, 1, 64, &text, gpa);
        try std.testing.expectEqualStrings("東京", text.items);
        text.clearRetainingCapacity();
        _ = try data.appendCell(0, 7, 64, &text, gpa);
        try std.testing.expectEqualStrings("18446744073709551615", text.items);
        text.clearRetainingCapacity();
        _ = try data.appendCell(1, 6, 64, &text, gpa);
        try std.testing.expectEqualStrings("-0.0012", text.items);
        text.clearRetainingCapacity();
        _ = try data.appendCell(2, 3, 64, &text, gpa);
        try std.testing.expectEqualStrings("", text.items);
    }
}
