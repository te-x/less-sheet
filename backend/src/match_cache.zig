//! One session-local counted prefix per Find mode, shared with Filter. Storage is
//! O(checkpoints + oversized rows), never a list of every matching row.
const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const search = @import("search.zig");
const filter = @import("filter.zig");
const nav = @import("nav.zig");
const sort = @import("sort.zig");

pub fn same(a: base.MatchCtx, b: base.MatchCtx) bool {
    if (a.kind != b.kind or a.q.fold != b.q.fold or
        !std.mem.eql(u8, a.q.value, b.q.value)) return false;
    if (a.kind == .predicate) return a.op == b.op and a.column == b.column;
    // Scope is a set: NULL and an explicit all-column mask are equivalent.
    for (0..a.column_count) |col| {
        if ((a.scope_mask.len == 0 or a.scope_mask[col]) !=
            (b.scope_mask.len == 0 or b.scope_mask[col])) return false;
    }
    return true;
}

/// A stalled chunk can append an empty counter without advancing its cursor.
/// Such a region must restart, even if the cursor is on a block boundary.
pub fn resumable(rows: u64, exact: bool, blocks: usize) bool {
    const remainder = rows % base.checkpoint_interval;
    return (exact or remainder == 0) and
        blocks == rows / base.checkpoint_interval + @intFromBool(remainder != 0);
}

const Entry = struct {
    query: matcher.Query = .empty,
    scope: std.ArrayList(bool) = .empty,
    kind: api.SearchKind = .text,
    op: api.SearchOp = .eq,
    column: u32 = 0,
    // null = whole-document predicate; otherwise an intersection with this
    // filter generation. Intersections must never seed a whole-document filter.
    filter_gen: ?u64 = null,
    counts: std.ArrayList(u64) = .empty,
    oversized: std.ArrayList(base.OversizedMatch) = .empty,
    rows: u64 = 0,
    pos: base.Pos = undefined,
    total: u64 = 0,
    exact: bool = false,
    progress: f64 = 0,
    sorted: sort.NavCache = .{},

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.query.deinit(gpa);
        self.scope.deinit(gpa);
        self.counts.deinit(gpa);
        self.oversized.deinit(gpa);
        self.sorted.deinit(gpa);
    }

    fn ctx(self: *const Entry, doc: *base.Document) base.MatchCtx {
        return .{ .kind = self.kind, .op = self.op, .column = self.column, .q = &self.query, .scope_mask = self.scope.items, .column_count = doc.column_count };
    }

    fn compatible(self: *const Entry, doc: *base.Document, target: base.MatchCtx, for_filter: bool) bool {
        if (base.sourceFaultCount(doc) != 0 or (!self.exact and self.rows == 0) or
            !same(self.ctx(doc), target)) return false;
        if (for_filter) return self.filter_gen == null;
        // Sorted navigation needs its own per-sorted-block tally, which a
        // source-order prefix cannot restore.
        if (sort.presented(doc) and !self.sorted.compatible(doc)) return false;
        if (doc.filter_state != .idle and self.rows > doc.filter_rows) return false;
        if (self.filter_gen) |gen| return doc.filter_state != .idle and gen == doc.filter_gen;
        return doc.filter_state == .idle or same(target, filter.filterCtx(doc));
    }

    fn reusable(doc: *base.Document, rows: u64, exact: bool, blocks: usize, oversized: []const base.OversizedMatch) bool {
        if (base.sourceFaultCount(doc) != 0) return false;
        // Only EOF or whole blocks can resume without double counting a
        // partial terminal block (e.g. a stalled network read).
        if ((!exact and rows == 0) or !resumable(rows, exact, blocks)) return false;
        for (doc.oversized_checkpoints.items) |cp| {
            // A checkpoint names the row AFTER the oversized row.
            if (cp.row > rows) break;
            if (nav.oversizedMatch(oversized, cp.row - 1) == null) return false;
        }
        return true;
    }

    // Best effort, transactional: an OOM leaves the old cache intact.
    fn save(self: *Entry, doc: *base.Document, source: base.MatchCtx, gen: ?u64, counts: []const u64, oversized: []const base.OversizedMatch, rows: u64, pos: base.Pos, total: u64, exact: bool, progress: f64, from_search: bool) void {
        if (!reusable(doc, rows, exact, counts.len, oversized)) return;
        if (same(self.ctx(doc), source) and self.filter_gen == gen and self.rows >= rows and
            (self.exact or !exact) and
            (!from_search or !sort.presented(doc) or self.sorted.compatible(doc))) return;
        var next: Entry = .{ .kind = source.kind, .op = source.op, .column = source.column, .filter_gen = gen, .rows = rows, .pos = pos, .total = total, .exact = exact, .progress = progress };
        var installed = false;
        defer if (!installed) next.deinit(doc.gpa);
        next.query = source.q.clone(doc.gpa) catch return;
        next.scope.appendSlice(doc.gpa, source.scope_mask) catch return;
        next.counts.appendSlice(doc.gpa, counts) catch return;
        next.oversized.appendSlice(doc.gpa, oversized) catch return;
        if (from_search) next.sorted.capture(doc) catch return;
        self.deinit(doc.gpa);
        self.* = next;
        installed = true;
    }

    /// Clear remains allocation-free: transfer the inactive filter's buffers.
    /// The worker owns separate snapshots; clear invalidates its generation.
    pub fn takeFilter(self: *Entry, doc: *base.Document) void {
        if (!reusable(doc, doc.filter_rows, doc.filter_total_exact, doc.filter_block_counts.items.len, doc.filter_oversized_matches.items)) return;
        if (self.compatible(doc, filter.filterCtx(doc), true) and self.rows >= doc.filter_rows and
            (self.exact or !doc.filter_total_exact)) return;
        self.deinit(doc.gpa);
        self.* = .{ .query = doc.filter_query, .scope = .fromOwnedSlice(doc.filter_scope_mask), .kind = doc.filter_kind, .op = doc.filter_op, .column = doc.filter_column, .counts = doc.filter_block_counts, .oversized = doc.filter_oversized_matches, .rows = doc.filter_rows, .pos = doc.filter_pos, .total = doc.filter_total, .exact = doc.filter_total_exact, .progress = doc.filter_progress };
        doc.filter_query = .empty;
        doc.filter_scope_mask = &.{};
        doc.filter_block_counts = .empty;
        doc.filter_oversized_matches = .empty;
    }

    /// Restore into a reset job; reserve both buffers before changing either.
    pub fn restore(self: *const Entry, doc: *base.Document, target: base.MatchCtx, for_filter: bool) bool {
        if (!self.compatible(doc, target, for_filter)) return false;
        const counts = if (for_filter) &doc.filter_block_counts else &doc.block_counts;
        const oversized = if (for_filter) &doc.filter_oversized_matches else &doc.search_oversized_matches;
        counts.ensureTotalCapacity(doc.gpa, self.counts.items.len) catch return false;
        oversized.ensureTotalCapacity(doc.gpa, self.oversized.items.len) catch return false;
        if (!for_filter and sort.presented(doc) and !self.sorted.restore(doc)) return false;
        counts.clearRetainingCapacity();
        counts.appendSliceAssumeCapacity(self.counts.items);
        oversized.clearRetainingCapacity();
        oversized.appendSliceAssumeCapacity(self.oversized.items);
        if (for_filter) {
            doc.filter_rows = self.rows;
            doc.filter_pos = self.pos;
            doc.filter_total = self.total;
            doc.filter_total_exact = self.exact;
            doc.filter_progress = self.progress;
        } else {
            doc.search_rows = self.rows;
            doc.search_pos = self.pos;
            doc.search_total = self.total;
            doc.search_total_exact = self.exact;
            doc.search_progress = self.progress;
        }
        return true;
    }
};

