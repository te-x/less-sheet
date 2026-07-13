//! Search (find-seek slice) — the streaming match-scan with O(checkpoints)
//! per-block counts, navigation over the counted region, and the shared
//! scan-slot state machine (jump / search / filter priority is arbitrated by
//! the worker in src/index.zig). See api/lesssheet.h SEARCH for the pinned
//! model; api/lesssheet.h FILTERED VIEWS FIND for how a concurrent filter
//! composes into the same scan. Parsing goes through `Document.reader` (see
//! docs/architecture/ARCH-reader-interface.md) — this module never imports
//! `lexer.zig`.

const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");
const filter = @import("filter.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const MatchCtx = base.MatchCtx;
const Pos = base.Pos;
const Match = nav.Match;
const checkpoint_interval = base.checkpoint_interval;
const searchProgress = base.searchProgress;

// ---------------------------------------------------------------------------
// The streaming match-scan (worker; lock-free chunk, mutex-batched commit).
// ---------------------------------------------------------------------------

const SearchChunk = struct {
    end_pos: Pos,
    end_row: u64,
    eof: bool,
    checkpoint: ?Checkpoint,
    matches: u64, // rows satisfying find (AND the filter, when one is active)
    filter_matches: u64, // rows satisfying the filter alone; meaningful only when filtered
};

/// Build the matcher context from the document (caller holds the mutex).
pub fn docCtx(doc: *Document) MatchCtx {
    return .{
        .kind = doc.search_kind,
        .op = doc.search_op,
        .column = doc.search_column,
        .fold = doc.search_fold,
        .value = doc.search_value,
        .value_dec = doc.search_value_dec,
        .scope_mask = doc.scope_mask,
        .column_count = doc.column_count,
        .failure = doc.search_failure,
    };
}

/// Snapshot the active request into worker-owned buffers (caller holds the
/// mutex). The worker matches lock-free against this snapshot, so ls_search_start
/// can replace/free the document's request buffers without a use-after-free.
/// Returns false on OOM — a TRUNCATED query/scope copy must never be matched
/// against (an empty query would match every cell); the caller fails the search.
pub fn refreshWorkerCtx(doc: *Document) bool {
    doc.w_value.clearRetainingCapacity();
    doc.w_value.appendSlice(doc.gpa, doc.search_value) catch return false;
    doc.w_mask.clearRetainingCapacity();
    doc.w_mask.appendSlice(doc.gpa, doc.scope_mask) catch return false;
    doc.w_failure.clearRetainingCapacity();
    doc.w_failure.appendSlice(doc.gpa, doc.search_failure) catch return false;
    doc.w_ctx = .{
        .kind = doc.search_kind,
        .op = doc.search_op,
        .column = doc.search_column,
        .fold = doc.search_fold,
        .value = doc.w_value.items,
        .value_dec = matcher.parseDecimal(doc.w_value.items),
        .scope_mask = doc.w_mask.items,
        .column_count = doc.column_count,
        .failure = doc.w_failure.items,
    };
    return true;
}

/// Lex + match one block of data rows (up to the next checkpoint boundary, EOF,
/// or a stop request) from `start_pos`/`start_row`, counting matches. Reads only
/// via the Reader (immutable mmap bytes, for CSV) + the worker snapshot;
/// reuses the scan scratch per row. `filtered` composes `doc.wf_ctx` (the
/// worker's lock-free filter snapshot, refreshed alongside `doc.w_ctx` — see
/// filter.refreshFilterWorkerCtx) with the find predicate: a row counts
/// toward `matches` only if it ALSO satisfies the filter (see api/
/// lesssheet.h FILTERED VIEWS FIND); `filter_matches` tallies the filter
/// alone, letting the caller re-drive the filter's own counted region as a
/// side effect (maybeAdvanceFilterFromSearch).
pub fn searchScanChunk(doc: *Document, start_pos: Pos, start_row: u64, filtered: bool, generation: u64) SearchChunk {
    var pos = start_pos;
    var row = start_row;
    var matches: u64 = 0;
    var filter_matches: u64 = 0;
    const reader_mod = @import("reader.zig");
    const scan = doc.beginMatchScan(.search, generation, start_pos);
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    base.beginOversizedChunk(doc);
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
        }
        if (doc.reader.atEnd(doc.source, pos)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
        }
        const res = if (scan) |cur|
            reader_mod.readerMatchRowAtScanCursor(doc.reader, cur, doc.w_ctx, if (filtered) doc.wf_ctx else null)
        else
            reader_mod.readerMatchRow(doc.reader, doc.source, pos, doc.w_ctx, if (filtered) doc.wf_ctx else null, .{});
        if (filtered and res.filter_matched) filter_matches += 1;
        if (res.matched_col != null) matches += 1;
        base.stageOversized(doc, row, pos, res.next);
        pos = res.next;
        row += 1;
        if (doc.source == .gzip) doc.gz_match_resident_bytes = @max(doc.gz_match_resident_bytes, 2 * @sizeOf(matcher.StreamCell));
        if (doc.reader.atEnd(doc.source, pos)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
        }
    }
    return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .pos = pos }, .matches = matches, .filter_matches = filter_matches };
}

