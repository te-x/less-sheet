//! Local Parquet transport and bounded, page-level decoding. No row group is
//! converted to CSV or materialized in full. All cached values remain private;
//! callers copy display text into their own window storage.
const std = @import("std");
const pq = @import("parquet");
const low = pq.internals.reader;
const decoder = pq.internals.column_decoder;
const format = pq.format;

pub const Error = error{ OutOfMemory, InvalidParquet, UnsupportedParquet };
const metadata_limit = 8 * 1024 * 1024;
const page_limit = 16 * 1024 * 1024;
const page_values_limit = 1 << 20;
const memory_limit = 64 * 1024 * 1024;
const cache_slots = 64;

/// Limits allocations made by the decoder, including malicious Thrift counts.
const Budget = struct {
    parent: std.mem.Allocator,
    used: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (len > memory_limit -| self.used) return null;
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        self.peak = @max(self.peak, self.used);
        return result;
    }
    fn resize(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (len > old.len and len - old.len > memory_limit -| self.used) return false;
        if (!self.parent.rawResize(old, alignment, len, ra)) return false;
        self.used = self.used - old.len + len;
        self.peak = @max(self.peak, self.used);
        return true;
    }
    fn remap(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (len > old.len and len - old.len > memory_limit -| self.used) return null;
        const result = self.parent.rawRemap(old, alignment, len, ra) orelse return null;
        self.used = self.used - old.len + len;
        self.peak = @max(self.peak, self.used);
        return result;
    }
    fn free(ctx: *anyopaque, old: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(old, alignment, ra);
        self.used -= old.len;
    }
};

