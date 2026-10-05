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

fn openRemote(fixture: *const api.NetFixture) !*api.Doc {
    const url = "https://example.invalid/data.parquet";
    const job = api.openUrlStartFake(fixture, url.ptr, url.len, null) orelse return error.OpenFailed;
    defer api.ls_net_open_release(job);
    const status = api.ls_net_open_poll(job);
    try std.testing.expectEqual(api.NetOpenState.done, status.state);
    return status.doc orelse error.OpenFailed;
}
fn remoteWindow(doc: *api.Doc, row: u64, count: u32, column: u32, columns: u32) !void {
    errdefer std.debug.print("remote window row={d} count={d} filter={any} sort={any} status={any}\n", .{ row, count, api.ls_filter_poll(doc), api.ls_sort_poll(doc), api.ls_document_status(doc) });
    for (0..5000) |_| {
        const result = api.ls_window_set_columns(doc, row, count, column, columns);
        if (result.row_count == count) return;
        try std.testing.expectEqual(api.Status.ok, api.ls_document_status(doc));
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

test "HTTP Parquet footer, projected pages and deep indexed/unindexed jumps" {
    inline for (.{ @embedFile("fixtures/parquet/remote-indexed.parquet"), @embedFile("fixtures/parquet/remote-unindexed.parquet") }) |input| {
        const doc = try openRemote(&.{ .body = input });
        defer api.ls_close(doc);
        try std.testing.expect(api.ls_document_is_parquet(doc));
        try std.testing.expectEqual(api.NetRangeMode.random_access, api.netRangeMode(doc));
        try std.testing.expectEqual(65536, api.ls_row_count_get(doc).count);
        try std.testing.expect(api.ls_row_count_get(doc).exact);
        try remoteWindow(doc, 0, 2, 0, 1);
        try std.testing.expectEqualStrings("0", api.ls_cell(doc, 0, 0).slice());
        try std.testing.expectEqualStrings("", api.ls_cell(doc, 0, 1).slice());
        // A first viewport must leave a substantial part of the file unfetched.
        try std.testing.expect(api.netSpoolStore(doc).bytes < input.len);
        try remoteWindow(doc, 65535, 1, 1, 2);
        try std.testing.expectEqualStrings("12673362341216059938", api.ls_cell(doc, 65535, 1).slice());
        try std.testing.expectEqualStrings("last", api.ls_cell(doc, 65535, 2).slice());
        const fetched = api.netFetchCount(doc);
        try remoteWindow(doc, 65534, 1, 1, 2);
        try remoteWindow(doc, 65535, 1, 1, 2);
        try std.testing.expectEqual(fetched, api.netFetchCount(doc));
        try std.testing.expect(api.netResidentBytes(doc) <= 16 * 1024 * 1024);
        try std.testing.expectEqual(api.Status.ok, api.ls_document_status(doc));
    }
}

test "HTTP Parquet sequential fallback handles known and unknown lengths" {
    inline for (.{ true, false }) |known| {
        const doc = try openRemote(&.{ .body = @embedFile("fixtures/parquet/remote-indexed.parquet"), .honor_ranges = false, .advertise_length = known });
        defer api.ls_close(doc);
        try std.testing.expectEqual(api.NetRangeMode.sequential_fallback, api.netRangeMode(doc));
        try remoteWindow(doc, 65535, 1, 0, 3);
        try std.testing.expectEqualStrings("65535", api.ls_cell(doc, 65535, 0).slice());
        try std.testing.expectEqualStrings("last", api.ls_cell(doc, 65535, 2).slice());
    }
}

test "HTTP Parquet copy yields pending and resumes on the page worker" {
    const doc = try openRemote(&.{ .body = @embedFile("fixtures/parquet/remote-indexed.parquet") });
    defer api.ls_close(doc);
    var output: [64]u8 = undefined;
    var length: usize = 0;
    var truncated = false;
    try std.testing.expectEqual(api.CopyResult.pending, api.ls_cell_copy(doc, 0, 1, &output, output.len, &length, &truncated));
    try std.testing.expectEqual(0, length);
    for (0..5000) |_| {
        const result = api.ls_cell_copy(doc, 0, 1, &output, output.len, &length, &truncated);
        if (result == .ok) break;
        try std.testing.expectEqual(api.CopyResult.pending, result);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try std.testing.expectEqualStrings("1442695040888963407", output[0..length]);
}

test "HTTP Parquet search, filtered display and sorted projected display" {
    const doc = try openRemote(&.{ .body = bytes });
    defer api.ls_close(doc);
    const query = "last";
    try std.testing.expect(api.ls_search_start(doc, &.{ .kind = .text, .value_ptr = query.ptr, .value_len = query.len }));
    api.ls_search_nav(doc, 0, .forward);
    try std.testing.expectEqual(1, (try waitSearch(doc)).total);
    const value = "5";
    errdefer std.debug.print("remote composed jobs: search={any} filter={any} jump={any} sort={any}\n", .{ api.ls_search_poll(doc), api.ls_filter_poll(doc), api.ls_jump_poll(doc), api.ls_sort_poll(doc) });
    try std.testing.expect(api.ls_filter_set(doc, &.{ .kind = .predicate, .op = .gt, .column = 0, .value_ptr = value.ptr, .value_len = value.len }));
    // A network filter advances only on concrete demand.
    api.ls_jump_start(doc, 2);
    for (0..5000) |_| {
        if (api.ls_jump_poll(doc).state == .done) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try remoteWindow(doc, 0, 3, 0, 2);
    try std.testing.expectEqualStrings("6", api.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("last", api.ls_cell(doc, 2, 1).slice());
    api.ls_filter_clear(doc);
    try std.testing.expect(api.ls_sort_set(doc, 0, .descending));
    for (0..5000) |_| {
        const status = api.ls_sort_poll(doc);
        if (status.state == .active) break;
        try std.testing.expect(status.state != .failed);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try remoteWindow(doc, 0, 2, 0, 2);
    try std.testing.expectEqualStrings("8", api.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("last", api.ls_cell(doc, 0, 1).slice());
}

test "HTTP Parquet rejects missing footer and truncated sequential body" {
    const input = @embedFile("fixtures/parquet/remote-indexed.parquet");
    inline for (.{ api.NetFixture{ .body = input, .short_body_at = input.len - 10 }, api.NetFixture{ .body = input, .honor_ranges = false, .drop_after = input.len - 10 } }) |fixture| {
        const url = "https://example.invalid/broken.parquet";
        const job = api.openUrlStartFake(&fixture, url.ptr, url.len, null) orelse return error.OpenFailed;
        defer api.ls_net_open_release(job);
        try std.testing.expectEqual(api.NetOpenState.failed, api.ls_net_open_poll(job).state);
        try std.testing.expect(api.ls_net_open_poll(job).doc == null);
    }
}

test "HTTP Parquet navigation and filtered jump reload evicted pages" {
    const doc = try openRemote(&.{ .body = @embedFile("fixtures/parquet/remote-indexed.parquet") });
    defer api.ls_close(doc);
    const zero = "0";
    const all: api.SearchRequest = .{ .kind = .predicate, .op = .ge, .column = 0, .value_ptr = zero.ptr, .value_len = zero.len };
    try std.testing.expect(api.ls_search_start(doc, &all));
    api.ls_search_nav(doc, 65535, .forward);
    try std.testing.expectEqual(65536, (try waitSearch(doc)).total);
    api.ls_search_nav(doc, 0, .forward);
    for (0..5000) |_| {
        const status = api.ls_search_poll(doc);
        if (status.nav == .found) {
            try std.testing.expectEqual(0, status.found_row);
            try std.testing.expectEqual(1, status.position);
            break;
        }
        try std.testing.expect(status.nav != .exhausted);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try std.testing.expect(api.ls_filter_set(doc, &all));
    try std.testing.expect(api.ls_sort_set(doc, 0, .descending));
    for (0..5000) |_| {
        const status = api.ls_sort_poll(doc);
        if (status.state == .active) break;
        try std.testing.expect(status.state != .failed);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try std.testing.expect(api.ls_filter_poll(doc).total_exact);
    api.ls_sort_clear(doc);
    api.ls_jump_start(doc, 0);
    for (0..5000) |_| {
        const status = api.ls_jump_poll(doc);
        if (status.state == .done) {
            try std.testing.expectEqual(0, status.landed_row);
            break;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.Timeout;
    try remoteWindow(doc, 0, 2, 0, 1);
    try std.testing.expectEqualStrings("0", api.ls_cell(doc, 0, 0).slice());
    try std.testing.expectEqualStrings("1", api.ls_cell(doc, 1, 0).slice());
}
