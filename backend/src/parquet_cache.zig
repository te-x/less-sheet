//! Cache only owned scalar values. Dictionary, level and decompression buffers
//! belong to a temporary decode arena and must not survive a page load.
const std = @import("std");
const pq = @import("parquet");
const Error = @import("parquet_remote.zig").Error;

pub const Values = union(enum) {
    bool_val: []bool,
    int32_val: []i32,
    int64_val: []i64,
    float_val: []f32,
    double_val: []f64,
    bytes_val: [][]const u8,
    fixed_bytes_val: [][]const u8,

    pub fn init(alloc: std.mem.Allocator, physical: pq.format.PhysicalType, input: []const pq.Value) Error!Values {
        return switch (physical) {
            .boolean => copy(.bool_val, alloc, input),
            .int32 => copy(.int32_val, alloc, input),
            .int64, .int96 => copy(.int64_val, alloc, input),
            .float => copy(.float_val, alloc, input),
            .double => copy(.double_val, alloc, input),
            .byte_array => copy(.bytes_val, alloc, input),
            .fixed_len_byte_array => copy(.fixed_bytes_val, alloc, input),
        };
    }

    fn copy(comptime tag: std.meta.Tag(Values), alloc: std.mem.Allocator, input: []const pq.Value) Error!Values {
        const T = @typeInfo(@FieldType(Values, @tagName(tag))).pointer.child;
        const output = try alloc.alloc(T, input.len);
        for (input, output) |value, *target| {
            // Null slots are guarded by Page.present before they are read.
            if (value == .null_val) continue;
            if (std.meta.activeTag(value) != @field(std.meta.Tag(pq.Value), @tagName(tag))) return error.InvalidParquet;
            const scalar = @field(value, @tagName(tag));
            target.* = if (T == []const u8) try alloc.dupe(u8, scalar) else scalar;
        }
        return @unionInit(Values, @tagName(tag), output);
    }

    pub fn at(self: Values, index: usize) pq.Value {
        return switch (self) {
            inline else => |values, tag| @unionInit(pq.Value, @tagName(tag), values[index]),
        };
    }
};
