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
