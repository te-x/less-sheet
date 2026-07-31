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

pub const SelectedStep = union(enum) {
    paused: Pos,
    done: Pos,
    oversized: Pos,
};

pub const SelectedScanner = struct {
    cursor: source_mod.Cursor,
    sep: u8,
    quote: ?u8,
    encoding: u8,
    produced: u32 = 0,
    selected_index: usize = 0,
    field_start: usize = 0,
    truncated: bool = false,
    mode: enum { start, quoted, unquoted } = .start,
    source_start: u64,

    pub fn init(reader: CsvReader, source: Source, pos: Pos) SelectedScanner {
        return .{
            .cursor = source_mod.cursorAt(source, toOffset(pos), null, null),
            .sep = reader.sep,
            .quote = reader.quote,
            .encoding = reader.encoding,
            .source_start = pos.logical,
        };
    }

    pub fn deinit(self: *SelectedScanner) void {
        self.cursor.deinit();
    }

    pub fn releaseLane(self: *SelectedScanner) void {
        self.cursor.releaseLane();
    }

    fn stores(self: *const SelectedScanner, selected: []const u32) bool {
        return self.selected_index < selected.len and selected[self.selected_index] == self.produced;
    }

    fn appendUnit(self: *SelectedScanner, selected: []const u32, cap: usize, unit: enc.Unit, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        if (!self.stores(selected) or self.truncated) return;
        if (buf.items.len - self.field_start + unit.out_len > cap) {
            self.truncated = true;
            return;
        }
        try buf.appendSlice(gpa, unit.out[0..unit.out_len]);
    }

    fn finishField(self: *SelectedScanner, selected: []const u32, refs: *std.ArrayList(CellRef), buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        if (self.stores(selected)) {
            if (self.truncated and self.encoding == api.encoding_utf8)
                buf.shrinkRetainingCapacity(self.field_start + enc.utf8TrimToBoundary(buf.items[self.field_start..]));
            try refs.append(gpa, .{ .start = self.field_start, .len = buf.items.len - self.field_start, .truncated = self.truncated });
            self.selected_index += 1;
        }
        self.produced += 1;
        self.field_start = buf.items.len;
        self.truncated = false;
        self.mode = .start;
    }

    fn finishRecord(self: *SelectedScanner, selected: []const u32, refs: *std.ArrayList(CellRef), buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !SelectedStep {
        try self.finishField(selected, refs, buf, gpa);
        while (self.selected_index < selected.len) : (self.selected_index += 1)
            try refs.append(gpa, .{ .start = 0, .len = 0 });
        return .{ .done = cursorPos(&self.cursor) };
    }

    pub fn step(self: *SelectedScanner, selected: []const u32, cap: usize, work_budget: u64, row_budget: u64, buf: *std.ArrayList(u8), refs: *std.ArrayList(CellRef), gpa: std.mem.Allocator) !SelectedStep {
        self.cursor.resumeLane();
        const step_start = self.cursor.logical;
        const decoded_start = buf.items.len;
        const source_boundary = work_budget -| @min(work_budget, @as(u64, 8));
        const decoded_boundary = work_budget -| @min(work_budget, @as(u64, 4));
        while (true) {
            if (self.cursor.logical -| self.source_start >= row_budget)
                return .{ .oversized = cursorPos(&self.cursor) };
            if (self.cursor.logical -| step_start >= source_boundary or
                buf.items.len - decoded_start >= decoded_boundary)
                return .{ .paused = cursorPos(&self.cursor) };
            const unit = streamUnit(&self.cursor, self.encoding) orelse return self.finishRecord(selected, refs, buf, gpa);
            if (self.cursor.logical -| step_start +| unit.src_len > work_budget)
                return .{ .paused = cursorPos(&self.cursor) };
            if (self.cursor.logical -| self.source_start +| unit.src_len > row_budget)
                return .{ .oversized = cursorPos(&self.cursor) };
            switch (self.mode) {
                .start => {
                    self.field_start = buf.items.len;
                    if (self.quote) |q| if (enc.unitIsByte(unit, q)) {
                        self.cursor.advance(unit.src_len);
                        self.mode = .quoted;
                        continue;
                    };
                    self.mode = .unquoted;
                },
                .quoted => {
                    self.cursor.advance(unit.src_len);
                    if (self.quote) |q| if (enc.unitIsByte(unit, q)) {
                        if (streamUnit(&self.cursor, self.encoding)) |peek| if (enc.unitIsByte(peek, q)) {
                            if (self.cursor.logical -| self.source_start +| peek.src_len > row_budget)
                                return .{ .oversized = cursorPos(&self.cursor) };
                            try self.appendUnit(selected, cap, unit, buf, gpa);
                            self.cursor.advance(peek.src_len);
                            continue;
                        };
                        self.mode = .unquoted;
                        continue;
                    };
                    try self.appendUnit(selected, cap, unit, buf, gpa);
                    continue;
                },
                .unquoted => {},
            }
            if (enc.unitIsByte(unit, self.sep)) {
                self.cursor.advance(unit.src_len);
                try self.finishField(selected, refs, buf, gpa);
            } else if (enc.unitIsByte(unit, '\r') or enc.unitIsByte(unit, '\n')) {
                self.cursor.advance(unit.src_len);
                if (enc.unitIsByte(unit, '\r')) if (streamUnit(&self.cursor, self.encoding)) |next| {
                    if (enc.unitIsByte(next, '\n')) {
                        if (self.cursor.logical -| self.source_start +| next.src_len > row_budget)
                            return .{ .oversized = cursorPos(&self.cursor) };
                        self.cursor.advance(next.src_len);
                    }
                };
                return self.finishRecord(selected, refs, buf, gpa);
            } else {
                try self.appendUnit(selected, cap, unit, buf, gpa);
                self.cursor.advance(unit.src_len);
            }
        }
    }
};

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
            .http_range => |hr| hr.physical_base,
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
            .gzip, .http_range => boundsStream(source, pos, limit, self.sep, self.quote, self.encoding),
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
            .gzip, .http_range => try lexStream(source, pos, want, cap, limit, self.sep, self.quote, self.encoding, buf, refs, gpa),
        };
    }

    pub fn materializeSelected(
        self: CsvReader,
        source: Source,
        pos: Pos,
        selected: []const u32,
        cap: usize,
        limit: ?Pos,
        buf: *std.ArrayList(u8),
        refs: *std.ArrayList(CellRef),
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!MaterializeResult {
        return switch (source) {
            .mmap => {
                const content = source.slice(0, source.len());
                const lim: usize = if (limit) |l| toOffset(l) else content.len;
                const res = try lexer.lexSelected(content, toOffset(pos), self.sep, self.quote, selected, cap, lim, self.encoding, buf, refs, gpa);
                return .{ .next = toPos(res.next, source.mmap.physical_base +| res.next), .capped = res.capped };
            },
            .gzip, .http_range => try lexStreamSelected(source, pos, selected, cap, limit, self.sep, self.quote, self.encoding, buf, refs, gpa),
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
            .gzip, .http_range => cellStream(source, pos, col, limit, self.sep, self.quote, self.encoding, buf, buf_len),
        };
    }

    pub fn scanRows(self: CsvReader, source: Source, pos: Pos, max_rows: u64) reader_mod.ScanRowsResult {
        var cur = source_mod.cursorAt(source, toOffset(pos), null, null);
        defer cur.deinit();
        if (self.encoding == api.encoding_utf8) return scanUtf8Rows(&cur, self.sep, self.quote, max_rows);
        var rows: u64 = 0;
        // FRONTIER COMMIT GUARD (source.Source.commitBound), UTF-16 arm. Hoisted:
        // a local document never enters the guarded branch at all.
        const guarded = source.commitGuarded();
        while (rows < max_rows) {
            if (streamUnit(&cur, self.encoding) == null) break;
            // The row's OWN start, which is where the frontier stays if the row
            // turns out not to be committable (the lex below cannot be un-run).
            const row_start = if (guarded) cursorPos(&cur) else undefined;
            _ = boundsFromCursor(&cur, self.sep, self.quote, self.encoding);
            if (guarded and cur.logical > source.commitBound(cur.logical))
                return .{ .next = row_start, .rows = rows, .eof = false };
            rows += 1;
        }
        // security-hardening (e) AC-e3: as scanUtf8Rows -- an empty stream unit is
        // EOF only at a genuine end-of-source, never a network short-body stall.
        const eof = streamUnit(&cur, self.encoding) == null and !streamAtLimit(&cur) and cur.spanTerminal();
        return .{ .next = cursorPos(&cur), .rows = rows, .eof = eof };
    }

    pub fn matchRow(self: CsvReader, source: Source, pos: Pos, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx, limit: api.DualLimit) reader_mod.MatchRowResult {
        return matchStream(source, pos, self.sep, self.quote, self.encoding, primary, filter_ctx, limit);
    }

    /// Match the row at a retained sequential scan cursor.  FILTER/SEARCH use
    /// this only for gzip; keeping the Cursor alive keeps one inflater lane
    /// alive across every row in the chunk.
    pub fn matchRowAtScanCursor(self: CsvReader, cur: *source_mod.Cursor, primary: base.MatchCtx, filter_ctx: ?base.MatchCtx) reader_mod.MatchRowResult {
        return matchCursor(cur, self.sep, self.quote, self.encoding, primary, filter_ctx);
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
        .gzip, .http_range => blk: {
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
    // A TERMINATOR IS CONSUMED WHOLE, OR NOT AT ALL — the one rule that keeps this
    // walk's row count equal to the streaming lexer's (`boundsAfter`/`materialize`,
    // which re-lex from the positions this walk publishes). A CR whose LF falls in
    // the NEXT span is the only terminator a span cannot settle from its own bytes,
    // and it is settled AT the boundary below (`peek` reads through a span end;
    // `span` does not), never by carrying a pending-LF flag: such a flag drifted the
    // count in BOTH directions — set against an already-incremented index it
    // swallowed a following lone LF as a CRLF's second byte (UNDERcount), and since
    // `index.scanChunk` calls this once per checkpoint batch it did not survive the
    // RETURN, leaving a published position BETWEEN a CR and its LF where the next
    // call — and every re-lex from that checkpoint — counted the LF as its own empty
    // row (OVERcount). Neither is expressible now: there is no pending state to
    // mis-set or to drop, and every position this walk hands back is a row START.

    // FRONTIER COMMIT GUARD (source.Source.commitBound). Hoisted: a LOCAL document
    // leaves `commit_end` at maxInt, so the only per-row cost is one compare
    // against a loop-invariant register (and this loop is never reached for an mmap
    // Source at all -- index.scanChunk routes mmap through its own boundsAfter
    // loop). Offsets here are ABSOLUTE, never span-relative: the quoted-field
    // escape below advances the cursor MID-span, which would strand an index.
    const guarded = cur.source.?.commitGuarded();
    // The last row boundary that is BOTH whole and committable — the position this
    // call publishes, paired with `rows` (see the final position, below). A bulk span
    // walk otherwise leaves the cursor MID-ROW when the present region ends inside a
    // row, which would publish a frontier whose own lookahead is absent (the wedge
    // again, by a second route) and a row count that does not describe that position.
    var commit_logical: u64 = cur.logical;
    var withheld = false;
    while (rows < max_rows) {
        const bytes = cur.span();
        if (bytes.len == 0) break;
        var i: usize = 0;
        // ABSOLUTE logical offset of `bytes[i]`, minus `i` — the pass's anchor, so
        // the two offsets the row path needs (`row_end`, `commit_logical`) are one
        // add on a register instead of a load through `cur` per row. Sound because
        // the cursor moves only where the pass ENDS: the quoted-field escape (which
        // breaks, so the next pass re-anchors) and the span-ending CR below (which
        // re-anchors here). Still absolute, so a mid-span advance strands nothing.
        var span_base = cur.logical;
        // Cheap bound, NO demand (this span's bytes are present by construction, so
        // a demand here could only be a no-op): two atomic reads, once per 256 KiB.
        // A row ending past it re-checks WITH a demand below -- so the common row
        // pays one compare and no fetch.
        const commit_end: u64 = if (guarded) cur.source.?.commitBoundNoFetch() else std.math.maxInt(u64);
        while (i < bytes.len and rows < max_rows) {
            const b = bytes[i];
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
                // Terminator bytes NOT YET CONSUMED at `span_base + i` (1 for a lone
                // LF or a bare CR, 2 for a CRLF still whole in this span, 0 for a
                // bare CR already consumed by the boundary case below). One
                // `b == '\r'` test, one bound test: the span-end case is the ELSE of
                // "the LF is in this span", so it can no longer be reached with the
                // LF already consumed.
                var term: usize = 1;
                var boundary_cr = false;
                if (b == '\r') {
                    if (i + 1 < bytes.len) {
                        if (bytes[i + 1] == '\n') term = 2;
                    } else {
                        // SPAN-ENDING CR — at most once per span, never per row. The
                        // question is about the SUCCESSOR byte, so consume the CR and
                        // ask it AT the successor's own offset, which is the only way
                        // to ask either half of it correctly:
                        //   * `peek(1)` here demands the byte AT the cursor, and on
                        //     the sequential net arm that is the ONLY demand honored
                        //     -- `net_source.ensureSliceSequentialLocked` waits for
                        //     `internal` and IGNORES `want`, so a 2-byte peek AT the
                        //     CR comes back 1 byte long whenever the drain high-water
                        //     is CR+1 and would silently read a CRLF as a bare CR.
                        //     `commitBound` documents that same trap and works around
                        //     it the same way, by demanding its far byte separately
                        //     (net_source.zig:985-989).
                        //   * `spanTerminal` answers for the CURRENT offset only, so
                        //     asking it here asks about the successor -- the true-end
                        //     question this decision actually turns on, on EVERY
                        //     Source, with no `guarded` special case.
                        // `bytes` and the original `i` are DEAD from here: a gzip peek
                        // may re-fill the lane buffer `bytes` points into, so this
                        // branch reads neither again and ends the span pass (the
                        // quoted-field escape above follows the same rule).
                        boundary_cr = true;
                        cur.advance(i + 1);
                        i = 0;
                        span_base = cur.logical; // re-anchor: the cursor moved, `bytes` is dead
                        const p = cur.peek(1);
                        if (p.len > 0) {
                            term = if (p[0] == '\n') 1 else 0;
                        } else if (cur.spanTerminal()) {
                            term = 0; // a bare CR at the true end: nothing follows it
                        } else {
                            // The successor has NOT ARRIVED (a parked network stream),
                            // so CR-vs-CRLF is not decidable yet and guessing either
                            // way drifts the count. Give the row back exactly as the
                            // commit guard does -- uncounted, with the position rewound
                            // to the last whole terminator below -- and let the call
                            // that can see the byte count it.
                            withheld = true;
                            break;
                        }
                    }
                }
                // FRONTIER COMMIT GUARD: this row ends at `span_base + i + term`.
                // Count it only if the lookahead a later mutex-held re-lex will
                // peek there is already present; the second call DEMANDS that
                // lookahead on this (scan-worker) thread and re-reads the bound, so
                // a healthy document always proceeds and only a short/failed range
                // withholds. Reached at most once per row and, because a row
                // boundary rarely lands within `max_lookahead` of the present edge,
                // it demands at most once per chunk.
                const row_end = span_base + i + term;
                if (row_end > commit_end and row_end > cur.source.?.commitBound(row_end)) {
                    withheld = true;
                    break;
                }
                rows += 1;
                field_start = true;
                saw = false;
                i += term;
                // The TRUTHFUL PAIR, updated with the count it belongs to and never
                // apart from it: `(commit_logical, rows)` -- so `rows` needs no
                // shadow copy, and there is no state to fall out of step. One store
                // per row on every Source now, because the position this walk
                // publishes must be a row START on every Source (below).
                commit_logical = span_base + i;
                // `bytes` is dead (see above): end the pass and re-span. The cursor
                // sits just past the CR and `i` is what is left of the terminator (the
                // LF, or nothing), so the `cur.advance(i)` below lands exactly past it.
                if (boundary_cr) break;
            } else {
                field_start = false;
                i += 1;
            }
        }
        // Give the row back — either because its lookahead is not committable
        // (guarded) or because its terminator is not yet decidable (above). Both
        // leave the row UNCOUNTED, and the final position below rewinds to the last
        // whole terminator, so what is published is a pair a later call reproduces
        // exactly. The SCAN is not stopped for the caller's purposes -- it returns
        // normally with the rows it did count, and the withheld row is picked up by
        // the next chunk as soon as its successor bytes arrive.
        if (withheld) break;
        cur.advance(i);
    }
    // security-hardening (e) AC-e3: an empty span is EOF only at a genuine
    // end-of-source; a NETWORK short body leaves un-fetched bytes below the known
    // end, so an empty span there is a retryable STALL (the worker ends the jump
    // WITHOUT completing) -- never a clean EOF that would count a phantom tail row.
    const eof = cur.span().len == 0 and cur.spanTerminal();
    if (eof and saw and rows < max_rows) rows += 1;
    // FINAL POSITION: the last WHOLE terminator, i.e. a row START, paired with the
    // `rows` that describes it. At a genuine end there is nothing to withhold (every
    // byte is present and `peekHttp` caps at the known end), so EOF keeps the true
    // end — that is the 1f-b exemption, and without it every network document would
    // permanently lose its last row (the unterminated tail row counted just above is
    // exactly one such row).
    if (!eof and cur.logical != commit_logical) {
        // The walk stopped MID-ROW: the span ran out inside a row, or the row was
        // given back (commit guard, or an undecidable terminator). The bytes from
        // `commit_logical` to here belong to a row this call does not count, so
        // publishing THIS position would anchor the next row on its own middle --
        // `index.scanChunk` stores `{row, pos}` as the checkpoint verbatim, and every
        // re-lex from it would then serve that row's TAIL as a whole row and lose its
        // first cells. Rewinding costs only the re-lex of one row, which is what the
        // guarded arm has always paid here.
        if (guarded) {
            cur.seekTo(commit_logical); // position-only Source: sound (see seekTo)
        } else {
            // A gzip cursor can NEVER be rewound (`seekTo` asserts `commitGuarded`:
            // an inflate session cannot run backwards), so hand the `Pos` back
            // directly. Its physical is the CURSOR's, i.e. exactly what `cursorPos`
            // below would publish, because `physical` is a conservative progress
            // byte-count and NOT a companion coordinate: nothing derives a position
            // from it (`cursorAt` takes `pos.logical` only, `reader.posPhysicalBytes`
            // hands it verbatim to progress/madvise, `base.scanStalled` compares
            // `logical`), while `ls_index_poll` DOES pin it as monotone
            // non-decreasing (api/lesssheet.h: "bytes_scanned ... monotone
            // non-decreasing over the document's lifetime") and clamps only from
            // above. Publishing the one formula every other publisher uses, on this
            // same cursor and lane, is what keeps that guarantee: a compressed
            // high-water for `commit_logical` computed some other way can sit AHEAD
            // of the op window the next chunk publishes from and tick the counter
            // backward. Overstating the compressed bytes behind `commit_logical` by
            // the tail of one op is the safe direction; understating is not.
            return .{ .next = toPos(@intCast(commit_logical), cur.physicalPosition()), .rows = rows, .eof = false };
        }
    }
    return .{ .next = cursorPos(cur), .rows = rows, .eof = eof };
}

fn streamUnit(cur: anytype, encoding: u8) ?enc.Unit {
    // The ONE max-width peek in the lexer (a 4-byte UTF-16 surrogate pair). The
    // frontier commit guard sizes itself from the same const — see
    // source.max_lookahead.
    const bytes = cur.peek(source_mod.max_lookahead);
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

fn lexStreamSelected(source: Source, pos: Pos, selected: []const u32, cap: usize, limit: ?Pos, sep: u8, quote: ?u8, encoding: u8, buf: *std.ArrayList(u8), refs: *std.ArrayList(CellRef), gpa: std.mem.Allocator) !MaterializeResult {
    var cur = source_mod.cursorAt(source, toOffset(pos), if (limit) |l| toOffset(l) else null, null);
    defer cur.deinit();
    var produced: u32 = 0;
    var selected_index: usize = 0;
    while (true) {
        const store = selected_index < selected.len and selected[selected_index] == produced;
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

        const capped = ended and streamAtLimit(&cur);
        if (store) {
            truncated = truncated or capped;
            if (truncated and encoding == api.encoding_utf8)
                buf.shrinkRetainingCapacity(start + enc.utf8TrimToBoundary(buf.items[start..]));
            try refs.append(gpa, .{ .start = start, .len = buf.items.len - start, .truncated = truncated });
            selected_index += 1;
        }
        produced += 1;
        if (ended) {
            while (selected_index < selected.len) : (selected_index += 1)
                try refs.append(gpa, .{ .start = 0, .len = 0, .truncated = capped });
            return .{ .next = cursorPos(&cur), .capped = capped };
        }
        const structural = streamUnit(&cur, encoding).?;
        if (enc.unitIsByte(structural, sep)) {
            cur.advance(structural.src_len);
            continue;
        }
        finishTerminator(&cur, structural, encoding);
        while (selected_index < selected.len) : (selected_index += 1)
            try refs.append(gpa, .{ .start = 0, .len = 0 });
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