const Page = struct {
    arena: ?std.heap.ArenaAllocator = null,
    group: usize = 0,
    column: usize = 0,
    first: u64 = 0,
    values: []const pq.Value = &.{},
    used: u64 = 0,

    fn clear(self: *Page) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

pub const Data = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    budget: Budget,
    metadata_arena: std.heap.ArenaAllocator,
    reader: pq.DynamicReader,
    group_ends: []u64,
    rows: u64,
    columns: u32,
    pages: [cache_slots]Page = @splat(.{}),
    clock: u64 = 0,
    mutex: std.Io.Mutex = .init,
    failed: std.atomic.Value(bool) = .init(false),
    pages_decoded: u64 = 0,
    decoded_bytes: u64 = 0,

    pub fn isParquet(bytes: []const u8) bool {
        return bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "PAR1") or std.mem.eql(u8, bytes[0..4], "PARE"));
    }

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) Error!*Data {
        if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "PAR1") or !std.mem.eql(u8, bytes[bytes.len - 4 ..], "PAR1")) return error.InvalidParquet;
        const footer_len = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
        if (footer_len > metadata_limit or footer_len > bytes.len - 12) return error.InvalidParquet;
        const self = try gpa.create(Data);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.bytes = bytes;
        self.budget = .{ .parent = gpa };
        self.metadata_arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.metadata_arena.deinit();
        self.reader = pq.openBufferDynamic(self.metadata_arena.allocator(), bytes, .{}) catch |err| return convertError(err);
        // The arena owns metadata even if validation fails partway through.
        const meta = self.reader.metadata;
        if (meta.num_rows < 0 or meta.schema.len == 0) return error.InvalidParquet;
        const children = meta.schema[0].num_children orelse return error.InvalidParquet;
        if (children < 0 or children > 1 << 20) return error.InvalidParquet;
        self.columns = @intCast(children);
        if (meta.schema.len != @as(usize, self.columns) + 1) return error.UnsupportedParquet;
        for (meta.schema[1..]) |col| {
            if (col.type_ == null or col.repetition_type == .repeated) return error.UnsupportedParquet;
            if (col.type_ == .fixed_len_byte_array and (col.type_length == null or col.type_length.? <= 0)) return error.InvalidParquet;
            if (col.converted_type == 5 and ((col.scale orelse -1) < 0 or (col.scale orelse 77) > 76 or (col.precision orelse 0) <= 0 or (col.precision orelse 77) > 76)) return error.InvalidParquet;
            if (col.logical_type) |logical| {
                if (logical == .decimal and (logical.decimal.scale < 0 or logical.decimal.precision <= 0 or logical.decimal.precision > 76 or logical.decimal.scale > logical.decimal.precision)) return error.UnsupportedParquet;
            }
        }
        self.group_ends = try self.metadata_arena.allocator().alloc(u64, meta.row_groups.len);
        var count: u64 = 0;
        for (meta.row_groups, 0..) |group, i| {
            if (group.num_rows < 0 or group.columns.len != self.columns) return error.InvalidParquet;
            count = std.math.add(u64, count, @intCast(group.num_rows)) catch return error.InvalidParquet;
            self.group_ends[i] = count;
            for (group.columns, 0..) |col, column| {
                if (col.file_path) |path| if (path.len != 0) return error.UnsupportedParquet;
                const m = col.meta_data orelse return error.InvalidParquet;
                if (m.type_ != meta.schema[column + 1].type_.? or m.path_in_schema.len != 1 or !std.mem.eql(u8, m.path_in_schema[0], meta.schema[column + 1].name)) return error.InvalidParquet;
                if (m.data_page_offset < 0) return error.InvalidParquet;
                if (m.num_values != group.num_rows or m.total_compressed_size < 0 or (group.num_rows != 0 and m.data_page_offset < 4)) return error.InvalidParquet;
                const start: u64 = @intCast(if (m.dictionary_page_offset) |d| if (d > 0) d else m.data_page_offset else m.data_page_offset);
                if (start > bytes.len or @as(u64, @intCast(m.total_compressed_size)) > bytes.len - start) return error.InvalidParquet;
            }
        }
        if (count != @as(u64, @intCast(meta.num_rows))) return error.InvalidParquet;
        if (count >= std.math.maxInt(u64) / 1024) return error.InvalidParquet;
        self.rows = count;
        self.pages = @splat(.{});
        self.clock = 0;
        self.mutex = .init;
        self.failed = .init(false);
        self.pages_decoded = 0;
        self.decoded_bytes = 0;
        return self;
    }

    pub fn deinit(self: *Data) void {
        for (&self.pages) |*page| page.clear();
        // Metadata, transport wrapper and unused DynamicReader byte arena are
        // all arena-owned; deinit first releases their internal references.
        self.reader.deinit();
        self.metadata_arena.deinit();
        std.debug.assert(self.budget.used == 0);
        self.gpa.destroy(self);
    }

    pub fn header(self: *const Data, column: u32) []const u8 {
        return self.reader.metadata.schema[@as(usize, column) + 1].name;
    }

    /// Appends one value's exact text. Output does not borrow page-cache storage.
    pub fn appendCell(self: *Data, row: u64, column: u32, cap: usize, out: *std.ArrayList(u8), gpa: std.mem.Allocator) Error!bool {
        if (row >= self.rows or column >= self.columns) return error.InvalidParquet;
        const io = @import("sysio.zig").io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const group = self.groupForRow(row);
        const first = if (group == 0) 0 else self.group_ends[group - 1];
        const local = row - first;
        self.clock +%= 1;
        for (&self.pages) |*page| {
            if (page.arena != null and page.group == group and page.column == column and local >= page.first and local - page.first < page.values.len) {
                page.used = self.clock;
                return appendValue(page.values[@intCast(local - page.first)], self.reader.metadata.schema[@as(usize, column) + 1], cap, out, gpa);
            }
        }
        var slot: *Page = &self.pages[0];
        for (&self.pages) |*page| {
            if (page.arena == null) {
                slot = page;
                break;
            }
            if (page.used < slot.used) slot = page;
        }
        slot.clear();
        // Reserve room for a new page while retaining the most useful pages.
        while (self.budget.used > memory_limit / 2) {
            var victim: ?*Page = null;
            for (&self.pages) |*page| if (page.arena != null and (victim == null or page.used < victim.?.used)) {
                victim = page;
            };
            if (victim) |v| v.clear() else break;
        }
        self.loadPage(slot, group, column, local) catch |err| {
            slot.clear();
            self.failed.store(true, .release);
            return err;
        };
        slot.used = self.clock;
        return appendValue(slot.values[@intCast(local - slot.first)], self.reader.metadata.schema[@as(usize, column) + 1], cap, out, gpa);
    }

    fn groupForRow(self: *const Data, row: u64) usize {
        var lo: usize = 0;
        var hi = self.group_ends.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.group_ends[mid] <= row) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn loadPage(self: *Data, slot: *Page, group: usize, column: u32, row: u64) Error!void {
        slot.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        const alloc = slot.arena.?.allocator();
        const meta = self.reader.metadata.row_groups[group].columns[column].meta_data.?;
        const schema = self.reader.metadata.schema[@as(usize, column) + 1];
        const start: usize = @intCast(if (meta.dictionary_page_offset) |d| if (d > 0) d else meta.data_page_offset else meta.data_page_offset);
        const chunk = self.bytes[start .. start + @as(usize, @intCast(meta.total_compressed_size))];
        var it = low.PageIterator.init(alloc, chunk);
        var dict = low.DictionarySet.init(alloc);
        var first: u64 = 0;
        while (it.next() catch |err| return convertError(err)) |page| {
            defer low.freePageHeaderContents(alloc, &page.header);
            if (page.header.uncompressed_page_size < 0 or page.header.compressed_page_size < 0 or page.header.uncompressed_page_size > page_limit) return error.InvalidParquet;
            if (page.is_dictionary) {
                const d = page.header.dictionary_page_header.?;
                if (d.num_values < 0 or d.num_values > page_values_limit) return error.InvalidParquet;
                try checkCrc(page.header, page.body);
                dict.initFromPage(page.body, @intCast(d.num_values), schema.type_, schema.type_length, meta.codec, @intCast(page.header.uncompressed_page_size)) catch |err| return convertError(err);
                continue;
            }
            if (!page.is_data_page) continue;
            const n = if (page.header.data_page_header) |d| d.num_values else page.header.data_page_header_v2.?.num_values;
            if (n < 0 or n > page_values_limit) return error.InvalidParquet;
            const end = std.math.add(u64, first, @intCast(n)) catch return error.InvalidParquet;
            if (row >= end) {
                first = end;
                continue;
            }
            try checkCrc(page.header, page.body);
            const decoded = decodePage(alloc, schema, meta.codec, page, &dict) catch |err| return convertError(err);
            if (decoded.values.len != @as(usize, @intCast(n))) return error.InvalidParquet;
            slot.group = group;
            slot.column = column;
            slot.first = first;
            slot.values = decoded.values;
            self.pages_decoded += 1;
            self.decoded_bytes += @intCast(page.header.uncompressed_page_size);
            return;
        }
        return error.InvalidParquet;
    }
};

