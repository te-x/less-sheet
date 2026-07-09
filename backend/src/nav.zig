//! Navigation resolution over a counted region (caller holds the mutex).
//! Generic over WHICH predicate(s) are being satisfied (a plain search ctx,
//! a filter ctx, or both composed) and WHICH per-block counters describe the
//! counted region (search's block_counts or the filter's own) — reused by
//! both search-nav (src/search.zig) and the filtered-jump machinery (src/
//! filter.zig). Uses per-block counts to skip empty blocks, then re-lexes
//! only the target block(s) via the document's nav scratch — O(one block
//! re-lex), never O(file). See api/lesssheet.h SEARCH and FILTERED VIEWS.

const api = @import("api");
const base = @import("base.zig");
const lexer = @import("lexer.zig");
const matcher = @import("matcher.zig");

const Document = base.Document;
const MatchCtx = base.MatchCtx;
const CellRef = base.CellRef;
const checkpoint_interval = base.checkpoint_interval;

/// A found match: `row` is an ORIGINAL data-row number; `col` the matched
/// column (see matcher.matchRecord).
pub const Match = struct { row: u64, col: u32 };

pub const SourceLoc = struct { row: u64, offset: u64 };

/// True iff `filter_ctx` is absent or satisfied — the composed per-row test
/// shared by search-nav (unfiltered: filter_ctx null) and search-nav-under-a-
/// filter (filter_ctx = the active filter, so find evaluates only rows that
/// satisfy it too — see api/lesssheet.h FILTERED VIEWS FIND) and by the
/// filter-scan's own counting (primary_ctx = the filter, filter_ctx = null).
fn rowMatch(filter_ctx: ?MatchCtx, primary_ctx: MatchCtx, buf: []const u8, refs: []const CellRef) ?u32 {
    if (filter_ctx) |fc| {
        if (matcher.matchRecord(fc, buf, refs) == null) return null;
    }
    return matcher.matchRecord(primary_ctx, buf, refs);
}

/// Re-lex block `b` and evaluate rows [lo, hi); return the first (FORWARD) or
/// last (BACKWARD) matching row+col, or null. Caller holds the mutex.
fn relexBlock(doc: *Document, filter_ctx: ?MatchCtx, primary_ctx: MatchCtx, b: u64, lo: u64, hi: u64, dir: api.SearchDir) ?Match {
    if (b >= doc.checkpoints.items.len) return null;
    const cp = doc.checkpoints.items[@intCast(b)];
    var off: usize = @intCast(cp.offset);
    var row = cp.row;
    while (row < lo and off < doc.content.len) : (row += 1) {
        off = lexer.recordBounds(doc.content, off, doc.sep, doc.quote, doc.content.len, doc.encoding).next;
    }
    var result: ?Match = null;
    while (row < hi and off < doc.content.len) : (row += 1) {
        doc.nav_scratch.clearRetainingCapacity();
        doc.nav_refs.clearRetainingCapacity();
        // NAVIGATION also matches the FULL cell (cap = null), same as the scan.
        const res = lexer.lexInto(doc.content, off, doc.sep, doc.quote, doc.column_count, null, doc.content.len, doc.encoding, &doc.nav_scratch, &doc.nav_refs, doc.gpa) catch break;
        if (rowMatch(filter_ctx, primary_ctx, doc.nav_scratch.items, doc.nav_refs.items)) |col| {
            result = .{ .row = row, .col = col };
            if (dir == .forward) return result;
        }
        off = res.next;
    }
    return result;
}

/// First matching row in [anchor, hi) within the counted region described by
/// `block_counts`, or null.
pub fn findForwardMatch(doc: *Document, block_counts: []const u64, filter_ctx: ?MatchCtx, primary_ctx: MatchCtx, anchor: u64, hi: u64) ?Match {
    const nblocks = block_counts.len;
    var b: u64 = anchor / checkpoint_interval;
    while (b < nblocks) : (b += 1) {
        const block_start = b * checkpoint_interval;
        if (block_start >= hi) break;
        if (block_counts[@intCast(b)] == 0) continue; // skip empty block
        const lo = @max(anchor, block_start);
        const block_hi = @min(block_start + checkpoint_interval, hi);
        if (relexBlock(doc, filter_ctx, primary_ctx, b, lo, block_hi, .forward)) |m| return m;
    }
    return null;
}

