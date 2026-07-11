//! Navigation resolution over a counted region (caller holds the mutex).
//! Generic over WHICH predicate(s) are being satisfied (a plain search ctx,
//! a filter ctx, or both composed) and WHICH per-block counters describe the
//! counted region (search's block_counts or the filter's own) — reused by
//! both search-nav (src/search.zig) and the filtered-jump machinery (src/
//! filter.zig). Uses per-block counts to skip empty blocks, then re-lexes
//! only the target block(s) via the document's nav scratch — O(one block
//! re-lex), never O(file). See api/lesssheet.h SEARCH and FILTERED VIEWS.
//!
//! Also owns the sparse-checkpoint lookup (`bestCheckpoint`, shared by
//! window.zig and this file's own `nthMatchInBlock`) and, for
//! ARCH-huge-row-filtered, `nthMatchInBlock`'s per-row window-scan-cap bound
//! + the `oversizedMatch` lookup into a filter's recorded oversized-row match
//! results — see base.OversizedMatch. Parsing goes through `Document.reader`
//! (see docs/architecture/ARCH-reader-interface.md) — this module never
//! imports `lexer.zig`.

const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");

const Document = base.Document;
const MatchCtx = base.MatchCtx;
const CellRef = base.CellRef;
const Checkpoint = base.Checkpoint;
const OversizedMatch = base.OversizedMatch;
const Pos = base.Pos;
const checkpoint_interval = base.checkpoint_interval;

/// A found match: `row` is an ORIGINAL data-row number; `col` the matched
/// column (see matcher.matchRecord).
pub const Match = struct { row: u64, col: u32 };

