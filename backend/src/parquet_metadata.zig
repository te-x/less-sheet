//! Immutable footer inspection. Never touches the page cache or source bytes.
const std = @import("std");
const api = @import("api");
const Data = @import("parquet_data.zig").Data;
const format = @import("parquet").format;

fn span(bytes: []const u8) api.Str {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

pub fn info(data: *const Data, out: *api.ParquetInfo) void {
    const meta = data.reader.metadata;
    out.* = .{
        .file_bytes = data.bytes.len,
        .rows = data.rows,
        .row_groups = meta.row_groups.len,
        .columns = data.columns,
        .format_version = meta.version,
        .created_by = span(meta.created_by orelse ""),
    };
    for (meta.row_groups) |group| for (group.columns) |chunk| {
        out.codec_mask |= @as(u32, 1) << @intCast(@intFromEnum(chunk.meta_data.?.codec));
    };
}

pub fn column(data: *const Data, index: u32, out: *api.ParquetColumn) void {
    const schema = data.reader.metadata.schema[@as(usize, index) + 1];
    out.* = .{
        .name = span(schema.name),
        .physical_type = span(switch (schema.type_.?) {
            .boolean => "BOOLEAN",
            .int32 => "INT32",
            .int64 => "INT64",
            .int96 => "INT96",
            .float => "FLOAT",
            .double => "DOUBLE",
            .byte_array => "BYTE_ARRAY",
            .fixed_len_byte_array => "FIXED_LEN_BYTE_ARRAY",
        }),
        .nullable = schema.repetition_type == .optional,
    };
    const buffer = out.logical_type[0 .. out.logical_type.len - 1];
    _ = logicalType(schema, buffer) catch unreachable; // All labels fit in 127 bytes.
}

fn logicalType(schema: format.SchemaElement, buffer: []u8) ![]u8 {
    if (schema.logical_type) |logical| return switch (logical) {
        .decimal => |d| std.fmt.bufPrint(buffer, "Decimal({d}, {d})", .{ d.precision, d.scale }),
        .int => |i| std.fmt.bufPrint(buffer, "{s}Int{d}", .{ if (i.is_signed) "" else "U", i.bit_width }),
        .time => |t| std.fmt.bufPrint(buffer, "Time ({s}, {s})", .{ @tagName(t.unit), if (t.is_adjusted_to_utc) "UTC" else "local" }),
        .timestamp => |t| std.fmt.bufPrint(buffer, "Timestamp ({s}, {s})", .{ @tagName(t.unit), if (t.is_adjusted_to_utc) "UTC" else "local" }),
        .string => std.fmt.bufPrint(buffer, "String", .{}),
        .enum_ => std.fmt.bufPrint(buffer, "Enum", .{}),
        .date => std.fmt.bufPrint(buffer, "Date", .{}),
        .json => std.fmt.bufPrint(buffer, "JSON", .{}),
        .bson => std.fmt.bufPrint(buffer, "BSON", .{}),
        .uuid => std.fmt.bufPrint(buffer, "UUID", .{}),
        .float16 => std.fmt.bufPrint(buffer, "Float16", .{}),
        .geometry => std.fmt.bufPrint(buffer, "Geometry", .{}),
        .geography => std.fmt.bufPrint(buffer, "Geography", .{}),
    };
    // Old writers often have only a ConvertedType annotation.
    if (schema.converted_type) |converted| {
        if (converted == 5) return std.fmt.bufPrint(buffer, "Decimal({d}, {d})", .{ schema.precision orelse 0, schema.scale orelse 0 });
        const label: []const u8 = switch (converted) {
            0 => "String",
            4 => "Enum",
            6 => "Date",
            7 => "Time (millis, UTC)",
            8 => "Time (micros, UTC)",
            9 => "Timestamp (millis, UTC)",
            10 => "Timestamp (micros, UTC)",
            11 => "UInt8",
            12 => "UInt16",
            13 => "UInt32",
            14 => "UInt64",
            15 => "Int8",
            16 => "Int16",
            17 => "Int32",
            18 => "Int64",
            19 => "JSON",
            20 => "BSON",
            21 => "Interval",
            else => "Unknown",
        };
        return std.fmt.bufPrint(buffer, "{s}", .{label});
    }
    if (schema.type_length) |length| return std.fmt.bufPrint(buffer, "Fixed bytes ({d})", .{length});
    return buffer[0..0];
}

pub fn rowGroup(data: *const Data, index: usize, out: *api.ParquetRowGroup) void {
    const group = data.reader.metadata.row_groups[index];
    out.* = .{
        .first_row = if (index == 0) 0 else data.group_ends[index - 1],
        .rows = @intCast(group.num_rows),
    };
    for (group.columns) |chunk| {
        const meta = chunk.meta_data.?;
        out.compressed_bytes +|= @intCast(meta.total_compressed_size);
        out.uncompressed_bytes +|= @intCast(@max(0, meta.total_uncompressed_size));
    }
}