/// Terminate the active search cleanly at its last consistent state (caller
/// holds the mutex): CANCELLED with counts/found/progress frozen and any
/// pending navigation resolved to NONE. Used both by ls_search_cancel and as
/// the fail-safe when a search allocation OOMs (a silently degraded search
/// would corrupt block<->count alignment or match against a truncated query).
pub fn failSearchLocked(doc: *Document) void {
    doc.search_state = .cancelled;
    if (doc.search_nav == .searching) {
        doc.search_nav = .none;
        doc.nav_pending = false;
    }
}

/// Fold a completed match-scan chunk into the counted region (caller holds the
/// mutex). One block per chunk (block b == block_counts.items[b]); advances the
/// shared frontier where the scan broke new ground beyond it. When `filtered`,
/// also re-drives the filter's OWN counted region with this chunk's
/// filter-only tally (maybeAdvanceFilterFromSearch) — a filtered find's own
/// scan "advances the frontier" for the filter too (see FILTERED VIEWS).
pub fn commitSearch(doc: *Document, res: SearchChunk, filtered: bool) void {
    const block = doc.search_rows / checkpoint_interval;
    const advancing = doc.reader.bytesConsumed(doc.source, res.end_pos) > doc.reader.bytesConsumed(doc.source, doc.frontier_pos);
    const need_cp = advancing and res.checkpoint != null;
    // Reserve counter (and any new nav checkpoint) storage BEFORE mutating the
    // cursor: OOM here fails the search cleanly rather than dropping a block
    // count (which would misalign block<->count and corrupt nav positions) or a
    // checkpoint (which would misdirect a later nav re-lex). Nothing is mutated
    // on failure, so the counted region stays exact at its last committed row.
    doc.block_counts.ensureUnusedCapacity(doc.gpa, 1) catch {
        failSearchLocked(doc);
        return;
    };
    if (need_cp) doc.checkpoints.ensureUnusedCapacity(doc.gpa, 1) catch {
        failSearchLocked(doc);
        return;
    };

    doc.block_counts.appendAssumeCapacity(res.matches);
    doc.search_rows = res.end_row;
    doc.search_pos = res.end_pos;
    doc.search_total +%= res.matches;
    if (advancing) {
        doc.frontier_pos = res.end_pos;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.appendAssumeCapacity(cp);
    }
    // ARCH-huge-row-budget: fold this chunk's staged oversized-row checkpoints
    // in IFF this chunk was the one advancing the frontier (same `advancing`
    // that gates the sibling `checkpoints` append above).
    base.drainOversized(doc, advancing);
    if (res.eof) {
        doc.complete = true;
        doc.total_rows = doc.search_rows;
        doc.search_state = .done;
        doc.search_total_exact = true;
        doc.search_progress = 1.0;
        doc.search_to_eof = true;
    } else {
        doc.search_progress = searchProgress(doc, res.end_pos);
    }
    if (filtered) maybeAdvanceFilterFromSearch(doc, block, res);
}