fn convertError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidParquet;
}

fn checkCrc(header: format.PageHeader, body: []const u8) Error!void {
    if (header.crc) |expected| if (@as(i32, @bitCast(std.hash.crc.Crc32.hash(body))) != expected) return error.InvalidParquet;
}

fn decodePage(alloc: std.mem.Allocator, schema: format.SchemaElement, codec: format.CompressionCodec, page: low.PageInfo, dict: *low.DictionarySet) !decoder.DynamicDecodeResult {
    const sd = if (dict.string_dict) |*d| d else null;
    const i32d = if (dict.int32_dict) |*d| d else null;
    const i64d = if (dict.int64_dict) |*d| d else null;
    const f32d = if (dict.float32_dict) |*d| d else null;
    const f64d = if (dict.float64_dict) |*d| d else null;
    const fixed = if (dict.fixed_byte_array_dict) |*d| d else null;
    const i96d = if (dict.int96_dict) |*d| d else null;
    const def: u8 = if (schema.repetition_type == .optional) 1 else 0;
    if (page.header.data_page_header) |h| {
        const body = if (codec == .uncompressed) page.body else try pq.internals.compress.decompress(alloc, page.body, codec, @intCast(page.header.uncompressed_page_size));
        return decoder.decodeColumnDynamicWithValueEncoding(alloc, schema, body, @intCast(h.num_values), def, 0, dict.hasDictionary(), sd, i32d, i64d, f32d, f64d, fixed, i96d, h.definition_level_encoding, h.repetition_level_encoding, h.encoding);
    }
    const h = page.header.data_page_header_v2.?;
    if (h.repetition_levels_byte_length < 0 or h.definition_levels_byte_length < 0) return error.InvalidParquet;
    const rep: usize = @intCast(h.repetition_levels_byte_length);
    const defs: usize = @intCast(h.definition_levels_byte_length);
    if (rep > page.body.len or defs > page.body.len - rep) return error.InvalidParquet;
    const compressed = page.body[rep + defs ..];
    const full: usize = @intCast(page.header.uncompressed_page_size);
    if (full < rep + defs) return error.InvalidParquet;
    var values = if (h.is_compressed and codec != .uncompressed) try pq.internals.compress.decompress(alloc, compressed, codec, full - rep - defs) else compressed;
    // Boolean RLE has a four-byte length prefix in both page versions.
    // The upstream V2 decoder consumes the hybrid stream without that prefix.
    if (schema.type_ == .boolean and h.encoding == .rle) {
        if (values.len < 4) return error.InvalidParquet;
        const len = std.mem.readInt(u32, values[0..4], .little);
        if (len != values.len - 4) return error.InvalidParquet;
        values = values[4..];
    }
    return decoder.decodeColumnDynamicV2(alloc, schema, page.body[0..rep], page.body[rep .. rep + defs], values, @intCast(h.num_values), def, 0, dict.hasDictionary(), sd, i32d, i64d, f32d, f64d, fixed, i96d, h.encoding);
}

