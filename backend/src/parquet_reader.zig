//! Row coordinates for a self-describing, page-cached Parquet document.
const std = @import("std");
const api = @import("api");
const seam = @import("reader.zig");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const Data = @import("parquet_data.zig").Data;
const Pos = seam.Pos;
const stride = 1024;

pub const ParquetReader = struct {
    data: *Data,

    pub fn coordinate(self: ParquetReader, ordinal: u64) Pos {
        const n = @min(ordinal, self.data.rows + 1);
        return .{ .logical = n * stride, .physical = @intCast(@as(u128, self.data.bytes.len) * n / (self.data.rows + 1)) };
    }
    pub fn positionForRow(self: ParquetReader, row: u64) Pos {
        return self.coordinate(row +| 1);
    }
    pub fn start(self: ParquetReader, _: seam.Source) Pos {
        return self.coordinate(0);
    }
    pub fn atEnd(self: ParquetReader, _: seam.Source, pos: Pos) bool {
        return self.data.failed.load(.acquire) or pos.logical / stride >= self.data.rows + 1;
    }
    pub fn posAtByteBudget(self: ParquetReader, _: seam.Source, from: Pos, budget: u64) Pos {
        return self.coordinate(from.logical / stride +| budget / stride);
    }
    pub fn bytesConsumed(_: ParquetReader, _: seam.Source, pos: Pos) u64 {
        return pos.physical;
    }
    pub fn boundsAfter(self: ParquetReader, source: seam.Source, pos: Pos, limit: ?Pos) seam.BoundsResult {
        const next = if (self.atEnd(source, pos)) pos else self.coordinate(pos.logical / stride + 1);
        return .{ .next = if (limit) |l| if (next.logical > l.logical) l else next else next, .capped = if (limit) |l| next.logical > l.logical else false };
    }
    fn append(self: ParquetReader, pos: Pos, column: u32, cap: usize, buf: *std.ArrayList(u8), refs: *std.ArrayList(base.CellRef), gpa: std.mem.Allocator) seam.ReadError!void {
        const cell_start = buf.items.len;
        var truncated = false;
        if (column < self.data.columns) {
            if (pos.logical == 0) {
                const name = self.data.header(column);
                const len = @min(name.len, cap);
                try buf.appendSlice(gpa, name[0..len]);
                truncated = len < name.len;
            } else {
                truncated = self.data.appendCell(pos.logical / stride - 1, column, cap, buf, gpa) catch |err| {
                    if (err == error.WouldBlock) return error.WouldBlock;
                    self.data.failed.store(true, .release);
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return;
                };
            }
        }
        try refs.append(gpa, .{ .start = cell_start, .len = buf.items.len - cell_start, .truncated = truncated });
    }
    pub fn materialize(self: ParquetReader, source: seam.Source, pos: Pos, want: ?u32, cap: ?usize, limit: ?Pos, buf: *std.ArrayList(u8), refs: *std.ArrayList(base.CellRef), gpa: std.mem.Allocator) seam.ReadError!seam.MaterializeResult {
        const buf_mark = buf.items.len;
        const refs_mark = refs.items.len;
        errdefer {
            buf.items.len = buf_mark;
            refs.items.len = refs_mark;
        }
        var pending = false;
        const bounds = self.boundsAfter(source, pos, limit);
        if (self.atEnd(source, pos)) return .{ .next = pos, .capped = false };
        for (0..(want orelse self.data.columns)) |col| {
            self.append(pos, @intCast(col), cap orelse std.math.maxInt(usize), buf, refs, gpa) catch |err| {
                if (err == error.WouldBlock) {
                    pending = true;
                } else return err;
            };
            if (self.data.failed.load(.acquire)) break;
        }
        if (pending) return error.WouldBlock;
        return .{ .next = bounds.next, .capped = bounds.capped };
    }
    pub fn materializeWindow(self: ParquetReader, source: seam.Source, pos: Pos, want: u32, first_col: u32, last_col: u32, cap: usize, limit: ?Pos, buf: *std.ArrayList(u8), refs: *std.ArrayList(base.CellRef), gpa: std.mem.Allocator) seam.ReadError!seam.MaterializeResult {
        const buf_mark = buf.items.len;
        const refs_mark = refs.items.len;
        errdefer {
            buf.items.len = buf_mark;
            refs.items.len = refs_mark;
        }
        var pending = false;
        const bounds = self.boundsAfter(source, pos, limit);
        if (!self.atEnd(source, pos)) for (0..want) |column| {
            const col: u32 = @intCast(column);
            if (col >= first_col and col < last_col) {
                self.append(pos, col, cap, buf, refs, gpa) catch |err| {
                    if (err == error.WouldBlock) {
                        pending = true;
                    } else return err;
                };
            } else try refs.append(gpa, .{ .start = buf.items.len, .len = 0, .truncated = false });
            if (self.data.failed.load(.acquire)) break;
        };
        if (pending) return error.WouldBlock;
        return .{ .next = bounds.next, .capped = bounds.capped };
    }
    pub fn materializeSelected(self: ParquetReader, source: seam.Source, pos: Pos, selected: []const u32, cap: usize, limit: ?Pos, buf: *std.ArrayList(u8), refs: *std.ArrayList(base.CellRef), gpa: std.mem.Allocator) seam.ReadError!seam.MaterializeResult {
        const buf_mark = buf.items.len;
        const refs_mark = refs.items.len;
        errdefer {
            buf.items.len = buf_mark;
            refs.items.len = refs_mark;
        }
        var pending = false;
        const bounds = self.boundsAfter(source, pos, limit);
        if (!self.atEnd(source, pos)) for (selected) |col| {
            self.append(pos, col, cap, buf, refs, gpa) catch |err| {
                if (err == error.WouldBlock) {
                    pending = true;
                } else return err;
            };
            if (self.data.failed.load(.acquire)) break;
        };
        if (pending) return error.WouldBlock;
        return .{ .next = bounds.next, .capped = bounds.capped };
    }
    pub fn cell(self: ParquetReader, source: seam.Source, pos: Pos, col: u32, _: ?Pos, output: ?[*]u8, capacity: usize) seam.CellResult {
        if (self.atEnd(source, pos) or col >= self.data.columns) return .{ .len = 0, .truncated = false };
        // Use caller storage directly. A page-cache hit needs no allocation.
        const cap = if (output != null) capacity else 0;
        var text: std.ArrayList(u8) = .{ .items = if (output) |p| p[0..0] else &.{}, .capacity = cap };
        const truncated = self.data.appendCell(pos.logical / stride - 1, col, cap, &text, self.data.gpa) catch |err| {
            if (err == error.WouldBlock) return .{ .len = 0, .truncated = false, .pending = true };
            self.data.failed.store(true, .release);
            return .{ .len = 0, .truncated = true };
        };
        return .{ .len = text.items.len, .truncated = truncated };
    }
    pub fn scanRows(self: ParquetReader, source: seam.Source, pos: Pos, max_rows: u64) seam.ScanRowsResult {
        const next = self.coordinate(pos.logical / stride +| max_rows);
        return .{ .next = next, .rows = (next.logical - pos.logical) / stride, .eof = self.atEnd(source, next) };
    }
    pub fn matchRow(self: ParquetReader, source: seam.Source, pos: Pos, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx, _: api.DualLimit) seam.MatchRowResult {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.data.gpa);
        var found: ?u32 = null;
        var filtered = filter_ctx == null;
        for (0..self.data.columns) |column| {
            const col: u32 = @intCast(column);
            const p = relevant(primary, col) and found == null;
            const f = if (filter_ctx) |ctx| relevant(ctx, col) and !filtered else false;
            if (!p and !f) continue;
            text.clearRetainingCapacity();
            _ = self.data.appendCell(pos.logical / stride - 1, col, std.math.maxInt(usize), &text, self.data.gpa) catch |err| {
                if (err == error.WouldBlock) return .{ .next = pos, .matched_col = null, .filter_matched = false, .capped = false, .end = .inflating };
                self.data.failed.store(true, .release);
                break;
            };
            if (p and matcher.cellMatches(primary, col, text.items)) found = col;
            if (f and matcher.cellMatches(filter_ctx.?, col, text.items)) filtered = true;
        }
        const failed = self.data.failed.load(.acquire);
        const next = self.boundsAfter(source, pos, null).next;
        return .{ .next = next, .matched_col = if (!failed and filtered) found else null, .filter_matched = !failed and filtered, .capped = false, .end = if (failed) .damaged_eof else if (self.atEnd(source, next)) .clean_eof else .inflating };
    }
};
fn relevant(ctx: base.MatchCtx, col: u32) bool {
    return if (ctx.kind == .predicate) col == ctx.column else ctx.scope_mask.len == 0 or (col < ctx.scope_mask.len and ctx.scope_mask[col]);
}

pub const SelectedScanner = struct {
    reader: ParquetReader,
    source: seam.Source,
    pos: Pos,
    pub fn deinit(_: *SelectedScanner) void {}
    pub fn releaseLane(_: *SelectedScanner) void {}
    pub fn step(self: *SelectedScanner, selected: []const u32, cap: usize, _: u64, _: u64, buf: *std.ArrayList(u8), refs: *std.ArrayList(base.CellRef), gpa: std.mem.Allocator) seam.ReadError!seam.SelectedStep {
        const result = try self.reader.materializeSelected(self.source, self.pos, selected, cap, null, buf, refs, gpa);
        self.pos = result.next;
        return .{ .done = result.next };
    }
};
