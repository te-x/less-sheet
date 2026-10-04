const std = @import("std");
const api = @import("api");
const bytes = @embedFile("fixtures/parquet/snappy-v2.parquet");

const Opened = struct {
    tmp: std.testing.TmpDir,
    doc: *api.Doc,
    fn deinit(self: *Opened) void {
        api.ls_close(self.doc);
        self.tmp.cleanup();
    }
};
fn open(input: []const u8) !Opened {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.parquet", .data = input });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..len], "data.parquet" });
    defer std.testing.allocator.free(path);
    // CSV overrides must not change a self-describing file's shape.
    const options: api.OpenOptions = .{ .header = api.header_off, .separator = ';', .index_mode = api.index_manual };
    var doc: ?*api.Doc = null;
    try std.testing.expectEqual(api.Status.ok, api.ls_open(path, &options, &doc));
    return .{ .tmp = tmp, .doc = doc.? };
}
fn waitSearch(doc: *api.Doc) !api.SearchStatus {
    for (0..5000) |_| {
        const status = api.ls_search_poll(doc);
        if (status.state == .done) return status;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}
fn waitFilter(doc: *api.Doc) !api.FilterStatus {
    for (0..5000) |_| {
        const status = api.ls_filter_poll(doc);
        if (status.state == .done) return status;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}
test "Parquet ABI schema, exact counts, random windows and projected copy" {
    var opened = try open(bytes);
    defer opened.deinit();
    const doc = opened.doc;
    try std.testing.expect(api.ls_document_is_parquet(doc));
    try std.testing.expect(api.ls_dialect_get(doc).header);
    try std.testing.expectEqual(8, api.ls_column_count(doc));
    const rows = api.ls_row_count_get(doc);
    try std.testing.expect(rows.exact);
    try std.testing.expectEqual(8, rows.count);
    try std.testing.expect(api.ls_index_poll(doc).complete);
    try std.testing.expectEqualStrings("name", api.ls_header_cell(doc, 1).slice());
    const columns = [_]u32{ 0, 4, 6 };
    var metadata: [3]api.ColumnMetadata = undefined;
    for (&metadata) |*item| {
        item.struct_size = @sizeOf(api.ColumnMetadata);
        item.abi_version = api.column_metadata_abi_version;
    }
    var generation: u64 = 0;
    try std.testing.expectEqual(api.ColumnResult.ok, api.ls_column_metadata_get_many(doc, &columns, columns.len, &metadata, metadata.len, &generation));
    try std.testing.expectEqual(api.ColumnTypeSource.declared, metadata[0].effective_source);
    try std.testing.expectEqual(api.ColumnTypeKind.integer, metadata[0].effective.kind);
    try std.testing.expectEqual(api.ColumnTypeKind.date, metadata[1].effective.kind);
    try std.testing.expectEqual(4, metadata[2].effective.decimal_scale);

    const projected = api.ls_window_set_columns(doc, 6, 2, 1, 1);
    try std.testing.expectEqual(2, projected.row_count);
    try std.testing.expectEqualStrings("東京", api.ls_cell(doc, 6, 1).slice());
    try std.testing.expectEqualStrings("", api.ls_cell(doc, 6, 0).slice());
    // A projected window must not hide a full-cell copy in another column.
    var copy: [64]u8 = undefined;
    var length: usize = 0;
    var truncated = false;
    try std.testing.expectEqual(api.CopyResult.ok, api.ls_cell_copy(doc, 0, 7, &copy, copy.len, &length, &truncated));
    try std.testing.expectEqualStrings("18446744073709551615", copy[0..length]);
    try std.testing.expect(!truncated);
    try std.testing.expectEqual(8, api.ls_window_set(doc, 0, 8).row_count);
    try std.testing.expectEqualStrings("true", api.ls_cell(doc, 0, 3).slice());
    try std.testing.expectEqualStrings("-0.0012", api.ls_cell(doc, 1, 6).slice());
    try std.testing.expectEqualStrings("line\nfeed", api.ls_cell(doc, 4, 1).slice());
    try std.testing.expectEqual(api.Status.ok, api.ls_document_status(doc));
}
test "Parquet search, navigation, filter and filtered windows" {
    var opened = try open(bytes);
    defer opened.deinit();
    const doc = opened.doc;
    const query = "last";
    const request: api.SearchRequest = .{ .kind = .text, .value_ptr = query.ptr, .value_len = query.len };
    try std.testing.expect(api.ls_search_start(doc, &request));
    const found = try waitSearch(doc);
    try std.testing.expectEqual(1, found.total);
    api.ls_search_nav(doc, 0, .forward);
    for (0..5000) |_| {
        const status = api.ls_search_poll(doc);
        if (status.nav == .found) {
            try std.testing.expectEqual(7, status.found_row);
            break;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    const value = "5";
    const filter: api.SearchRequest = .{ .kind = .predicate, .op = .gt, .column = 0, .value_ptr = value.ptr, .value_len = value.len };
    try std.testing.expect(api.ls_filter_set(doc, &filter));
    const filtered = try waitFilter(doc);
    try std.testing.expectEqual(3, filtered.total);
    try std.testing.expectEqual(3, api.ls_window_set_columns(doc, 0, 8, 0, 2).row_count);
    try std.testing.expectEqualStrings("6", api.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("last", api.ls_cell(doc, 2, 1).slice());
    try std.testing.expectEqual(7, api.ls_source_row(doc, 2));
    api.ls_filter_clear(doc);
    try std.testing.expectEqual(1, api.ls_window_set(doc, 0, 1).row_count);
    try std.testing.expectEqualStrings("Ada", api.ls_cell(doc, 0, 1).slice());
}
test "Parquet page failure reports IO and serves no fabricated rows" {
    const corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[50] ^= 1;
    var opened = try open(corrupt);
    defer opened.deinit();
    try std.testing.expectEqual(0, api.ls_window_set(opened.doc, 0, 8).row_count);
    try std.testing.expectEqual(api.Status.io, api.ls_document_status(opened.doc));
}

test "Parquet virtual checkpoints beyond the first block and numeric sorting" {
    var opened = try open(@embedFile("fixtures/parquet/blocks.parquet"));
    defer opened.deinit();
    const doc = opened.doc;
    try std.testing.expectEqual(1, api.ls_window_set_columns(doc, 4999, 1, 0, 2).row_count);
    try std.testing.expectEqualStrings("4999", api.ls_cell(doc, 4999, 0).slice());
    const query = "last";
    const request: api.SearchRequest = .{ .kind = .text, .value_ptr = query.ptr, .value_len = query.len };
    try std.testing.expect(api.ls_search_start(doc, &request));
    try std.testing.expectEqual(1, (try waitSearch(doc)).total);
    api.ls_search_nav(doc, 0, .forward);
    for (0..5000) |_| {
        const status = api.ls_search_poll(doc);
        if (status.nav == .found) {
            try std.testing.expectEqual(4999, status.found_row);
            break;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    const value = "4997";
    const filter: api.SearchRequest = .{ .kind = .predicate, .op = .gt, .column = 0, .value_ptr = value.ptr, .value_len = value.len };
    try std.testing.expect(api.ls_filter_set(doc, &filter));
    try std.testing.expectEqual(2, (try waitFilter(doc)).total);
    try std.testing.expectEqual(2, api.ls_window_set_columns(doc, 0, 2, 0, 2).row_count);
    try std.testing.expectEqualStrings("4998", api.ls_cell(doc, 0, 0).slice());
    api.ls_filter_clear(doc);
    try std.testing.expect(api.ls_sort_set(doc, 0, .descending));
    for (0..5000) |_| {
        const status = api.ls_sort_poll(doc);
        if (status.state == .active) break;
        try std.testing.expect(status.state != .failed);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try std.testing.expectEqual(2, api.ls_window_set_columns(doc, 0, 2, 0, 2).row_count);
    try std.testing.expectEqualStrings("4999", api.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("4998", api.ls_cell(doc, 1, 0).slice());
}