/// When SEARCH runs while a filter is active, its scan visits the SAME rows
/// the filter-scan would. Fold this chunk's filter-only tally into the
/// filter's OWN counted region too, IFF this is exactly the next unrecorded
/// filter block (both cursors always advance block-by-block from row 0, so
/// they can only be ahead of or exactly meet each other — never leave a gap).
/// A block the filter already knows independently is left untouched. Caller
/// holds the mutex. Best-effort: an allocation failure just skips extending
/// this time (the filter's own counted region simply lags a little longer).
fn maybeAdvanceFilterFromSearch(doc: *Document, block: u64, res: SearchChunk) void {
    if (block != doc.filter_block_counts.items.len) return;
    doc.filter_block_counts.ensureUnusedCapacity(doc.gpa, 1) catch return;
    doc.filter_block_counts.appendAssumeCapacity(res.filter_matches);
    doc.filter_rows = res.end_row;
    doc.filter_pos = res.end_pos;
    doc.filter_total +%= res.filter_matches;
    if (res.eof) {
        doc.filter_total_exact = true;
        doc.filter_progress = 1.0;
        if (doc.filter_state == .cancelled) doc.filter_state = .done;
    } else {
        doc.filter_progress = searchProgress(doc, res.end_pos);
    }
}

// ---------------------------------------------------------------------------
// Navigation resolution over the counted region (caller holds the mutex).
// Uses per-block counts to skip empty blocks, then re-lexes the target block(s)
// via the nav scratch — O(one block re-lex), never O(file).
// ---------------------------------------------------------------------------

/// `m.row` is an ORIGINAL data-row number. Unfiltered, that IS the reported
/// found_row; while filtered, found_row must be `m.row`'s FILTERED index (see
/// api/lesssheet.h FILTERED VIEWS FIND) — the count of filter matches
/// strictly before it (m.row itself satisfies the filter: rowMatch checked
/// it to find it at all), via the filter's OWN counted region.
fn setFound(doc: *Document, m: Match) void {
    doc.search_found_col = m.col;
    doc.search_position = nav.positionOf(doc, doc.block_counts.items, filter.activeFilterCtxOrNull(doc), docCtx(doc), m.row);
    doc.search_found_row = if (doc.filter_state != .idle)
        nav.positionOf(doc, doc.filter_block_counts.items, null, filter.filterCtx(doc), m.row) - 1
    else
        m.row;
    doc.search_nav = .found;
    doc.nav_pending = false;
}

fn setExhausted(doc: *Document) void {
    doc.search_nav = .exhausted;
    doc.nav_pending = false;
}

/// Resolve the pending navigation from the counted region if the answer is
/// determined; otherwise leave it pending (the scan will serve it). Caller holds
/// the mutex. FORWARD = first match at-or-after anchor; BACKWARD = last match
/// strictly before anchor; EXHAUSTED is core-uniform (the frontend wraps).
/// While filtered, dispatches to the FILTERED-INDEX variant below (see
/// api/lesssheet.h FILTERED VIEWS FIND: "ls_search_nav anchors and found_row
/// are FILTERED indices").
pub fn resolveNavLocked(doc: *Document) void {
    if (!doc.nav_pending) return;
    if (doc.filter_state != .idle) {
        // Filtered counted-region resolution can re-lex a full checkpoint
        // block. With a worker present it is a worker job, never mutex-held
        // caller work; the no-worker degraded mode retains its terminating
        // synchronous fallback.
        if (doc.worker != null) return;
        resolveNavLockedFiltered(doc);
        return;
    }
    const anchor = doc.nav_anchor;
    const counted = doc.search_rows;
    const done = doc.search_state == .done;
    if (doc.nav_dir == .forward) {
        if (anchor < counted) {
            if (nav.findForwardMatch(doc, doc.block_counts.items, null, docCtx(doc), anchor, counted)) |m| {
                setFound(doc, m);
                return;
            }
        }
        if (done) setExhausted(doc); // no match at-or-after anchor anywhere
    } else {
        // Answerable once [0, anchor) is fully counted (or the scan is DONE).
        if (counted >= anchor or done) {
            const upper = @min(anchor, counted);
            if (nav.findBackwardMatch(doc, doc.block_counts.items, null, docCtx(doc), upper)) |m| setFound(doc, m) else setExhausted(doc);
        }
    }
}

