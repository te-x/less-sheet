//! Bounded HTTP page navigation. Column chunks are never downloaded in full.
const std = @import("std");
const pq = @import("parquet");
const low = pq.internals.reader;
const thrift = pq.internals.thrift;
const format = pq.format;
pub const Error = error{ OutOfMemory, InvalidParquet, UnsupportedParquet, WouldBlock };
const header_limit = 256 * 1024;
const index_limit = 8 * 1024 * 1024;
const page_limit = 16 * 1024 * 1024;

/// The provider owns the sparse spool. Reads happen only on the designated
/// fetch worker; foreground callers use decoded pages or yield WouldBlock.
pub const Source = struct {
    ctx: *anyopaque,
    read: *const fn (*anyopaque, u64, u64) []const u8,
    can_fetch: *const fn () bool,
    peek: ?*const fn (*anyopaque, u64, u64) []const u8 = null,

    pub fn slice(self: Source, offset: u64, length: u64) Error![]const u8 {
        const fetch = self.can_fetch();
        const result = if (fetch) self.read(self.ctx, offset, length) else if (self.peek) |peek| peek(self.ctx, offset, length) else return error.WouldBlock;
        if (result.len != length) return if (fetch) error.InvalidParquet else error.WouldBlock;
        return result;
    }
};

pub const Header = struct {
    arena: std.heap.ArenaAllocator,
    info: low.PageInfo,
    body_offset: u64,
    pub fn deinit(self: *Header) void {
        self.arena.deinit();
    }
    pub fn body(self: *Header, source: Source) Error!void {
        self.info.body = try source.slice(self.body_offset, @intCast(self.info.header.compressed_page_size));
    }
};

/// Parse a bounded header separately from its body, so skipping a data page
/// reads only its header (plus the transport's surrounding cache chunk).
pub fn readHeader(allocator: std.mem.Allocator, source: Source, offset: u64, end: u64) Error!Header {
    if (offset >= end) return error.InvalidParquet;
    var length = @min(end - offset, 4096);
    while (true) {
        const bytes = try source.slice(offset, length);
        var arena = std.heap.ArenaAllocator.init(allocator);
        var reader = thrift.CompactReader.init(bytes);
        const header = format.PageHeader.parse(arena.allocator(), &reader) catch |err| {
            arena.deinit();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err != error.EndOfData or length >= header_limit or length == end - offset) return error.InvalidParquet;
            length = @min(end - offset, @min(header_limit, length * 2));
            continue;
        };
        errdefer arena.deinit();
        if (header.compressed_page_size < 0 or header.uncompressed_page_size < 0 or
            header.compressed_page_size > page_limit or header.uncompressed_page_size > page_limit) return error.InvalidParquet;
        const body_offset = offset + reader.pos;
        const size: u64 = @intCast(header.compressed_page_size);
        if (body_offset > end or size > end - body_offset) return error.InvalidParquet;
        return .{ .arena = arena, .body_offset = body_offset, .info = .{
            .header = header,
            .body = &.{},
            .next_pos = @intCast(body_offset + size),
            .is_dictionary = header.dictionary_page_header != null,
            .is_data_page = header.data_page_header != null or header.data_page_header_v2 != null,
        } };
    }
}