pub const Cache = struct {
    entries: [2]Entry = .{ .{}, .{} },

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        for (&self.entries) |*entry| entry.deinit(gpa);
    }

    /// Save the OUTGOING query before replacing it. Keeping the last query of
    /// each mode lets Text -> Where -> Text resume even if Where is still
    /// scanning. Only committed prefixes are copied, under the document mutex.
    pub fn remember(self: *Cache, doc: *base.Document, target: base.MatchCtx, for_filter: bool) void {
        if (doc.search_state != .idle) {
            const source = search.docCtx(doc);
            const global = doc.filter_state == .idle or same(source, filter.filterCtx(doc));
            self.entries[@intCast(@intFromEnum(source.kind))].save(doc, source, if (global) null else doc.filter_gen, doc.block_counts.items, doc.search_oversized_matches.items, doc.search_rows, doc.search_pos, doc.search_total, doc.search_total_exact, doc.search_progress, true);
        }
        if (doc.filter_state != .idle and same(target, filter.filterCtx(doc))) {
            const entry = &self.entries[@intCast(@intFromEnum(target.kind))];
            // Keep a compatible intersection for Find. A Filter needs the
            // whole-document predicate instead.
            if (!for_filter and entry.compatible(doc, target, false) and entry.exact) return;
            entry.save(doc, filter.filterCtx(doc), null, doc.filter_block_counts.items, doc.filter_oversized_matches.items, doc.filter_rows, doc.filter_pos, doc.filter_total, doc.filter_total_exact, doc.filter_progress, false);
        }
    }

    pub fn takeFilter(self: *Cache, doc: *base.Document) void {
        self.entries[@intCast(@intFromEnum(doc.filter_kind))].takeFilter(doc);
    }

    pub fn restore(self: *const Cache, doc: *base.Document, target: base.MatchCtx, for_filter: bool) bool {
        return self.entries[@intCast(@intFromEnum(target.kind))].restore(doc, target, for_filter);
    }
};