/// resolveNavLocked's filtered-coordinate variant: `doc.nav_anchor` is a
/// FILTERED index (not an original row). Converts it to the original row of
/// that filtered position via the filter's OWN counted region
/// (nthMatchLocation), then searches the combined (filter AND find) counted
/// region — `doc.block_counts` — from there, exactly like the unfiltered
/// path. Caller holds the mutex; see api/lesssheet.h FILTERED VIEWS FIND.
fn resolveNavLockedFiltered(doc: *Document) void {
    const anchor = doc.nav_anchor;
    const counted = doc.search_rows; // combined-match counted region (original rows)
    const search_done = doc.search_state == .done;
    const fctx = filter.filterCtx(doc);
    const pctx = docCtx(doc);
    if (doc.nav_dir == .forward) {
        if (anchor >= doc.filter_total) {
            // No row exists at/after this filtered index YET; only exhausted
            // once the filter is known to be exact (it never will).
            if (doc.filter_total_exact) setExhausted(doc);
            return;
        }
        const loc = nav.nthMatchLocation(doc, doc.filter_block_counts.items, fctx, doc.filter_rows, anchor) orelse return;
        if (loc.row < counted) {
            if (nav.findForwardMatch(doc, doc.block_counts.items, fctx, pctx, loc.row, counted)) |m| {
                setFound(doc, m);
                return;
            }
        }
        if (search_done) setExhausted(doc);
    } else {
        if (anchor == 0) {
            setExhausted(doc); // nothing is strictly before filtered index 0
            return;
        }
        var r0: u64 = 0;
        var have_bound = false;
        if (anchor - 1 < doc.filter_total) {
            if (nav.nthMatchLocation(doc, doc.filter_block_counts.items, fctx, doc.filter_rows, anchor - 1)) |loc| {
                r0 = loc.row + 1; // include that row itself: "< anchor" is inclusive of anchor-1
                have_bound = true;
            }
        } else if (doc.filter_total_exact) {
            r0 = doc.filter_rows; // anchor is at/past the (now fully known) filtered view's end
            have_bound = true;
        }
        if (!have_bound) return; // more filter matches could still land before `anchor`
        if (counted >= r0 or search_done) {
            const upper = @min(r0, counted);
            if (nav.findBackwardMatch(doc, doc.block_counts.items, fctx, pctx, upper)) |m| setFound(doc, m) else setExhausted(doc);
        }
    }
}

// ---------------------------------------------------------------------------
// Off-main filtered navigation. The worker snapshots only scalar plans and a
// checkpoint while holding the document mutex, then performs all source
// parsing after releasing it. search_gen/filter_gen/nav_gen validate every
// phase and the final short commit, so replacement and cancellation cannot
// publish stale results.
// ---------------------------------------------------------------------------

pub const FilteredNavOutcome = struct {
    found: bool,
    row: u64 = 0,
    col: u32 = 0,
    position: u64 = 0,
};

fn navJobCurrentLocked(doc: *Document, nav_gen: u64, search_gen: u64, filter_gen: u64) bool {
    return doc.nav_pending and doc.search_nav == .searching and
        doc.nav_gen == nav_gen and doc.search_gen == search_gen and
        doc.filter_gen == filter_gen and doc.filter_state != .idle;
}