const Entry = struct { offset: u64, first: u64, count: u64, next: u64 };
pub const Navigator = struct {
    arena: ?std.heap.ArenaAllocator = null,
    group: usize = 0,
    column: u32 = 0,
    used: u64 = 0,
    index: ?format.OffsetIndex = null,
    entries: std.ArrayList(Entry) = .empty,

    pub fn clear(self: *Navigator) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn init(self: *Navigator, allocator: std.mem.Allocator, source: Source, chunk: format.ColumnChunk, rows: u64, file_size: u64, group: usize, column: u32) Error!void {
        self.clear();
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.clear();
        self.group = group;
        self.column = column;
        if (chunk.offset_index_offset == null and chunk.offset_index_length == null) return;
        const offset = chunk.offset_index_offset orelse return error.InvalidParquet;
        const length = chunk.offset_index_length orelse return error.InvalidParquet;
        if (offset < 4 or length <= 0 or length > index_limit) return error.InvalidParquet;
        const at: u64 = @intCast(offset);
        const len: u64 = @intCast(length);
        if (at > file_size or len > file_size - at) return error.InvalidParquet;
        const bytes = try source.slice(at, len);
        var reader = thrift.CompactReader.init(bytes);
        const index = format.OffsetIndex.parse(self.arena.?.allocator(), &reader) catch |err| return convertError(err);
        if (reader.pos != bytes.len or index.page_locations.len == 0) return error.InvalidParquet;
        const meta = chunk.meta_data.?;
        const start: u64 = @intCast(meta.data_page_offset);
        const chunk_start: u64 = @intCast(if (meta.dictionary_page_offset) |d| if (d > 0) d else meta.data_page_offset else meta.data_page_offset);
        const end = chunk_start + @as(u64, @intCast(meta.total_compressed_size));
        var previous_end = start;
        var previous_row: i64 = -1;
        for (index.page_locations, 0..) |location, i| {
            if (location.offset < 0 or location.compressed_page_size <= 0 or location.compressed_page_size > page_limit + header_limit or
                location.first_row_index < 0 or location.first_row_index <= previous_row or @as(u64, @intCast(location.first_row_index)) >= rows or
                (i == 0 and (location.first_row_index != 0 or location.offset != meta.data_page_offset))) return error.InvalidParquet;
            const page_start: u64 = @intCast(location.offset);
            const size: u64 = @intCast(location.compressed_page_size);
            if (page_start < previous_end or page_start > end or size > end - page_start) return error.InvalidParquet;
            previous_end = page_start + size;
            previous_row = location.first_row_index;
        }
        self.index = index;
    }

    pub const Located = struct {
        header: Header,
        first: u64,
        count: u64,
    };
    pub fn locate(self: *Navigator, allocator: std.mem.Allocator, source: Source, chunk: format.ColumnChunk, rows: u64, row: u64) Error!Located {
        const meta = chunk.meta_data.?;
        const chunk_start: u64 = @intCast(if (meta.dictionary_page_offset) |d| if (d > 0) d else meta.data_page_offset else meta.data_page_offset);
        const end = chunk_start + @as(u64, @intCast(meta.total_compressed_size));
        if (self.index) |index| {
            const locations = index.page_locations;
            var lo: usize = 0;
            var hi = locations.len;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (@as(u64, @intCast(locations[mid].first_row_index)) <= row) lo = mid else hi = mid;
            }
            const location = locations[lo];
            const first: u64 = @intCast(location.first_row_index);
            const next = if (lo + 1 < locations.len) @as(u64, @intCast(locations[lo + 1].first_row_index)) else rows;
            var header = try readHeader(allocator, source, @intCast(location.offset), end);
            errdefer header.deinit();
            const n = try pageRows(header.info);
            if (n != next - first or header.info.next_pos != @as(u64, @intCast(location.offset)) + @as(u64, @intCast(location.compressed_page_size))) return error.InvalidParquet;
            return .{ .header = header, .first = first, .count = n };
        }
        // Without an OffsetIndex, retain the contiguous sequence of discovered
        // page positions. Repeat/backward jumps binary-search this map; forward
        // jumps continue at its tail, never re-walking the whole row group.
        var offset: u64 = @intCast(meta.data_page_offset);
        var first: u64 = 0;
        const entries = self.entries.items;
        if (entries.len != 0) {
            var lo: usize = 0;
            var hi = entries.len;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (entries[mid].first <= row) lo = mid else hi = mid;
            }
            const entry = entries[lo];
            if (row < entry.first + entry.count) {
                const header = try readHeader(allocator, source, entry.offset, end);
                return .{ .header = header, .first = entry.first, .count = entry.count };
            }
            const tail = entries[entries.len - 1];
            offset = tail.next;
            first = tail.first + tail.count;
        }
        while (offset < end) {
            var header = try readHeader(allocator, source, offset, end);
            var retained = false;
            defer if (!retained) header.deinit();
            if (!header.info.is_data_page) {
                offset = header.info.next_pos;
                continue;
            }
            const n = try pageRows(header.info);
            if (n == 0 or n > rows -| first) return error.InvalidParquet;
            try self.entries.append(self.arena.?.allocator(), .{ .offset = offset, .first = first, .count = n, .next = header.info.next_pos });
            if (row < first + n) {
                retained = true;
                return .{ .header = header, .first = first, .count = n };
            }
            first += n;
            offset = header.info.next_pos;
        }
        return error.InvalidParquet;
    }
};

fn pageRows(page: low.PageInfo) Error!u64 {
    const n = if (page.header.data_page_header) |h| h.num_values else if (page.header.data_page_header_v2) |h| h.num_values else return error.InvalidParquet;
    if (n < 0 or n > 1 << 20) return error.InvalidParquet;
    return @intCast(n);
}
fn convertError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidParquet;
}