pub const SourceLoc = struct { row: u64, pos: Pos };

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
    var pos = cp.pos;
    var row = cp.row;
    while (row < lo and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
        pos = doc.reader.boundsAfter(doc.source, pos, null).next;
    }
    var result: ?Match = null;
    while (row < hi and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
        doc.nav_scratch.clearRetainingCapacity();
        doc.nav_refs.clearRetainingCapacity();
        // NAVIGATION also matches the FULL cell (cap = null), same as the scan.
        const res = doc.reader.materialize(doc.source, pos, doc.column_count, null, null, &doc.nav_scratch, &doc.nav_refs, doc.gpa) catch break;
        if (rowMatch(filter_ctx, primary_ctx, doc.nav_scratch.items, doc.nav_refs.items)) |col| {
            result = .{ .row = row, .col = col };
            if (dir == .forward) return result;
        }
        pos = res.next;
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
    var pos = cp.pos;
    var r = cp.row;
    var count: u64 = 0;
    while (r <= row and !doc.reader.atEnd(doc.source, pos)) : (r += 1) {
        doc.nav_scratch.clearRetainingCapacity();
        doc.nav_refs.clearRetainingCapacity();
        const res = doc.reader.materialize(doc.source, pos, doc.column_count, null, null, &doc.nav_scratch, &doc.nav_refs, doc.gpa) catch break;
        if (rowMatch(filter_ctx, primary_ctx, doc.nav_scratch.items, doc.nav_refs.items)) |_| count += 1;
        pos = res.next;
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

/// Largest entry in a sorted (`.row` ascending) checkpoint list with
/// `.row <= row`, or null when the list is empty or every entry's row > row.
fn checkpointAtOrBefore(list: []const Checkpoint, row: u64) ?Checkpoint {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list[mid].row <= row) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return if (lo == 0) null else list[lo - 1];
}

/// Largest checkpoint with `.row <= row` (checkpoints[0].row == 0 always).
fn findCheckpoint(checkpoints: []const Checkpoint, row: u64) Checkpoint {
    return checkpointAtOrBefore(checkpoints, row).?;
}

/// `findCheckpoint`, but also considers the extra checkpoints the frontier
/// drops immediately after an oversized row (ARCH-huge-row-budget decision 2)
/// when one lands closer to `row` — this is what lets ls_window_set's skip-
/// from-checkpoint loop (window.windowSet / windowSetFiltered) and this
/// file's own nthMatchInBlock reach a row after a huge row without re-
/// scanning it. Caller holds the document mutex (reads `d.checkpoints` /
/// `d.oversized_checkpoints`).
pub fn bestCheckpoint(d: *Document, row: u64) Checkpoint {
    var best = findCheckpoint(d.checkpoints.items, row);
    if (checkpointAtOrBefore(d.oversized_checkpoints.items, row)) |alt| {
        if (alt.row > best.row) best = alt;
    }
    return best;
}

/// The recorded FULL-cell filter-match result for OVERSIZED row `row` (see
/// base.OversizedMatch / filter.filterScanChunk), or null when `row` has no
/// entry (never happens for a row already inside the filter's counted region
/// — see Document.filter_oversized_matches — a defensive fallback only).
/// `list` is row-ascending (the filter-scan's own cursor is monotonic,
/// contiguous, and single-owner, so it can never re-stage or reorder a row —
/// simpler than `oversized_checkpoints`, which is shared across scanners), so
/// a plain binary search suffices.
pub fn oversizedMatch(list: []const OversizedMatch, row: u64) ?bool {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list[mid].row == row) return list[mid].matched;
        if (list[mid].row < row) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// Locate the ORIGINAL row/position of the `need`-th (0-based) row satisfying
/// `ctx` within block `b` (rows [b*interval, min((b+1)*interval, hi_bound))),
/// re-lexing from its checkpoint. ARCH-huge-row-filtered: `ctx` must be the
/// ACTIVE FILTER's own predicate (filter.filterCtx) — true of both current
/// callers (window.windowSetFiltered and search.resolveNavLockedFiltered, via
/// nthMatchLocation below) — since that is what lets an OVERSIZED candidate's
/// match be taken from the already-recorded `doc.filter_oversized_matches`
/// (base.OversizedMatch) instead of re-testing it: the per-row lex is bounded
/// to the window scan cap, and a capped (oversized) row is skipped via the
/// checkpoint the frontier drops immediately after it (ARCH-huge-row-budget
/// decision 2) rather than by re-scanning its remaining bytes. Caller holds
/// the mutex.
fn nthMatchInBlock(doc: *Document, ctx: MatchCtx, b: u64, hi_bound: u64, need: u64) ?SourceLoc {
    if (b >= doc.checkpoints.items.len) return null;
    const cp = doc.checkpoints.items[@intCast(b)];
    const block_hi = @min((b + 1) * checkpoint_interval, hi_bound);
    var pos = cp.pos;
    var row = cp.row;
    var seen: u64 = 0;
    while (row < block_hi and !doc.reader.atEnd(doc.source, pos)) {
        const row_pos = pos;
        const row_limit = doc.reader.posAtByteBudget(doc.source, pos, api.window_row_scan_max_bytes);
        doc.nav_scratch.clearRetainingCapacity();
        doc.nav_refs.clearRetainingCapacity();
        const res = doc.reader.materialize(doc.source, pos, doc.column_count, null, row_limit, &doc.nav_scratch, &doc.nav_refs, doc.gpa) catch return null;
        if (res.capped) {
            // OVERSIZED: the match is decided from the filter-scan's already-
            // recorded FULL-cell result, never re-tested on this bounded
            // prefix and never by re-lexing to the row's true end.
            if (oversizedMatch(doc.filter_oversized_matches.items, row) orelse false) {
                if (seen == need) return .{ .row = row, .pos = row_pos };
                seen += 1;
            }
            const target_row = row + 1;
            const skip_cp = bestCheckpoint(doc, target_row);
            pos = skip_cp.pos;
            row = skip_cp.row;
            while (row < target_row) : (row += 1) {
                pos = doc.reader.boundsAfter(doc.source, pos, null).next;
            }
            continue;
        }
        if (matcher.matchRecord(ctx, doc.nav_scratch.items, doc.nav_refs.items) != null) {
            if (seen == need) return .{ .row = row, .pos = row_pos };
            seen += 1;
        }
        pos = res.next;
        row += 1;
    }
    return null;
}

/// Locate the ORIGINAL row/position of the `idx`-th (0-based) row satisfying
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