fn locateFilteredIndexJob(doc: *Document, nav_gen: u64, search_gen: u64, filter_gen: u64, fctx: MatchCtx, idx: u64) ?nav.SourceLoc {
    dlock: {
        doc.lock();
        if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen)) {
            doc.unlock();
            return null;
        }
        var cum: u64 = 0;
        var b: usize = 0;
        while (b < doc.filter_block_counts.items.len) : (b += 1) {
            const count = doc.filter_block_counts.items[b];
            if (cum + count > idx) break;
            cum += count;
        }
        if (b >= doc.filter_block_counts.items.len or b >= doc.checkpoints.items.len) {
            doc.unlock();
            return null;
        }
        const cp = doc.checkpoints.items[b];
        const hi = @min((@as(u64, @intCast(b)) + 1) * checkpoint_interval, doc.filter_rows);
        const need = idx - cum;
        doc.unlock();

        var pos = cp.pos;
        var row = cp.row;
        var seen: u64 = 0;
        while (row < hi and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
            if (doc.stop_atomic.load(.monotonic)) return null;
            const row_pos = pos;
            const res = @import("reader.zig").readerMatchRow(doc.reader, doc.source, pos, fctx, null, .{});
            if (res.matched_col != null) {
                if (seen == need) return .{ .row = row, .pos = row_pos };
                seen += 1;
            }
            pos = res.next;
        }
        break :dlock;
    }
    return null;
}

fn scanSearchBlockJob(doc: *Document, pctx: MatchCtx, fctx: MatchCtx, cp: Checkpoint, lo: u64, hi: u64, dir: api.SearchDir) ?Match {
    var pos = cp.pos;
    var row = cp.row;
    while (row < lo and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
        if (doc.stop_atomic.load(.monotonic)) return null;
        pos = doc.reader.boundsAfter(doc.source, pos, null).next;
    }
    var found: ?Match = null;
    while (row < hi and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
        if (doc.stop_atomic.load(.monotonic)) return null;
        const res = @import("reader.zig").readerMatchRow(doc.reader, doc.source, pos, pctx, fctx, .{});
        if (res.matched_col) |col| {
            found = .{ .row = row, .col = col };
            if (dir == .forward) return found;
        }
        pos = res.next;
    }
    return found;
}

fn findSearchMatchJob(doc: *Document, nav_gen: u64, search_gen: u64, filter_gen: u64, pctx: MatchCtx, fctx: MatchCtx, bound: u64, dir: api.SearchDir) ?Match {
    if (dir == .forward) {
        var b: u64 = bound / checkpoint_interval;
        while (true) : (b += 1) {
            doc.lock();
            if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or b >= doc.block_counts.items.len) {
                doc.unlock();
                return null;
            }
            const count = doc.block_counts.items[@intCast(b)];
            const cp = doc.checkpoints.items[@intCast(b)];
            const hi = @min((b + 1) * checkpoint_interval, doc.search_rows);
            doc.unlock();
            if (count == 0) continue;
            const lo = @max(bound, b * checkpoint_interval);
            if (scanSearchBlockJob(doc, pctx, fctx, cp, lo, hi, .forward)) |m| return m;
        }
    }

    if (bound == 0) return null;
    doc.lock();
    if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or doc.block_counts.items.len == 0) {
        doc.unlock();
        return null;
    }
    var b: u64 = (bound - 1) / checkpoint_interval;
    if (b >= doc.block_counts.items.len) b = doc.block_counts.items.len - 1;
    doc.unlock();
    while (true) {
        doc.lock();
        if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen)) {
            doc.unlock();
            return null;
        }
        const count = doc.block_counts.items[@intCast(b)];
        const cp = doc.checkpoints.items[@intCast(b)];
        const hi = @min(@min((b + 1) * checkpoint_interval, bound), doc.search_rows);
        doc.unlock();
        if (count != 0) {
            if (scanSearchBlockJob(doc, pctx, fctx, cp, b * checkpoint_interval, hi, .backward)) |m| return m;
        }
        if (b == 0) return null;
        b -= 1;
    }
}