fn appendValue(value: pq.Value, schema: format.SchemaElement, cap: usize, out: *std.ArrayList(u8), gpa: std.mem.Allocator) Error!bool {
    var scratch: [512]u8 = undefined;
    const text: []const u8 = switch (value) {
        .null_val => "",
        .bool_val => |v| if (v) "true" else "false",
        .int32_val => |v| try integerText(v, schema, &scratch),
        .int64_val => |v| try integerText(v, schema, &scratch),
        .float_val => |v| std.fmt.bufPrint(&scratch, "{d}", .{v}) catch return error.InvalidParquet,
        .double_val => |v| std.fmt.bufPrint(&scratch, "{d}", .{v}) catch return error.InvalidParquet,
        .bytes_val, .fixed_bytes_val => |v| blk: {
            if (schema.logical_type) |l| {
                if (l == .decimal) break :blk try decimalText(v, l.decimal.scale, &scratch);
                if (l == .uuid) {
                    if (v.len != 16) return error.InvalidParquet;
                    break :blk std.fmt.bufPrint(&scratch, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12], v[13], v[14], v[15] }) catch return error.InvalidParquet;
                }
            } else if (schema.converted_type == 5) break :blk try decimalText(v, schema.scale orelse 0, &scratch);
            break :blk v;
        },
        else => return error.UnsupportedParquet,
    };
    var length = @min(text.len, cap);
    if (length < text.len) while (length > 0 and text[length] & 0xc0 == 0x80) : (length -= 1) {};
    try out.appendSlice(gpa, text[0..length]);
    return length < text.len;
}

fn integerText(value: anytype, schema: format.SchemaElement, scratch: []u8) Error![]const u8 {
    if (schema.logical_type) |logical| switch (logical) {
        .date => return dateText(@intCast(value), scratch),
        .decimal => |d| return decimalIntegerText(value, d.scale, scratch),
        .time => |t| return timeText(@intCast(value), t.unit, scratch),
        .timestamp => |ts| return timestampText(@intCast(value), ts.unit, ts.is_adjusted_to_utc, scratch),
        .int => |int| if (!int.is_signed) {
            const unsigned = @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value))), @bitCast(value));
            return std.fmt.bufPrint(scratch, "{d}", .{unsigned}) catch return error.InvalidParquet;
        },
        else => {},
    } else if (schema.converted_type) |t| switch (t) {
        5 => return decimalIntegerText(value, schema.scale orelse 0, scratch),
        7 => return timeText(@intCast(value), .millis, scratch),
        8 => return timeText(@intCast(value), .micros, scratch),
        6 => return dateText(@intCast(value), scratch),
        9 => return timestampText(@intCast(value), .millis, true, scratch),
        10 => return timestampText(@intCast(value), .micros, true, scratch),
        else => {},
    };
    if (schema.type_ == .int96) return timestampText(@intCast(value), .nanos, true, scratch);
    return std.fmt.bufPrint(scratch, "{d}", .{value}) catch return error.InvalidParquet;
}