/// Last matching row in [0, upper) within the counted region described by
/// `block_counts`, or null.
pub fn findBackwardMatch(doc: *Document, block_counts: []const u64, filter_ctx: ?MatchCtx, primary_ctx: MatchCtx, upper: u64) ?Match {
    if (upper == 0) return null;
    const nblocks = block_counts.len;
    if (nblocks == 0) return null;
    var b: u64 = (upper - 1) / checkpoint_interval;
    if (b >= nblocks) b = nblocks - 1;
    while (true) {
        const block_start = b * checkpoint_interval;
        if (block_counts[@intCast(b)] != 0) {
            const block_hi = @min(block_start + checkpoint_interval, upper);
            if (relexBlock(doc, filter_ctx, primary_ctx, b, block_start, block_hi, .backward)) |m| return m;
        }
        if (b == 0) break;
        b -= 1;
    }
    return null;
}

/// Count matches in block `b` for rows [b*interval, row]. Caller holds the mutex.
fn countInBlockUpTo(doc: *Document, filter_ctx: ?MatchCtx, primary_ctx: MatchCtx, b: u64, row: u64) u64 {
    if (b >= doc.checkpoints.items.len) return 0;
    const cp = doc.checkpoints.items[@intCast(b)];
    var off: usize = @intCast(cp.offset);
    var r = cp.row;
    var count: u64 = 0;
    while (r <= row and off < doc.content.len) : (r += 1) {
        doc.nav_scratch.clearRetainingCapacity();
        doc.nav_refs.clearRetainingCapacity();
        const res = lexer.lexInto(doc.content, off, doc.sep, doc.quote, doc.column_count, null, doc.content.len, doc.encoding, &doc.nav_scratch, &doc.nav_refs, doc.gpa) catch break;
        if (rowMatch(filter_ctx, primary_ctx, doc.nav_scratch.items, doc.nav_refs.items)) |_| count += 1;
        off = res.next;
    }
    return count;
}

/// 1-based position of `row` among all matching rows in file order (exact,
/// since [0, row] is fully counted): sum of prior block counts + in-block count.
pub fn positionOf(doc: *Document, block_counts: []const u64, filter_ctx: ?MatchCtx, primary_ctx: MatchCtx, row: u64) u64 {
    const b = row / checkpoint_interval;
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < b and i < block_counts.len) : (i += 1) sum += block_counts[i];
    return sum + countInBlockUpTo(doc, filter_ctx, primary_ctx, b, row);
}

/// Locate the ORIGINAL row/offset of the `need`-th (0-based) row satisfying
/// `ctx` within block `b` (rows [b*interval, min((b+1)*interval, hi_bound))),
/// re-lexing from its checkpoint. Caller holds the mutex.
fn nthMatchInBlock(doc: *Document, ctx: MatchCtx, b: u64, hi_bound: u64, need: u64) ?SourceLoc {
    if (b >= doc.checkpoints.items.len) return null;
    const cp = doc.checkpoints.items[@intCast(b)];
    const block_hi = @min((b + 1) * checkpoint_interval, hi_bound);
    var off: usize = @intCast(cp.offset);
    var row = cp.row;
    var seen: u64 = 0;
    while (row < block_hi and off < doc.content.len) : (row += 1) {
        doc.nav_scratch.clearRetainingCapacity();
        doc.nav_refs.clearRetainingCapacity();
        const res = lexer.lexInto(doc.content, off, doc.sep, doc.quote, doc.column_count, null, doc.content.len, doc.encoding, &doc.nav_scratch, &doc.nav_refs, doc.gpa) catch return null;
        if (matcher.matchRecord(ctx, doc.nav_scratch.items, doc.nav_refs.items) != null) {
            if (seen == need) return .{ .row = row, .offset = off };
            seen += 1;
        }
        off = res.next;
    }
    return null;
}

/// Locate the ORIGINAL row/offset of the `idx`-th (0-based) row satisfying
/// `ctx` within the counted region described by `block_counts` (bounded by
/// `hi_bound`, its row cursor). O(checkpoints) to find the block + a bounded
/// in-block re-lex — never O(idx)/O(matches) (see FILTERED VIEWS). Null when
/// `idx` is beyond the counted region's match count. Caller holds the mutex.
pub fn nthMatchLocation(doc: *Document, block_counts: []const u64, ctx: MatchCtx, hi_bound: u64, idx: u64) ?SourceLoc {
    var cum: u64 = 0;
    var b: u64 = 0;
    while (b < block_counts.len) : (b += 1) {
        const cnt = block_counts[b];
        if (cum + cnt > idx) return nthMatchInBlock(doc, ctx, b, hi_bound, idx - cum);
        cum += cnt;
    }
    return null;
}