fn positionFilteredMatchJob(doc: *Document, nav_gen: u64, search_gen: u64, filter_gen: u64, pctx: MatchCtx, fctx: MatchCtx, found: Match) ?FilteredNavOutcome {
    const b = found.row / checkpoint_interval;
    doc.lock();
    if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or
        b >= doc.checkpoints.items.len or b >= doc.block_counts.items.len or
        b >= doc.filter_block_counts.items.len)
    {
        doc.unlock();
        return null;
    }
    var search_before: u64 = 0;
    var filter_before: u64 = 0;
    var i: usize = 0;
    while (i < b) : (i += 1) {
        search_before += doc.block_counts.items[i];
        filter_before += doc.filter_block_counts.items[i];
    }
    const cp = doc.checkpoints.items[@intCast(b)];
    doc.unlock();

    var pos = cp.pos;
    var row = cp.row;
    var search_in_block: u64 = 0;
    var filter_in_block: u64 = 0;
    while (row <= found.row and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
        if (doc.stop_atomic.load(.monotonic)) return null;
        const res = @import("reader.zig").readerMatchRow(doc.reader, doc.source, pos, pctx, fctx, .{});
        if (res.filter_matched) filter_in_block += 1;
        if (res.matched_col != null) search_in_block += 1;
        pos = res.next;
    }
    if (search_in_block == 0 or filter_in_block == 0) return null;
    return .{
        .found = true,
        .row = filter_before + filter_in_block - 1,
        .col = found.col,
        .position = search_before + search_in_block,
    };
}

/// Resolve one exact filtered navigation on the worker. Called with the
/// document mutex released; returns null only for a stale/cancelled job.
pub fn resolveFilteredNavOffMain(doc: *Document, nav_gen: u64, search_gen: u64, filter_gen: u64, anchor: u64, dir: api.SearchDir, pctx: MatchCtx, fctx: MatchCtx) ?FilteredNavOutcome {
    doc.lock();
    if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or
        doc.search_state != .done or !doc.filter_total_exact)
    {
        doc.unlock();
        return null;
    }
    const total = doc.filter_total;
    const filter_rows = doc.filter_rows;
    doc.unlock();

    var source_bound: u64 = 0;
    if (dir == .forward) {
        if (anchor >= total) return .{ .found = false };
        const loc = locateFilteredIndexJob(doc, nav_gen, search_gen, filter_gen, fctx, anchor) orelse return null;
        source_bound = loc.row;
    } else {
        if (anchor == 0 or total == 0) return .{ .found = false };
        if (anchor >= total) {
            source_bound = filter_rows;
        } else {
            const loc = locateFilteredIndexJob(doc, nav_gen, search_gen, filter_gen, fctx, anchor - 1) orelse return null;
            source_bound = loc.row + 1;
        }
    }

    const found = findSearchMatchJob(doc, nav_gen, search_gen, filter_gen, pctx, fctx, source_bound, dir) orelse {
        doc.lock();
        const current = navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen);
        doc.unlock();
        return if (current) .{ .found = false } else null;
    };
    return positionFilteredMatchJob(doc, nav_gen, search_gen, filter_gen, pctx, fctx, found);
}

