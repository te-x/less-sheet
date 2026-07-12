//! The CSV Reader: the first (and, in this slice, only) implementation of
//! the Reader interface (src/reader.zig) — CSV's format→rows/cells parsing,
//! wrapping `lexer.zig` / `encoding.zig` / `sniff.zig` (moved BEHIND this
//! module, not rewritten — see docs/architecture/ARCH-reader-interface.md).
//! Its row `Pos` IS a byte offset into the `Source`; every cast between
//! `Pos` and a byte offset lives HERE (`toPos`/`toOffset` below) — nothing
//! outside this file may rely on that (see reader.zig's module doc).

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const enc = @import("encoding.zig");
const lexer = @import("lexer.zig");
const sniff = @import("sniff.zig");
const matcher = @import("matcher.zig");
const source_mod = @import("source.zig");
const reader_mod = @import("reader.zig");

const Source = source_mod.Source;
const Pos = reader_mod.Pos;
const CellRef = base.CellRef;
const BoundsResult = reader_mod.BoundsResult;
const MaterializeResult = reader_mod.MaterializeResult;
const CellResult = reader_mod.CellResult;

fn toPos(off: usize, physical: u64) Pos {
    return .{ .logical = off, .physical = physical };
}

fn toOffset(pos: Pos) usize {
    return @intCast(pos.logical);
}

fn cursorPos(cur: *source_mod.Cursor) Pos {
    return toPos(@intCast(cur.logical), cur.physicalPosition());
}

const DirectCursor = struct {
    bytes: []const u8,
    logical: u64,
    logical_limit: ?u64,
    physical_base: u64,
    physical_limit: ?u64,

    fn end(self: *const DirectCursor) u64 {
        const logical_end = self.logical_limit orelse self.bytes.len;
        const physical_end = if (self.physical_limit) |p| p -| self.physical_base else self.bytes.len;
        return @min(@as(u64, self.bytes.len), @min(logical_end, physical_end));
    }

    pub fn peek(self: *DirectCursor, n: usize) []const u8 {
        const end_at = self.end();
        if (self.logical >= end_at) return &.{};
        return self.bytes[@intCast(self.logical)..@intCast(@min(end_at, self.logical +| n))];
    }

    pub fn advance(self: *DirectCursor, n: usize) void {
        self.logical += n;
    }
    pub fn atLimit(self: *const DirectCursor) bool {
        if (self.logical_limit) |lim| if (self.logical >= lim) return true;
        return if (self.physical_limit) |lim| self.physical_base +| self.logical >= lim else false;
    }
};

fn anyCursorPos(cur: anytype) Pos {
    if (@TypeOf(cur.*) == DirectCursor) return toPos(@intCast(cur.logical), cur.physical_base +| cur.logical);
    return cursorPos(cur);
}