fn decimalIntegerText(value: anytype, scale: i32, scratch: []u8) Error![]const u8 {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .big);
    return decimalText(&bytes, scale, scratch);
}
fn timeText(value: i64, unit: format.TimeUnit, scratch: []u8) Error![]const u8 {
    const divisor: i64 = switch (unit) {
        .millis => 1000,
        .micros => 1_000_000,
        .nanos => 1_000_000_000,
    };
    if (value < 0 or @divTrunc(value, divisor) >= 86400) return error.InvalidParquet;
    const seconds: u64 = @intCast(@divTrunc(value, divisor));
    return std.fmt.bufPrint(scratch, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{ seconds / 3600, seconds / 60 % 60, seconds % 60, @as(u64, @intCast(@mod(value, divisor) * @divTrunc(1_000_000_000, divisor))) }) catch return error.InvalidParquet;
}

fn dateText(days: i64, scratch: []u8) Error![]const u8 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const day = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month = mp + @as(i64, if (mp < 10) 3 else -9);
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return std.fmt.bufPrint(scratch, "{s}{d:0>4}-{d:0>2}-{d:0>2}", .{ if (year < 0) @as([]const u8, "-") else "", @abs(year), @as(u64, @intCast(month)), @as(u64, @intCast(day)) }) catch return error.InvalidParquet;
}

fn timestampText(value: i64, unit: format.TimeUnit, utc: bool, scratch: []u8) Error![]const u8 {
    const divisor: i64 = switch (unit) {
        .millis => 1000,
        .micros => 1_000_000,
        .nanos => 1_000_000_000,
    };
    const seconds = @divFloor(value, divisor);
    const days = @divFloor(seconds, 86400);
    const tod = @mod(seconds, 86400);
    const date = try dateText(days, scratch);
    const rest = std.fmt.bufPrint(scratch[date.len..], "T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}{s}", .{ @as(u64, @intCast(@divTrunc(tod, 3600))), @as(u64, @intCast(@divTrunc(@mod(tod, 3600), 60))), @as(u64, @intCast(@mod(tod, 60))), @as(u64, @intCast(@mod(value, divisor) * @divTrunc(1_000_000_000, divisor))), if (utc) "Z" else "" }) catch return error.InvalidParquet;
    return scratch[0 .. date.len + rest.len];
}

fn decimalText(bytes: []const u8, scale: i32, scratch: []u8) Error![]const u8 {
    if (bytes.len == 0 or bytes.len > 32 or scale < 0 or scale > 76) return error.InvalidParquet;
    var bits: u256 = if (bytes[0] & 0x80 != 0) std.math.maxInt(u256) else 0;
    for (bytes) |byte| bits = (bits << 8) | byte;
    const value: i256 = @bitCast(bits);
    var number: [80]u8 = undefined;
    const digits = std.fmt.bufPrint(&number, "{d}", .{@abs(value)}) catch return error.InvalidParquet;
    const sign: []const u8 = if (value < 0) "-" else "";
    const places: usize = @intCast(scale);
    if (places == 0) return std.fmt.bufPrint(scratch, "{s}{s}", .{ sign, digits }) catch return error.InvalidParquet;
    if (places < digits.len) return std.fmt.bufPrint(scratch, "{s}{s}.{s}", .{ sign, digits[0 .. digits.len - places], digits[digits.len - places ..] }) catch return error.InvalidParquet;
    const prefix = std.fmt.bufPrint(scratch, "{s}0.", .{sign}) catch return error.InvalidParquet;
    const zeros = places - digits.len;
    @memset(scratch[prefix.len .. prefix.len + zeros], '0');
    @memcpy(scratch[prefix.len + zeros ..][0..digits.len], digits);
    return scratch[0 .. prefix.len + places];
}