// ---------------------------------------------------------------------------
// Search C-ABI logic (see api/lesssheet.h ls_search_start/nav/cancel/poll).
// The `pub export fn` wrappers stay in root.zig; these are their bodies.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_search_start`.
pub fn startSearch(d: *Document, request: *const api.SearchRequest) bool {
    const req = request.*;

    // Validate first — a rejected request changes NOTHING (no slot taken).
    const kind_i = @intFromEnum(req.kind);
    if (kind_i != 0 and kind_i != 1) return false;
    if (req.value_ptr == null and req.value_len != 0) return false;
    const value: []const u8 = if (req.value_ptr) |vp| vp[0..req.value_len] else &[_]u8{};
    var fold = false;
    if (kind_i == 0) { // TEXT
        if (value.len == 0) return false; // empty query means "no search"
        if (req.scope_ptr) |sp| {
            if (req.scope_len == 0) return false; // non-NULL empty scope
            var i: usize = 0;
            while (i < req.scope_len) : (i += 1) if (sp[i] >= d.column_count) return false;
        }
        fold = matcher.queryFolds(value);
    } else { // PREDICATE
        if (req.column >= d.column_count) return false;
        const op_i = @intFromEnum(req.op);
        if (op_i < 0 or op_i > 5) return false;
        if (op_i >= 2 and !matcher.parseDecimal(value).valid) return false; // ordering value must parse
    }

    // Allocate owned copies up front so an OOM rejects cleanly (no state change).
    const value_copy = d.gpa.dupe(u8, value) catch return false;
    var failure: []usize = &.{};
    if (kind_i == 0) failure = matcher.buildFailure(d.gpa, value_copy, fold) catch {
        d.gpa.free(value_copy);
        return false;
    };
    var mask: []bool = &.{};
    if (kind_i == 0 and req.scope_ptr != null) {
        mask = d.gpa.alloc(bool, d.column_count) catch {
            d.gpa.free(value_copy);
            if (failure.len > 0) d.gpa.free(failure);
            return false;
        };
        @memset(mask, false);
        const sp = req.scope_ptr.?;
        var i: usize = 0;
        while (i < req.scope_len) : (i += 1) mask[sp[i]] = true;
    }

    d.lock();
    // Replace any previous search ENTIRELY.
    if (d.search_value.len > 0) d.gpa.free(d.search_value);
    if (d.scope_mask.len > 0) d.gpa.free(d.scope_mask);
    if (d.search_failure.len > 0) d.gpa.free(d.search_failure);
    d.search_value = value_copy;
    d.scope_mask = mask;
    d.search_failure = failure;
    d.search_kind = req.kind;
    d.search_op = req.op;
    d.search_column = req.column;
    d.search_fold = fold;
    d.search_value_dec = if (kind_i == 1 and @intFromEnum(req.op) >= 2) matcher.parseDecimal(value_copy) else .{};
    d.search_gen +%= 1;

    // Take the scan slot: cancel a scanning jump (DONE persists; gains kept).
    if (d.jump_state == .scanning) {
        d.jump_state = .idle;
        d.jump_progress = 0.0;
    }

    // Reset counts / navigation / cursor; the match-scan starts from row 0.
    d.block_counts.clearRetainingCapacity();
    d.search_total = 0;
    d.search_total_exact = false;
    d.search_rows = 0;
    d.search_pos = d.data_start;
    d.search_progress = 0.0;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;
    d.search_nav = .none;
    d.nav_pending = false;
    d.search_to_eof = true;

    if (d.reader.atEnd(d.source, d.data_start) or d.column_count == 0) {
        // Nothing to scan: already DONE with total 0.
        d.search_state = .done;
        d.search_total_exact = true;
        d.search_progress = 1.0;
        d.unlock();
        return true;
    }
    d.search_state = .scanning;
    if (d.worker != null) {
        d.wakeWorker();
        d.unlock();
        return true;
    }
    // Degraded (worker never spawned at open): scan to completion synchronously
    // so the search always terminates. No other thread observes intermediate
    // state (the caller is blocked here). A snapshot OOM fails to CANCELLED,
    // which the loop guard below turns into an immediate, consistent terminal.
    if (refreshWorkerCtx(d)) d.w_gen = d.search_gen else failSearchLocked(d);
    const filtered = d.filter_state != .idle;
    if (filtered) {
        if (filter.refreshFilterWorkerCtx(d)) d.wf_gen = d.filter_gen else failSearchLocked(d);
    }
    const generation = d.search_gen;
    while (d.search_state == .scanning) {
        const res = searchScanChunk(d, d.search_pos, d.search_rows, filtered, generation);
        commitSearch(d, res, filtered);
        resolveNavLocked(d);
    }
    d.unlock();
    return true;
}