/// The CSV Reader: the resolved dialect (sep/quote/encoding — see
/// `openHead`) plus the Reader ops. Immutable after construction; cheap to
/// copy (three small scalar fields), which is what lets `reader.Reader`
/// dispatch by value with no indirection.
pub const CsvReader = struct {
    sep: u8,
    quote: ?u8,
    encoding: u8,

    pub fn start(self: CsvReader, source: Source) Pos {
        _ = self;
        return toPos(0, switch (source) {
            .mmap => |m| m.physical_base,
            .gzip => 0,
        });
    }

    pub fn atEnd(self: CsvReader, source: Source, pos: Pos) bool {
        _ = self;
        return if (source.knownEnd()) |end| toOffset(pos) >= end else false;
    }

    /// See reader.Reader.posAtByteBudget. CSV: `min(from + budget, len)`,
    /// exactly the bound every window/head-scan call site computed inline
    /// before the reorg (now the ONLY place that arithmetic happens).
    pub fn posAtByteBudget(self: CsvReader, source: Source, from: Pos, budget: u64) Pos {
        _ = self;
        const off = toOffset(from);
        const add: usize = @intCast(budget);
        const bounded = off +| add;
        const physical = from.physical;
        const end = source.knownEnd() orelse return toPos(bounded, physical);
        return toPos(@min(bounded, @as(usize, @intCast(end))), physical);
    }

    pub fn bytesConsumed(self: CsvReader, source: Source, pos: Pos) u64 {
        _ = self;
        _ = source;
        return pos.logical;
    }

    pub fn boundsAfter(self: CsvReader, source: Source, pos: Pos, limit: ?Pos) BoundsResult {
        return switch (source) {
            .mmap => {
                const content = source.slice(0, source.len());
                const lim: usize = if (limit) |l| toOffset(l) else content.len;
                const b = lexer.recordBounds(content, toOffset(pos), self.sep, self.quote, lim, self.encoding);
                return .{ .next = toPos(b.next, source.mmap.physical_base +| b.next), .capped = b.capped };
            },
            .gzip => boundsStream(source, pos, limit, self.sep, self.quote, self.encoding),
        };
    }

    pub fn materialize(
        self: CsvReader,
        source: Source,
        pos: Pos,
        want: ?u32,
        cap: ?usize,
        limit: ?Pos,
        buf: *std.ArrayList(u8),
        refs: *std.ArrayList(CellRef),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!MaterializeResult {
        return switch (source) {
            .mmap => {
                const content = source.slice(0, source.len());
                const lim: usize = if (limit) |l| toOffset(l) else content.len;
                const res = try lexer.lexInto(content, toOffset(pos), self.sep, self.quote, want, cap, lim, self.encoding, buf, refs, gpa);
                return .{ .next = toPos(res.next, source.mmap.physical_base +| res.next), .capped = res.capped };
            },
            .gzip => try lexStream(source, pos, want, cap, limit, self.sep, self.quote, self.encoding, buf, refs, gpa),
        };
    }

    pub fn cell(
        self: CsvReader,
        source: Source,
        pos: Pos,
        col: u32,
        limit: ?Pos,
        buf: ?[*]u8,
        buf_len: usize,
    ) CellResult {
        return switch (source) {
            .mmap => {
                const content = source.slice(0, source.len());
                const lim: usize = if (limit) |l| toOffset(l) else content.len;
                const res = decodeColumn(content, toOffset(pos), self.sep, self.quote, lim, self.encoding, col, buf, buf_len);
                return .{ .len = res.len, .truncated = res.truncated };
            },
            .gzip => cellStream(source, pos, col, limit, self.sep, self.quote, self.encoding, buf, buf_len),
        };
    }

    pub fn scanRows(self: CsvReader, source: Source, pos: Pos, max_rows: u64) reader_mod.ScanRowsResult {
        var cur = source_mod.cursorAt(source, toOffset(pos), null, null);
        defer cur.deinit();
        if (self.encoding == api.encoding_utf8) return scanUtf8Rows(&cur, self.sep, self.quote, max_rows);
        var rows: u64 = 0;
        while (rows < max_rows) {
            if (streamUnit(&cur, self.encoding) == null) break;
            _ = boundsFromCursor(&cur, self.sep, self.quote, self.encoding);
            rows += 1;
        }
        const eof = streamUnit(&cur, self.encoding) == null and !streamAtLimit(&cur);
        return .{ .next = cursorPos(&cur), .rows = rows, .eof = eof };
    }

    pub fn matchRow(self: CsvReader, source: Source, pos: Pos, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx, limit: api.DualLimit) reader_mod.MatchRowResult {
        return matchStream(source, pos, self.sep, self.quote, self.encoding, primary, filter_ctx, limit);
    }
};

fn wantsCell(ctx: base.MatchCtx, col: u32) bool {
    return switch (ctx.kind) {
        .text => col < ctx.column_count and (ctx.scope_mask.len == 0 or ctx.scope_mask[col]),
        .predicate => col == ctx.column,
    };
}

fn matchStream(source: Source, pos: Pos, sep: u8, quote: ?u8, encoding: u8, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx, limit: api.DualLimit) reader_mod.MatchRowResult {
    const logical_limit = if (limit.logical) |n| pos.logical +| n else null;
    return switch (source) {
        .mmap => |m| blk: {
            if (encoding == api.encoding_utf8)
                break :blk matchMmapUtf8(m, pos, sep, quote, primary, filter_ctx, limit);
            var cur: DirectCursor = .{
                .bytes = m.bytes,
                .logical = pos.logical,
                .logical_limit = logical_limit,
                .physical_base = m.physical_base,
                .physical_limit = if (limit.physical) |n| pos.physical +| n else null,
            };
            break :blk matchCursor(&cur, sep, quote, encoding, primary, filter_ctx);
        },
        .gzip => blk: {
            var cur = source_mod.cursorAt(source, toOffset(pos), logical_limit, limit.physical);
            defer cur.deinit();
            break :blk matchCursor(&cur, sep, quote, encoding, primary, filter_ctx);
        },
    };
}

fn matchMmapUtf8(m: source_mod.Mmap, pos: Pos, sep: u8, quote: ?u8, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx, limit: api.DualLimit) reader_mod.MatchRowResult {
    const logical_end = if (limit.logical) |n| pos.logical +| n else m.bytes.len;
    const physical_end = if (limit.physical) |n| pos.physical +| n -| m.physical_base else m.bytes.len;
    const end: usize = @intCast(@min(@as(u64, m.bytes.len), @min(logical_end, physical_end)));
    var i: usize = @intCast(pos.logical);
    var col: u32 = 0;
    var primary_col: ?u32 = null;
    var filter_ok = filter_ctx == null;
    while (true) : (col += 1) {
        var ps = matcher.StreamCell.init(primary, col);
        var fs = if (filter_ctx) |fc| matcher.StreamCell.init(fc, col) else null;
        const pfeed = wantsCell(primary, col);
        const ffeed = if (filter_ctx) |fc| wantsCell(fc, col) else false;

        if (quote) |q| if (i < end and m.bytes[i] == q) {
            i += 1;
            while (i < end) {
                const rel = std.mem.findScalar(u8, m.bytes[i..end], q) orelse {
                    if (pfeed) ps.feed(m.bytes[i..end]);
                    if (ffeed) fs.?.feed(m.bytes[i..end]);
                    i = end;
                    break;
                };
                const q_at = i + rel;
                if (pfeed) ps.feed(m.bytes[i..q_at]);
                if (ffeed) fs.?.feed(m.bytes[i..q_at]);
                if (q_at + 1 < end and m.bytes[q_at + 1] == q) {
                    if (pfeed) ps.feed(&.{q});
                    if (ffeed) fs.?.feed(&.{q});
                    i = q_at + 2;
                    continue;
                }
                i = q_at + 1;
                break;
            }
        };

        if (i < end) {
            const rel = std.mem.findAny(u8, m.bytes[i..end], &.{ sep, '\r', '\n' });
            const structural = i + (rel orelse end - i);
            if (pfeed) ps.feed(m.bytes[i..structural]);
            if (ffeed) fs.?.feed(m.bytes[i..structural]);
            i = structural;
        }

        if (pfeed and primary_col == null and ps.matches()) primary_col = col;
        if (ffeed and fs.?.matches()) filter_ok = true;
        if (i >= end) {
            var missing = col + 1;
            while (missing < primary.column_count) : (missing += 1) {
                if (primary_col == null and wantsCell(primary, missing) and matcher.StreamCell.init(primary, missing).matches()) primary_col = missing;
                if (filter_ctx) |fc| {
                    if (wantsCell(fc, missing) and matcher.StreamCell.init(fc, missing).matches()) filter_ok = true;
                }
            }
            const capped = end < m.bytes.len;
            return .{ .next = toPos(i, m.physical_base +| i), .matched_col = if (filter_ok) primary_col else null, .filter_matched = filter_ok, .capped = capped, .end = if (capped) .budget_stop else .clean_eof };
        }
        if (m.bytes[i] == sep) {
            i += 1;
            continue;
        }
        if (m.bytes[i] == '\r') {
            i += 1;
            if (i < end and m.bytes[i] == '\n') i += 1;
        } else i += 1;
        var missing = col + 1;
        while (missing < primary.column_count) : (missing += 1) {
            if (primary_col == null and wantsCell(primary, missing) and matcher.StreamCell.init(primary, missing).matches()) primary_col = missing;
            if (filter_ctx) |fc| {
                if (wantsCell(fc, missing) and matcher.StreamCell.init(fc, missing).matches()) filter_ok = true;
            }
        }
        return .{ .next = toPos(i, m.physical_base +| i), .matched_col = if (filter_ok) primary_col else null, .filter_matched = filter_ok, .capped = false, .end = .inflating };
    }
}

fn matchCursor(cur: anytype, sep: u8, quote: ?u8, encoding: u8, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx) reader_mod.MatchRowResult {
    var col: u32 = 0;
    var primary_col: ?u32 = null;
    var filter_ok = filter_ctx == null;
    while (true) : (col += 1) {
        var ps = matcher.StreamCell.init(primary, col);
        var fs = if (filter_ctx) |fc| matcher.StreamCell.init(fc, col) else null;
        const pfeed = wantsCell(primary, col);
        const ffeed = if (filter_ctx) |fc| wantsCell(fc, col) else false;
        var ended = false;
        if (quote) |q| if (streamUnit(cur, encoding)) |first| {
            if (enc.unitIsByte(first, q)) {
                cur.advance(first.src_len);
                while (streamUnit(cur, encoding)) |u| {
                    cur.advance(u.src_len);
                    if (enc.unitIsByte(u, q)) {
                        if (streamUnit(cur, encoding)) |peek| if (enc.unitIsByte(peek, q)) {
                            if (pfeed) ps.feed(u.out[0..u.out_len]);
                            if (ffeed) fs.?.feed(u.out[0..u.out_len]);
                            cur.advance(peek.src_len);
                            continue;
                        };
                        break;
                    }
                    if (pfeed) ps.feed(u.out[0..u.out_len]);
                    if (ffeed) fs.?.feed(u.out[0..u.out_len]);
                } else ended = true;
            }
        };
        if (!ended) {
            while (streamUnit(cur, encoding)) |u| {
                if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\r') or enc.unitIsByte(u, '\n')) break;
                if (pfeed) ps.feed(u.out[0..u.out_len]);
                if (ffeed) fs.?.feed(u.out[0..u.out_len]);
                cur.advance(u.src_len);
            } else ended = true;
        }
        if (pfeed and primary_col == null and ps.matches()) primary_col = col;
        if (ffeed and fs.?.matches()) filter_ok = true;
        if (ended) {
            var missing = col + 1;
            while (missing < primary.column_count) : (missing += 1) {
                if (primary_col == null and wantsCell(primary, missing) and matcher.StreamCell.init(primary, missing).matches()) primary_col = missing;
                if (filter_ctx) |fc| {
                    if (wantsCell(fc, missing) and matcher.StreamCell.init(fc, missing).matches()) filter_ok = true;
                }
            }
            const capped = streamAtLimit(cur);
            return .{ .next = anyCursorPos(cur), .matched_col = if (filter_ok) primary_col else null, .filter_matched = filter_ok, .capped = capped, .end = if (capped) .budget_stop else .clean_eof };
        }
        const structural = streamUnit(cur, encoding).?;
        if (enc.unitIsByte(structural, sep)) {
            cur.advance(structural.src_len);
            continue;
        }
        finishTerminator(cur, structural, encoding);
        var missing = col + 1;
        while (missing < primary.column_count) : (missing += 1) {
            if (primary_col == null and wantsCell(primary, missing) and matcher.StreamCell.init(primary, missing).matches()) primary_col = missing;
            if (filter_ctx) |fc| {
                if (wantsCell(fc, missing) and matcher.StreamCell.init(fc, missing).matches()) filter_ok = true;
            }
        }
        return .{ .next = anyCursorPos(cur), .matched_col = if (filter_ok) primary_col else null, .filter_matched = filter_ok, .capped = false, .end = .inflating };
    }
}

fn scanUtf8Rows(cur: *source_mod.Cursor, sep: u8, quote: ?u8, max_rows: u64) reader_mod.ScanRowsResult {
    var rows: u64 = 0;
    var field_start = true;
    var quoted = false;
    var saw = false;
    var skip_lf = false;
    while (rows < max_rows) {
        const bytes = cur.span();
        if (bytes.len == 0) break;
        var i: usize = 0;
        while (i < bytes.len and rows < max_rows) {
            const b = bytes[i];
            if (skip_lf) {
                skip_lf = false;
                if (b == '\n') {
                    i += 1;
                    continue;
                }
            }
            saw = true;
            if (quoted) {
                if (quote != null and b == quote.?) {
                    if (i + 1 < bytes.len) {
                        if (bytes[i + 1] == quote.?) {
                            i += 2;
                            continue;
                        }
                        quoted = false;
                    } else {
                        cur.advance(i + 1);
                        const p = cur.peek(1);
                        if (p.len > 0 and p[0] == quote.?) cur.advance(1) else quoted = false;
                        i = 0;
                        break;
                    }
                }
                i += 1;
                continue;
            }
            if (field_start and quote != null and b == quote.?) {
                quoted = true;
                field_start = false;
                i += 1;
            } else if (b == sep) {
                field_start = true;
                i += 1;
            } else if (b == '\n' or b == '\r') {
                if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
                if (b == '\r' and i + 1 == bytes.len) skip_lf = true;
                rows += 1;
                field_start = true;
                saw = false;
                i += 1;
            } else {
                field_start = false;
                i += 1;
            }
        }
        cur.advance(i);
    }
    const eof = cur.span().len == 0;
    if (eof and saw and rows < max_rows) rows += 1;
    return .{ .next = cursorPos(cur), .rows = rows, .eof = eof };
}

fn streamUnit(cur: anytype, encoding: u8) ?enc.Unit {
    const bytes = cur.peek(4);
    return enc.decodeUnit(bytes, 0, bytes.len, encoding);
}

fn streamAtLimit(cur: anytype) bool {
    return cur.atLimit();
}

fn finishTerminator(cur: anytype, u: enc.Unit, encoding: u8) void {
    cur.advance(u.src_len);
    if (enc.unitIsByte(u, '\r')) {
        if (streamUnit(cur, encoding)) |nxt| if (enc.unitIsByte(nxt, '\n')) cur.advance(nxt.src_len);
    }
}

fn boundsStream(source: Source, pos: Pos, limit: ?Pos, sep: u8, quote: ?u8, encoding: u8) BoundsResult {
    var cur = source_mod.cursorAt(source, toOffset(pos), if (limit) |l| toOffset(l) else null, null);
    defer cur.deinit();
    return boundsFromCursor(&cur, sep, quote, encoding);
}

fn boundsFromCursor(cur: *source_mod.Cursor, sep: u8, quote: ?u8, encoding: u8) BoundsResult {
    while (true) {
        if (quote) |q| if (streamUnit(cur, encoding)) |first| {
            if (enc.unitIsByte(first, q)) {
                cur.advance(first.src_len);
                while (streamUnit(cur, encoding)) |u| {
                    cur.advance(u.src_len);
                    if (!enc.unitIsByte(u, q)) continue;
                    if (streamUnit(cur, encoding)) |peek| {
                        if (enc.unitIsByte(peek, q)) {
                            cur.advance(peek.src_len);
                            continue;
                        }
                    }
                    break;
                }
            }
        };
        while (streamUnit(cur, encoding)) |u| {
            if (enc.unitIsByte(u, sep)) {
                cur.advance(u.src_len);
                break;
            }
            if (enc.unitIsByte(u, '\r') or enc.unitIsByte(u, '\n')) {
                finishTerminator(cur, u, encoding);
                return .{ .next = cursorPos(cur), .capped = false };
            }
            cur.advance(u.src_len);
        } else return .{ .next = cursorPos(cur), .capped = streamAtLimit(cur) };
    }
}

fn appendStreamUnit(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, start: usize, u: enc.Unit, cap: ?usize, truncated: *bool) !void {
    if (truncated.*) return;
    if (cap) |n| if (buf.items.len - start + u.out_len > n) {
        truncated.* = true;
        return;
    };
    try buf.appendSlice(gpa, u.out[0..u.out_len]);
}

fn lexStream(source: Source, pos: Pos, want: ?u32, cap: ?usize, limit: ?Pos, sep: u8, quote: ?u8, encoding: u8, buf: *std.ArrayList(u8), refs: *std.ArrayList(CellRef), gpa: std.mem.Allocator) !MaterializeResult {
    var cur = source_mod.cursorAt(source, toOffset(pos), if (limit) |l| toOffset(l) else null, null);
    defer cur.deinit();
    var produced: u32 = 0;
    while (true) {
        const store = want == null or produced < want.?;
        const start = buf.items.len;
        var truncated = false;
        var ended = false;
        if (quote) |q| if (streamUnit(&cur, encoding)) |first| {
            if (enc.unitIsByte(first, q)) {
                cur.advance(first.src_len);
                while (streamUnit(&cur, encoding)) |u| {
                    cur.advance(u.src_len);
                    if (enc.unitIsByte(u, q)) {
                        if (streamUnit(&cur, encoding)) |peek| {
                            if (enc.unitIsByte(peek, q)) {
                                if (store) try appendStreamUnit(buf, gpa, start, u, cap, &truncated);
                                cur.advance(peek.src_len);
                                continue;
                            }
                        }
                        break;
                    }
                    if (store) try appendStreamUnit(buf, gpa, start, u, cap, &truncated);
                } else ended = true;
            }
        };
        if (!ended) {
            while (streamUnit(&cur, encoding)) |u| {
                if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\r') or enc.unitIsByte(u, '\n')) break;
                if (store) try appendStreamUnit(buf, gpa, start, u, cap, &truncated);
                cur.advance(u.src_len);
            } else ended = true;
        }

        if (ended) truncated = truncated or streamAtLimit(&cur);
        if (store) {
            if (truncated and encoding == api.encoding_utf8) buf.shrinkRetainingCapacity(start + enc.utf8TrimToBoundary(buf.items[start..]));
            try refs.append(gpa, .{ .start = start, .len = buf.items.len - start, .truncated = truncated });
        }
        produced += 1;
        if (ended) {
            if (want) |w| while (produced < w) : (produced += 1) try refs.append(gpa, .{ .start = 0, .len = 0 });
            return .{ .next = cursorPos(&cur), .capped = streamAtLimit(&cur) };
        }
        const structural = streamUnit(&cur, encoding).?;
        if (enc.unitIsByte(structural, sep)) {
            cur.advance(structural.src_len);
            continue;
        }
        finishTerminator(&cur, structural, encoding);
        if (want) |w| while (produced < w) : (produced += 1) try refs.append(gpa, .{ .start = 0, .len = 0 });
        return .{ .next = cursorPos(&cur), .capped = false };
    }
}

fn cellStream(source: Source, pos: Pos, col: u32, limit: ?Pos, sep: u8, quote: ?u8, encoding: u8, buf: ?[*]u8, buf_len: usize) CellResult {
    var cur = source_mod.cursorAt(source, toOffset(pos), if (limit) |l| toOffset(l) else null, null);
    defer cur.deinit();
    var produced: u32 = 0;
    while (true) : (produced += 1) {
        const store = produced == col;
        var out_len: usize = 0;
        var truncated = false;
        var ended = false;
        if (quote) |q| if (streamUnit(&cur, encoding)) |first| {
            if (enc.unitIsByte(first, q)) {
                cur.advance(first.src_len);
                while (streamUnit(&cur, encoding)) |u| {
                    cur.advance(u.src_len);
                    if (enc.unitIsByte(u, q)) {
                        if (streamUnit(&cur, encoding)) |peek| if (enc.unitIsByte(peek, q)) {
                            if (store) storeUnit(buf, buf_len, &out_len, &truncated, u);
                            cur.advance(peek.src_len);
                            continue;
                        };
                        break;
                    }
                    if (store) storeUnit(buf, buf_len, &out_len, &truncated, u);
                } else ended = true;
            }
        };
        if (!ended) {
            while (streamUnit(&cur, encoding)) |u| {
                if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\r') or enc.unitIsByte(u, '\n')) break;
                if (store) storeUnit(buf, buf_len, &out_len, &truncated, u);
                cur.advance(u.src_len);
            } else ended = true;
        }
        if (store) {
            truncated = truncated or (ended and streamAtLimit(&cur));
            if (truncated and encoding == api.encoding_utf8) {
                if (buf) |b| out_len = enc.utf8TrimToBoundary(b[0..out_len]);
            }
            return .{ .len = out_len, .truncated = truncated };
        }
        if (ended) return .{ .len = 0, .truncated = streamAtLimit(&cur) };
        const structural = streamUnit(&cur, encoding).?;
        if (enc.unitIsByte(structural, sep)) {
            cur.advance(structural.src_len);
            continue;
        }
        return .{ .len = 0, .truncated = false };
    }
}

// ---------------------------------------------------------------------------
// open/sniff (ARCH-reader-interface item 5): detect + set up. Called ONCE,
// directly by root.zig's openWithAllocator, before any Reader/Source value
// exists — it PRODUCES them.
// ---------------------------------------------------------------------------

pub const OpenResult = struct {
    reader: CsvReader,
    bom_len: u64,
    /// The post-BOM content slice (`mapping[bom_len..]`); the caller (root.
    /// zig) wraps it into a `source.Mmap` — kept a plain slice here so this
    /// module needs no dependency the other way (Document lives in base.zig).
    content: []const u8,
};

/// Resolve the source encoding, then the dialect, from the raw (pre-BOM-
/// strip) mapping bytes, returning the ready CSV Reader + the post-BOM
/// content slice. Mirrors the pipeline root.zig ran inline before this
/// reorg (see api/lesssheet.h "Pipeline order at open"): encoding resolution
/// runs on a bounded raw sample BEFORE dialect sniffing (sniffing needs
/// already-transcoded structure). `sample_bytes` bounds the encoding-
/// detection sample only (independent of the O(head) dialect/shape budget
/// applied later via `posAtByteBudget`). `mapping` is the whole (post-open,
/// pre-BOM-strip) file mapping, or an empty slice for a 0-byte file — always
/// run unconditionally, exactly like the pre-reorg root.zig (an empty
/// `mapping` still yields sensible sniffed defaults).
pub fn openHead(mapping: []const u8, opt: api.OpenOptions, sample_bytes: usize) OpenResult {
    const sample = mapping[0..@min(mapping.len, sample_bytes)];
    const enc_res = enc.resolveEncoding(sample, opt.encoding);
    const content = mapping[enc_res.bom_len..mapping.len];
    const rd = sniff.sniffDialect(content, opt, enc_res.encoding);
    return .{
        .reader = .{ .sep = rd.sep, .quote = rd.quote, .encoding = enc_res.encoding },
        .bom_len = enc_res.bom_len,
        .content = content,
    };
}

// ---------------------------------------------------------------------------
// decodeColumn (the `cell` op's implementation — the ls_cell_copy / former
// window.cellCopy primitive). Moved verbatim from window.zig: decode ONLY
// column `col` of the record starting at SOURCE offset `start`, touching no
// ArrayList/allocator (fields before `col` are scanned WITHOUT storing;
// decoding stops the instant `col` is resolved).
// ---------------------------------------------------------------------------

/// Append one decoded unit's UTF-8 output to `buf[0..buf_len]` at
/// `out_len.*` unless the cap is already reached or would be exceeded (never
/// a partial unit, so the written bytes are only ever cut at a unit boundary
/// — the `utf8TrimToBoundary` fixup in `decodeColumn` then fixes up the rarer
/// UTF-8-pass-through case where a "unit" is a single raw byte that can
/// itself land mid code point), latching `cap_truncated.*` and storing
/// nothing further once set. Mirrors lexer.zig's private `storeCapped`,
/// adapted to a raw fixed buffer instead of an ArrayList so the caller does
/// ZERO heap allocation.
fn storeUnit(buf: ?[*]u8, buf_len: usize, out_len: *usize, cap_truncated: *bool, u: enc.Unit) void {
    if (cap_truncated.*) return;
    if (out_len.* + @as(usize, u.out_len) > buf_len) {
        cap_truncated.* = true;
        return;
    }
    if (buf) |b| @memcpy(b[out_len.* .. out_len.* + u.out_len], u.out[0..u.out_len]);
    out_len.* += u.out_len;
}

/// Decode ONLY column `col` of the record starting at SOURCE offset `start`
/// into `buf[0..buf_len]` (nothing written when `col`'s field doesn't exist —
/// a ragged row — or `buf_len` is 0). Mirrors lexer.lexInto's per-field decode
/// (quote handling, structural sep/CR/LF scanning, the `utf8TrimToBoundary`
/// fixup on a cut field) but touches no ArrayList or allocator: fields before
/// `col` are scanned WITHOUT storing, and decoding stops the instant `col` is
/// resolved (found, cut, or padded) — it never looks at the rest of the row.
/// `limit` bounds the SOURCE bytes visited (the caller's per-row scan cap, or
/// `content.len` for the unbounded pinned-row-0 decode); ZERO heap
/// allocation.
///
/// `truncated` is true iff `col`'s full transcoded content exceeds the
/// written bytes: `buf_len` cut it, or `limit` is an ARTIFICIAL bound
/// (`limit != content.len` — the per-row source scan cap) reached before
/// `col` could be located or fully decoded. Reaching the TRUE end of the
/// content (`limit == content.len`) with no more separators is simply a
/// ragged/short row: `col` beyond it pads to the empty, UNTRUNCATED cell —
/// nothing is missing.
fn decodeColumn(
    content: []const u8,
    start: usize,
    sep: u8,
    quote: ?u8,
    limit: usize,
    encoding: u8,
    col: u32,
    buf: ?[*]u8,
    buf_len: usize,
) struct { len: usize, truncated: bool } {
    const artificial = limit != content.len;
    var i = start;
    var produced: u32 = 0;
    while (true) {
        const store = produced == col;
        var out_len: usize = 0;
        var cap_truncated = false;
        var hit_limit = false;

        if (quote) |q| {
            if (enc.decodeUnit(content, i, limit, encoding)) |first| {
                if (enc.unitIsByte(first, q)) {
                    i += first.src_len;
                    while (true) {
                        const u = enc.decodeUnit(content, i, limit, encoding) orelse {
                            hit_limit = true;
                            break;
                        };
                        if (enc.unitIsByte(u, q)) {
                            const peek = enc.decodeUnit(content, i + u.src_len, limit, encoding);
                            if (peek != null and enc.unitIsByte(peek.?, q)) {
                                if (store) storeUnit(buf, buf_len, &out_len, &cap_truncated, u);
                                i += u.src_len + peek.?.src_len;
                                continue;
                            }
                            i += u.src_len;
                            break;
                        }
                        if (store) storeUnit(buf, buf_len, &out_len, &cap_truncated, u);
                        i += u.src_len;
                    }
                }
            }
        }
        if (!hit_limit) {
            while (true) {
                const u = enc.decodeUnit(content, i, limit, encoding) orelse {
                    hit_limit = true;
                    break;
                };
                if (enc.unitIsByte(u, sep) or enc.unitIsByte(u, '\n') or enc.unitIsByte(u, '\r')) break;
                if (store) storeUnit(buf, buf_len, &out_len, &cap_truncated, u);
                i += u.src_len;
            }
        }

        const was_truncated = cap_truncated or (hit_limit and artificial);
        if (store) {
            if (was_truncated and encoding == api.encoding_utf8) {
                if (buf) |b| out_len = enc.utf8TrimToBoundary(b[0..out_len]);
            }
            return .{ .len = out_len, .truncated = was_truncated };
        }
        if (hit_limit) return .{ .len = 0, .truncated = artificial };

        produced += 1;
        const u = enc.decodeUnit(content, i, limit, encoding).?; // present: hit_limit was false
        if (enc.unitIsByte(u, sep)) {
            i += u.src_len;
            continue;
        }
        return .{ .len = 0, .truncated = false }; // record terminator: col beyond -> ragged pad
    }
}

// ---------------------------------------------------------------------------
// AC5 note (docs/architecture/ARCH-reader-interface.md) — validated on paper
// against the two acid-test format shapes; neither would touch reader.zig or
// any core file (window/index/nav/search/filter/root), only add a sibling
// `..._reader.zig` + a `Reader` union variant:
//
//   * Parquet (columnar-binary; most different from CSV). `Pos` would encode
//     `(row_group: u32, in_group_index: u32)` packed into the same `u64`
//     (still an opaque handle to the core). `start`/`atEnd` read the footer's
//     row-group directory; `posAtByteBudget` bounds "open" to the footer +
//     first row group (still O(head) bytes, per the ABI); `boundsAfter` just
//     increments `in_group_index` (wrapping into the next row group at its
//     boundary — no byte scan at all); `materialize`/`cell` decode the
//     row's typed column chunks into display text; `bytesConsumed` sums the
//     row groups' on-disk byte ranges up to `pos` (Parquet's footer already
//     has these, so the ABI's byte-denominated progress fields stay exact,
//     not estimated). No byte-oriented `Source` is touched at all — Parquet
//     reads its own file structure directly (see source.zig's module doc).
//
//   * ODS/XLSX (ZIP container of XML; the container+stateful-position acid
//     test). A `zip_reader.zig` Source variant streams-inflates one ZIP
//     entry (e.g. `xl/worksheets/sheet1.xml`) — `len`/`slice` hide the
//     inflate exactly like a future gzip Source (source.zig's module doc).
//     An `xml_reader.zig` Reader parses that inflated stream; because a
//     `<row>` element's true start can depend on open ancestor tags, `Pos`
//     packs an inflated-stream offset PLUS a small parser-state tag (e.g.
//     "inside <sheetData>, no open row") into the same opaque `u64` — still
//     just a value the core stores/compares/hands back, never inspects.
//     `boundsAfter`/`materialize`/`cell` resume the SAX-style scan from that
//     state instead of re-parsing from the top of the sheet.
//
// Both slot in as a new Reader (+ new Source, for ODS) variant with zero
// change to window.zig/index.zig/nav.zig/search.zig/filter.zig/root.zig,
// which is the seam this reorg exists to prove (ARCH-reader-interface AC5).