/// See api/lesssheet.h `ls_search_nav`.
pub fn navSearch(d: *Document, anchor_row: u64, dir: api.SearchDir) void {
    d.lock();
    defer d.unlock();
    d.nav_charged_bytes = 0;
    if (d.search_state == .idle) return; // no active search: no-op
    const dir_i = @intFromEnum(dir);
    if (dir_i != 0 and dir_i != 1) return; // out-of-domain direction: no-op

    // Replace any pending navigation; clear the previous found result.
    d.nav_gen +%= 1;
    d.nav_pending = true;
    d.nav_anchor = anchor_row;
    d.nav_dir = dir;
    d.search_nav = .searching;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;

    // The identity-view fast path is bounded by ordinary row sizes and retains
    // its existing synchronous behavior. Filtered resolution is deliberately
    // left SEARCHING for the worker because a counted block may contain giant
    // rows. nav_charge_active meters only work completed before this call
    // returns; the off-main branch therefore remains zero/constant.
    d.nav_charge_active = true;
    resolveNavLocked(d);
    d.nav_charge_active = false;
    if (!d.nav_pending) return;

    if (d.filter_state != .idle and d.worker != null) d.wakeWorker();

    // Must scan to answer: ensure the match-scan runs and owns the slot.
    if (d.search_state == .cancelled) {
        d.search_state = .scanning;
        d.search_to_eof = false; // resume only as far as the nav needs
    }
    if (d.search_state == .scanning) {
        if (d.jump_state == .scanning) { // re-take the slot from a scanning jump
            d.jump_state = .idle;
            d.jump_progress = 0.0;
        }
        if (d.worker != null) {
            d.wakeWorker();
        } else {
            // Degraded (no worker): scan synchronously until the nav resolves.
            if (d.search_gen != d.w_gen) {
                if (refreshWorkerCtx(d)) d.w_gen = d.search_gen else failSearchLocked(d);
            }
            const filtered = d.filter_state != .idle;
            if (filtered and d.filter_gen != d.wf_gen) {
                if (filter.refreshFilterWorkerCtx(d)) d.wf_gen = d.filter_gen else failSearchLocked(d);
            }
            const generation = d.search_gen;
            while (d.nav_pending and d.search_state == .scanning) {
                const res = searchScanChunk(d, d.search_pos, d.search_rows, filtered, generation);
                commitSearch(d, res, filtered);
                resolveNavLocked(d);
                if (d.search_state == .scanning and !d.search_to_eof and !d.nav_pending) d.search_state = .cancelled;
            }
        }
    }
}

/// See api/lesssheet.h `ls_search_cancel`. Zero allocation.
pub fn cancelSearch(d: *Document) void {
    d.lock();
    defer d.unlock();
    if (d.search_state == .scanning) {
        d.search_state = .cancelled; // counts / found / progress freeze
        if (d.search_nav == .searching) {
            d.search_nav = .none; // a pending nav resolves to NONE
            d.nav_pending = false;
        }
    }
    if (d.search_nav == .searching) {
        d.nav_gen +%= 1;
        d.search_nav = .none;
        d.nav_pending = false;
    }
    // LS_SEARCH_DONE persists; the jump slot and the AUTO indexer are untouched.
}

/// See api/lesssheet.h `ls_search_poll`. Zero allocation; never fails.
pub fn pollSearch(d: *Document) api.SearchStatus {
    d.lock();
    defer d.unlock();
    return .{
        .state = d.search_state,
        .nav = d.search_nav,
        .progress = d.search_progress,
        .found_row = d.search_found_row,
        .found_col = d.search_found_col,
        .position = d.search_position,
        .total = d.search_total,
        .total_exact = d.search_total_exact,
    };
}
