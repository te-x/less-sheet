//! Search — the streaming match-scan with O(checkpoints)
//! per-block counts, navigation over the counted region, and the shared
//! scan-slot state machine (jump / search / filter priority is arbitrated by
//! the worker in src/index.zig). See api/lesssheet.h SEARCH for the pinned
//! model; api/lesssheet.h FILTERED VIEWS FIND for how a concurrent filter
//! composes into the same scan. Parsing goes through `Document.reader` (see
//! docs/architecture/ARCH-reader-interface.md) — this module never imports
//! `lexer.zig`.

const std = @import("std");
const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");
const filter = @import("filter.zig");
// FIND UNDER A SORT (api/lesssheet.h SORTED VIEWS §7): anchors and found_row
// are SORTED positions, resolved through the sort's inverse mapping.
const sort = @import("sort.zig");

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
    /// The chunk ended because the next bytes are NOT PRESENT (a network
    /// short/failed range below the known end), not because the source ended.
    /// Distinct from `eof` in every way that matters: nothing is counted, the
    /// document is NOT complete, and the caller must stop driving instead of
    /// re-entering on a zero-progress cursor.
    stalled: bool = false,
    checkpoint: ?Checkpoint,
    matches: u64, // rows satisfying find (AND the filter, when one is active)
    filter_matches: u64, // rows satisfying the filter alone; meaningful only when filtered
    /// FIND UNDER A SORT: this chunk staged its matches for the per-sorted-block
    /// tally (the flag was on when the chunk STARTED — snapshotted under the
    /// mutex by the caller, never re-read mid-chunk), and every one of them was
    /// staged successfully. Either being false means the counters cannot be
    /// complete, and the commit turns the tally off rather than keeping a
    /// tally that is short by an unknown amount.
    staged: bool = false,
    stage_dropped: bool = false,
};

/// Build the matcher context from the document (caller holds the mutex).
pub fn docCtx(doc: *Document) MatchCtx {
    return .{
        .kind = doc.search_kind,
        .op = doc.search_op,
        .column = doc.search_column,
        .q = &doc.search_query,
        .scope_mask = doc.scope_mask,
        .column_count = doc.column_count,
    };
}

/// Snapshot the active request into worker-owned buffers (caller holds the
/// mutex). The worker matches lock-free against this snapshot, so ls_search_start
/// can replace/free the document's request buffers without a use-after-free.
/// Returns false on OOM — a TRUNCATED query/scope copy must never be matched
/// against (an empty query would match every cell); the caller fails the search.
pub fn refreshWorkerCtx(doc: *Document) bool {
    doc.w_mask.clearRetainingCapacity();
    doc.w_mask.appendSlice(doc.gpa, doc.scope_mask) catch return false;
    // Build the new copy BEFORE dropping the old one: on OOM the worker keeps
    // matching against the previous (complete) snapshot and the caller fails
    // the search, rather than being left with a half-built query.
    const q = doc.search_query.clone(doc.gpa) catch return false;
    doc.w_query.deinit(doc.gpa);
    doc.w_query = q;
    doc.w_ctx = .{
        .kind = doc.search_kind,
        .op = doc.search_op,
        .column = doc.search_column,
        .q = &doc.w_query,
        .scope_mask = doc.w_mask.items,
        .column_count = doc.column_count,
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
pub fn searchScanChunk(doc: *Document, start_pos: Pos, start_row: u64, filtered: bool, tally: bool, generation: u64) SearchChunk {
    var pos = start_pos;
    var row = start_row;
    var matches: u64 = 0;
    var filter_matches: u64 = 0;
    var stage_dropped = false;
    const reader_mod = @import("reader.zig");
    const scan = doc.beginMatchScan(.search, generation, start_pos);
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    base.beginOversizedChunk(doc);
    doc.search_oversized_stage.clearRetainingCapacity();
    doc.filter_oversized_stage.clearRetainingCapacity();
    doc.search_match_stage.clearRetainingCapacity();
    // FRONTIER COMMIT GUARD (source.Source.commitBound), hoisted out of the row
    // loop: a LOCAL document pays one register test per row, no call.
    const guarded = doc.source.commitGuarded();
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = null, .matches = matches, .filter_matches = filter_matches, .staged = tally, .stage_dropped = stage_dropped };
        }
        if (doc.reader.atEnd(doc.source, pos)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches, .staged = tally, .stage_dropped = stage_dropped };
        }
        const res = if (scan) |cur|
            reader_mod.readerMatchRowAtScanCursor(doc.reader, cur, doc.w_ctx, if (filtered) doc.wf_ctx else null)
        else
            reader_mod.readerMatchRow(doc.reader, doc.source, pos, doc.w_ctx, if (filtered) doc.wf_ctx else null, .{});
        // Bail BEFORE counting this row if it consumed no bytes
        // (base.scanStalled) — the un-fetched tail must never be counted,
        // matched against, or staged.
        if (base.scanStalled(doc, pos, res.next)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = false, .stalled = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches, .staged = tally, .stage_dropped = stage_dropped };
        }
        // FRONTIER COMMIT GUARD (source.Source.commitBound): withhold a row whose
        // LOOKAHEAD is not present -- counting it would let a later MUTEX-HELD
        // re-lex of that same row block the whole document on a network fetch, and
        // can already hand the decoder a truncated peek (a UTF-16 surrogate pair
        // straddling the present edge silently becomes U+FFFD U+FFFD). The frontier
        // stays at `pos`, this row's own start. The demand inside `commitBound`
        // means a HEALTHY document never gets here; only a short/failed range does,
        // so this reports `stalled` exactly like the check above -- which is also
        // what keeps `commitSearch`'s one-block-count-per-chunk accounting intact
        // (a withheld partial chunk must not be re-entered and counted twice).
        if (guarded) {
            const row_end = doc.reader.logicalBytes(doc.source, res.next);
            if (row_end > doc.source.commitBound(row_end)) {
                doc.endMatchScanIf(.search, generation);
                return .{ .end_pos = pos, .end_row = row, .eof = false, .stalled = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches, .staged = tally, .stage_dropped = stage_dropped };
            }
        }
        if (filtered and res.filter_matched) filter_matches += 1;
        if (res.matched_col != null) {
            matches += 1;
            // FIND UNDER A SORT (ARCH FR7): stage this match's PRE-SORT view
            // index so the commit can tally it into the sorted-position block
            // counters through the inverse mapping. Bounded by the chunk (one
            // index block), never a document-wide match list, and skipped
            // entirely when no sort is presented.
            if (tally) {
                const base_index = if (filtered) doc.search_filter_cum + filter_matches - 1 else row;
                // A DROPPED match would leave that sorted block's counter short
                // — every later `position` off by one, and a block whose only
                // match was dropped skipped outright, which is a wrong answer
                // rather than a slow one. Record the drop; the commit throws
                // the whole tally away and the navigation rebuilds it.
                doc.search_match_stage.append(doc.gpa, base_index) catch {
                    stage_dropped = true;
                };
            }
        }
        base.stageOversized(doc, row, pos, res.next);
        if (doc.reader.bytesConsumed(doc.source, res.next) - doc.reader.bytesConsumed(doc.source, pos) > api.window_row_scan_max_bytes) {
            doc.search_oversized_stage.append(doc.gpa, .{ .row = row, .matched = res.matched_col != null }) catch {};
            if (filtered) doc.filter_oversized_stage.append(doc.gpa, .{ .row = row, .matched = res.filter_matched }) catch {};
        }
        pos = res.next;
        row += 1;
        if (doc.source == .gzip) doc.gz_match_resident_bytes = @max(doc.gz_match_resident_bytes, 2 * @sizeOf(matcher.StreamCell));
        if (doc.reader.atEnd(doc.source, pos)) {
            doc.endMatchScanIf(.search, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches, .staged = tally, .stage_dropped = stage_dropped };
        }
    }
    return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .pos = pos }, .matches = matches, .filter_matches = filter_matches, .staged = tally, .stage_dropped = stage_dropped };
}

/// Terminate a search whose chunk STALLED on un-fetched bytes
/// (`SearchChunk.stalled`). Call this AFTER `resolveNavLocked` at every driver,
/// so a navigation answerable within the rows that ARE present is served first
/// and only a nav that needed the un-fetched tail resolves to NONE. Freezes
/// counts exactly where the delivered bytes end; never marks the document
/// complete or the total exact. Idempotent.
pub fn finishStalledLocked(d: *Document) void {
    if (d.search_state == .scanning) failSearchLocked(d);
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
    doc.search_oversized_matches.appendSlice(doc.gpa, doc.search_oversized_stage.items) catch {};
    // ARCH FR7: fold this chunk's matches into the per-SORTED-block counters
    // (O(index blocks) memory, never a match list). Done here, inside the scan
    // that was already visiting these rows, so no navigation ever has to pay a
    // second pass for it. `doc.search_rows` is still this chunk's START row,
    // which is what lets the tally verify it has seen every row before it — a
    // gap (a dropped match, a chunk that ran while the flag was off, a
    // re-entered cursor) turns the tally OFF instead of leaving counters that
    // are short by an unknown amount.
    sort.navTallyLocked(doc, doc.search_match_stage.items, res.staged and !res.stage_dropped, doc.search_rows, res.end_row);
    doc.search_filter_cum += res.filter_matches;
    doc.search_rows = res.end_row;
    doc.search_pos = res.end_pos;
    doc.search_total +%= res.matches;
    if (advancing) {
        doc.frontier_pos = res.end_pos;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.appendAssumeCapacity(cp);
    }
    // Fold this chunk's staged oversized-row checkpoints in IFF this chunk was
    // the one advancing the frontier (same `advancing` that gates the sibling
    // `checkpoints` append above).
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
    doc.filter_oversized_matches.appendSlice(doc.gpa, doc.filter_oversized_stage.items) catch {};
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

// ---------------------------------------------------------------------------
// Budget gate for INLINE filtered-nav resolution: off-main only when
// synchronous resolution is not provably bounded. Computed purely from
// checkpoint offsets + per-block match counts (O(checkpoints), NO re-lex), it
// decides whether resolveNavLockedFiltered may run on the calling thread.
// Normal/bounded rows fit -> inline (the ABI's "synchronous after
// LS_SEARCH_DONE" promise); a giant-row crossing whose counted-block span
// exceeds window_budget_max_bytes does NOT -> defer off-main. This mirrors the
// unfiltered path, which resolves a single bounded checkpoint block inline.
// ---------------------------------------------------------------------------

/// Source logical-byte offset at the START of counted checkpoint block `b`.
fn blockStartByte(doc: *Document, b: usize) u64 {
    return doc.reader.logicalBytes(doc.source, doc.checkpoints.items[b].pos);
}

/// Source logical-byte offset at the END of counted checkpoint block `b` — the
/// next block's checkpoint, or the current counted frontier for the last block.
fn blockEndByte(doc: *Document, b: usize) u64 {
    if (b + 1 < doc.checkpoints.items.len)
        return doc.reader.logicalBytes(doc.source, doc.checkpoints.items[b + 1].pos);
    return doc.reader.logicalBytes(doc.source, doc.search_pos);
}

/// The checkpoint block holding the `idx`-th (0-based) FILTER match, or null
/// when `idx` is at/beyond the filter's counted match total.
fn filterMatchBlock(doc: *Document, idx: u64) ?usize {
    var cum: u64 = 0;
    var b: usize = 0;
    while (b < doc.filter_block_counts.items.len) : (b += 1) {
        cum += doc.filter_block_counts.items[b];
        if (cum > idx) return b;
    }
    return null;
}

/// First block at/after `from_block` that carries a combined (find AND filter)
/// match — the only block `findForwardMatch` re-lexes (it skips empty blocks for
/// free); null when the counted region has none beyond `from_block`.
fn firstCombinedBlockFrom(doc: *Document, from_block: usize) ?usize {
    var b: usize = from_block;
    while (b < doc.block_counts.items.len) : (b += 1) {
        if (doc.block_counts.items[b] != 0) return b;
    }
    return null;
}

/// Last block strictly before `upto_block` (exclusive) that carries a combined
/// match — the only block `findBackwardMatch` re-lexes; null when none.
fn lastCombinedBlockTo(doc: *Document, upto_block: usize) ?usize {
    var b: usize = @min(upto_block, doc.block_counts.items.len);
    while (b > 0) {
        b -= 1;
        if (doc.block_counts.items[b] != 0) return b;
    }
    return null;
}

/// True iff resolving the pending FILTERED navigation INLINE would re-lex a
/// checkpoint span within the synchronous responsiveness budget. The resolution
/// re-lexes the anchor's filter-match block (nthMatchLocation) and the one
/// combined-match block that carries the answer (findForward/BackwardMatch);
/// empty blocks between them are skipped, never scanned. The contiguous byte
/// span covering that block range (checkpoint offsets) upper-bounds the work —
/// tiny for normal rows, but > window_budget_max_bytes when the range straddles
/// a giant row.
///
/// The answer's block is NOT always the anchor's own block: when the anchor
/// block is non-empty in block_counts but all its combined matches fall on the
/// ALREADY-PASSED side of the anchor row (behind it for FORWARD / ahead of it
/// for BACKWARD), findForward/BackwardMatch re-lexes the anchor block, finds
/// nothing on the wanted side, and WALKS INTO the next non-empty combined block
/// (forward: beyond `lo`; backward: below `hi`) — which may hold a giant. The
/// bound therefore extends to that walked-into block, a safe over-defer that
/// never under-bounds the real re-lex. O(1)/O(checkpoints)
/// early-exit cases (no anchor row yet, nothing before filtered index 0) re-lex
/// nothing and always "fit". Caller holds the mutex.
fn filteredNavFitsBudget(doc: *Document) bool {
    if (doc.checkpoints.items.len == 0) return true;
    var lo: usize = undefined;
    var hi: usize = undefined;
    if (doc.nav_dir == .forward) {
        if (doc.nav_anchor >= doc.filter_total) return true; // no source row yet: O(1)
        lo = filterMatchBlock(doc, doc.nav_anchor) orelse return true;
        // The forward walk may pass block `lo` entirely (its matches all behind
        // the anchor row) into the next non-empty combined block BEYOND `lo`.
        hi = firstCombinedBlockFrom(doc, lo + 1) orelse lo;
    } else {
        if (doc.nav_anchor == 0) return true; // nothing before filtered index 0
        if (doc.nav_anchor - 1 < doc.filter_total) {
            hi = filterMatchBlock(doc, doc.nav_anchor - 1) orelse return true;
            // Symmetric: the backward walk may pass block `hi` entirely (its
            // matches all ahead of the anchor row) into the next non-empty
            // combined block BELOW `hi`.
            lo = lastCombinedBlockTo(doc, hi) orelse hi;
        } else if (doc.filter_total_exact) {
            // anchor is at/past the (fully known) filtered view's end: the bound
            // is filter_rows, so only the last combined block is re-lexed.
            lo = lastCombinedBlockTo(doc, doc.block_counts.items.len) orelse return true;
            hi = lo;
        } else return true; // bound not established yet: re-lex nothing
    }
    if (lo >= doc.checkpoints.items.len) return true;
    if (hi >= doc.checkpoints.items.len) hi = doc.checkpoints.items.len - 1;
    if (hi < lo) hi = lo;
    return (blockEndByte(doc, hi) -| blockStartByte(doc, lo)) <= api.window_budget_max_bytes;
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
    if (sort.presented(doc)) {
        // FIND UNDER A SORT. Full coverage is the precondition on BOTH axes —
        // every row counted, and the order final — and neither has an honest
        // partial answer in sorted space, so until then the navigation stays
        // LS_SEARCH_NAV_SEARCHING and this returns. The resolution itself is
        // the WORKER's job (src/index.zig `do_sort_nav`): it examines a whole
        // sorted-position block, which is window-sized work, and doing it on
        // the caller's thread with the mutex held would block every poll and
        // window read behind it — the same freeze the key pass's merge avoids.
        // The degraded no-worker mode resolves inline, as every other lane's
        // fallback does, because nothing else ever would.
        if (doc.sort_state != .active or doc.search_state != .done) return;
        if (doc.worker != null) {
            doc.wakeWorker();
            return;
        }
        resolveSortedNavOffMain(doc);
        return;
    }
    if (doc.filter_state != .idle) {
        // Filtered counted-region resolution can re-lex a checkpoint block that
        // may contain giant rows. Resolve INLINE when the block span the
        // resolution would re-lex fits the synchronous budget (the normal case:
        // api/lesssheet.h "synchronous after LS_SEARCH_DONE"); defer to the
        // off-main worker ONLY when a giant-row crossing would exceed it. The
        // no-worker degraded mode always resolves inline (its terminating
        // synchronous fallback).
        if (doc.worker == null or filteredNavFitsBudget(doc)) resolveNavLockedFiltered(doc);
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

// ---------------------------------------------------------------------------
// FIND UNDER A SORT (api/lesssheet.h SORTED VIEWS §7). Anchors and found_row
// are SORTED positions and "next" means next IN SORT ORDER. `total` is
// unchanged in VALUE — the matching row SET does not depend on the order — and
// `position` is the 1-based rank of found_row among all matching rows in
// SORTED order.
//
// THE ONE BEHAVIORAL COST the header pins: because a match at any sorted
// position can come from anywhere in the file, a navigation can only be
// answered once the match-scan has covered EVERY row AND the sort has reached
// LS_SORT_ACTIVE (only BROWSING converges — jump and find wait). Until then the
// navigation stays LS_SEARCH_NAV_SEARCHING and this function simply returns;
// the match-scan's commit and the key pass's completion both re-enter here.
//
// The resolution itself walks the matching rows in SOURCE order — skipping
// whole blocks with no combined match through the SAME per-block counters the
// unsorted path uses, never a materialized match-row list — and maps each one
// through the sort's INVERSE mapping to its sorted position. Memory stays
// O(index checkpoints).
// ---------------------------------------------------------------------------

/// Everything the off-lock sorted-navigation work reads from the document,
/// snapshotted under the mutex. The predicates are the WORKER's own copies
/// (`w_ctx` / `wf_ctx`), never the document's request buffers, so a concurrent
/// ls_search_start cannot free them under the walk — the same rule every other
/// lock-free scan in this core follows. The three tables are stable for the
/// duration: this work only runs once the search is DONE, which means the
/// frontier is complete and no scan is appending to them.
const SortedNavCtx = struct {
    pctx: MatchCtx,
    fctx: ?MatchCtx,
    filtered: bool,
    checkpoints: []const Checkpoint,
    oversized: []const Checkpoint,
    block_counts: []const u64,
    filter_block_counts: []const u64,
    counted: u64,
};

fn sortedNavCtx(doc: *Document) SortedNavCtx {
    const filtered = doc.filter_state != .idle;
    return .{
        .pctx = doc.w_ctx,
        .fctx = if (filtered) doc.wf_ctx else null,
        .filtered = filtered,
        .checkpoints = doc.checkpoints.items,
        .oversized = doc.oversized_checkpoints.items,
        .block_counts = doc.block_counts.items,
        .filter_block_counts = doc.filter_block_counts.items,
        .counted = doc.search_rows,
    };
}

/// FALLBACK counter builder: the counted region walked ONCE, in source order,
/// tallying every match into the sort's per-SORTED-block counters. Normally the
/// match-scan tallies as it goes (see `commitSearch`), so this never runs; it
/// exists for the corner case where the search finished while the sort was
/// still BUILDING, so no inverse mapping existed at the time. Whole blocks with
/// no combined match are skipped through the same per-block counters the
/// unsorted path uses.
///
/// Runs with the mutex RELEASED (the caller holds the sort's busy flag),
/// re-taking it only to fold each finished block's tally in — a few
/// microseconds per 2048 rows.
fn buildSortedCounters(doc: *Document, c: SortedNavCtx) bool {
    var stage: std.ArrayList(u64) = .empty;
    defer stage.deinit(doc.gpa);
    var cum_filtered: u64 = 0;
    var b: usize = 0;
    var ok = true;
    while (b < c.block_counts.len) : (b += 1) {
        const block_start = @as(u64, b) * checkpoint_interval;
        if (block_start >= c.counted) break;
        if (c.block_counts[b] == 0) {
            // No combined match here — but the FILTERED index still has to
            // advance, and the filter's own per-block counter says by how much
            // with no re-lex at all.
            if (c.filtered and b < c.filter_block_counts.len) cum_filtered += c.filter_block_counts[b];
            continue;
        }
        if (b >= c.checkpoints.len) break;
        if (doc.stop_atomic.load(.monotonic) or doc.sort_scan_interrupt.load(.acquire)) return false;
        const cp = c.checkpoints[b];
        var pos = cp.pos;
        var row = cp.row;
        const block_hi = @min(block_start + checkpoint_interval, c.counted);
        stage.clearRetainingCapacity();
        while (row < block_hi and !doc.reader.atEnd(doc.source, pos)) : (row += 1) {
            const res = @import("reader.zig").readerMatchRow(doc.reader, doc.source, pos, c.pctx, c.fctx, .{});
            pos = res.next;
            const in_view = !c.filtered or res.filter_matched;
            const base_index = if (c.filtered) cum_filtered else row;
            if (in_view and c.filtered) cum_filtered += 1;
            if (!in_view or res.matched_col == null) continue;
            stage.append(doc.gpa, base_index) catch return false;
        }
        doc.lock();
        ok = sort.navTallyRebuildLocked(doc, stage.items);
        doc.unlock();
        if (!ok) return false;
    }
    doc.lock();
    sort.navMarkReadyLocked(doc);
    doc.unlock();
    return true;
}

/// Test the rows of ONE sorted-position block and report which of its positions
/// match. The block's positions map to source rows scattered over the whole
/// file, so they are visited in ASCENDING SOURCE order behind a forward cursor:
/// that makes the walk no costlier than materializing a window of the same
/// rows, and much cheaper whenever several share a checkpoint block. Runs with
/// the mutex RELEASED.
fn scanSortedBlock(doc: *Document, c: SortedNavCtx, plan: sort.NavPlan, positions: *std.ArrayList(u64), columns: *std.ArrayList(u32)) bool {
    positions.clearRetainingCapacity();
    columns.clearRetainingCapacity();

    const Pair = struct { a: u64, b: u64 };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(doc.gpa);
    {
        // The mapping read is the one part that touches the sort's build; the
        // busy flag the caller holds is what keeps it alive.
        doc.lock();
        defer doc.unlock();
        var p = plan.lo;
        while (p < plan.hi) : (p += 1) {
            const src = sort.sourceRowOfPosition(doc, p) orelse continue;
            pairs.append(doc.gpa, .{ .a = src, .b = p }) catch return false;
        }
    }
    const BySrc = struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            return x.a < y.a;
        }
    };
    std.mem.sort(Pair, pairs.items, {}, BySrc.less);

    var hits: std.ArrayList(Pair) = .empty;
    defer hits.deinit(doc.gpa);
    var cursor_row: u64 = 0;
    var cursor_pos: Pos = doc.data_start;
    var cursor_valid = false;
    for (pairs.items) |pair| {
        if (doc.stop_atomic.load(.monotonic) or doc.sort_scan_interrupt.load(.acquire)) return false;
        const cp = nav.bestCheckpointIn(c.checkpoints, c.oversized, pair.a);
        var row = cp.row;
        var at = cp.pos;
        if (cursor_valid and cursor_row <= pair.a and cursor_row >= cp.row) {
            row = cursor_row;
            at = cursor_pos;
        }
        while (row < pair.a and !doc.reader.atEnd(doc.source, at)) : (row += 1) {
            at = doc.reader.boundsAfter(doc.source, at, null).next;
        }
        if (row != pair.a) continue;
        cursor_valid = true;
        cursor_row = row;
        cursor_pos = at;
        const res = @import("reader.zig").readerMatchRow(doc.reader, doc.source, at, c.pctx, c.fctx, .{});
        const in_view = !c.filtered or res.filter_matched;
        if (in_view) if (res.matched_col) |col| {
            hits.append(doc.gpa, .{ .a = col, .b = pair.b }) catch return false;
        };
    }
    const ByPos = struct {
        fn less(_: void, x: Pair, y: Pair) bool {
            return x.b < y.b;
        }
    };
    std.mem.sort(Pair, hits.items, {}, ByPos.less);
    for (hits.items) |h| {
        positions.append(doc.gpa, h.b) catch return false;
        columns.append(doc.gpa, @intCast(h.a)) catch return false;
    }
    return true;
}

/// A sorted-navigation answer, computed off-lock and published under the mutex.
const SortedNavOutcome = struct {
    found: bool,
    pos: u64 = 0,
    col: u32 = 0,
    position: u64 = 0,
};

/// Walk the per-SORTED-block counters outward from the anchor, examining one
/// block at a time until an answer is found or the counters are exhausted.
/// Enters and leaves with the mutex RELEASED; it re-takes it only for the O(1)
/// counter lookups and the block-cache publish.
fn resolveFromSortedCounters(doc: *Document, c: SortedNavCtx, anchor: u64, forward: bool) ?SortedNavOutcome {
    var positions: std.ArrayList(u64) = .empty;
    defer positions.deinit(doc.gpa);
    var columns: std.ArrayList(u32) = .empty;
    defer columns.deinit(doc.gpa);
    var probe = anchor;
    while (true) {
        doc.lock();
        const plan_opt = sort.navPlanLocked(doc, probe, forward);
        var pos_slice: []const u64 = &.{};
        var col_slice: []const u32 = &.{};
        var cached = false;
        if (plan_opt) |plan| {
            if (sort.navCachedBlock(doc, plan)) |hit| {
                pos_slice = hit.positions;
                col_slice = hit.columns;
                cached = true;
            }
        }
        // A cached block's slices belong to the build, so the answer is taken
        // from them while the mutex is still held.
        if (plan_opt) |plan| {
            if (cached) {
                const answer = pickInBlock(pos_slice, col_slice, plan, anchor, forward);
                doc.unlock();
                if (answer) |a| return a;
                if (!advanceProbe(&probe, plan, forward)) return .{ .found = false };
                continue;
            }
        }
        doc.unlock();
        const plan = plan_opt orelse return .{ .found = false }; // no non-empty block that way
        if (!scanSortedBlock(doc, c, plan, &positions, &columns)) return null;
        doc.lock();
        sort.navPublishBlock(doc, plan, positions.items, columns.items);
        doc.unlock();
        if (pickInBlock(positions.items, columns.items, plan, anchor, forward)) |a| return a;
        if (!advanceProbe(&probe, plan, forward)) return .{ .found = false };
    }
}

/// The answer inside one fully examined block, or null when the block holds no
/// match on the wanted side of the anchor.
fn pickInBlock(positions: []const u64, columns: []const u32, plan: sort.NavPlan, anchor: u64, forward: bool) ?SortedNavOutcome {
    if (forward) {
        for (positions, 0..) |p, i| {
            if (p < anchor) continue;
            return .{ .found = true, .pos = p, .col = if (i < columns.len) columns[i] else 0, .position = plan.before + i + 1 };
        }
        return null;
    }
    var i: usize = positions.len;
    while (i > 0) {
        i -= 1;
        if (positions[i] >= anchor) continue;
        return .{ .found = true, .pos = positions[i], .col = if (i < columns.len) columns[i] else 0, .position = plan.before + i + 1 };
    }
    return null;
}

/// Move the block probe past a block that held no answer. False == there is no
/// further block in that direction (EXHAUSTED).
fn advanceProbe(probe: *u64, plan: sort.NavPlan, forward: bool) bool {
    if (forward) {
        if (plan.hi <= plan.lo) return false;
        probe.* = plan.hi;
        return true;
    }
    if (plan.lo == 0) return false;
    probe.* = plan.lo;
    return true;
}

/// The worker's sorted-navigation step (src/index.zig `do_sort_nav`), entered
/// and left with the mutex HELD.
///
/// The expensive parts — the fallback counter build, and examining one
/// sorted-position block — run with the mutex RELEASED under the sort's
/// `sort_scan_busy` handshake, so polls, window reads and ls_close never queue
/// behind them and an ls_sort_clear / ls_sort_set still finds a consistent
/// point (it waits for the flag exactly as it does for a key-pass chunk, and
/// the interrupt flag keeps that wait short). The predicates are the WORKER's
/// snapshots, and every result is discarded unless the navigation, search,
/// filter and sort generations are all still the ones it was computed for.
pub fn resolveSortedNavOffMain(doc: *Document) void {
    if (doc.search_gen != doc.w_gen) {
        if (!refreshWorkerCtx(doc)) {
            failSearchLocked(doc);
            return;
        }
        doc.w_gen = doc.search_gen;
    }
    const filtered = doc.filter_state != .idle;
    if (filtered and doc.filter_gen != doc.wf_gen) {
        if (!filter.refreshFilterWorkerCtx(doc)) {
            failSearchLocked(doc);
            return;
        }
        doc.wf_gen = doc.filter_gen;
    }
    const c = sortedNavCtx(doc);
    const nav_gen = doc.nav_gen;
    const search_gen = doc.search_gen;
    const filter_gen = doc.filter_gen;
    const sort_gen = doc.sort_gen;
    const anchor = doc.nav_anchor;
    const forward = doc.nav_dir == .forward;
    const have_counters = sort.navHasCounters(doc);

    doc.sort_scan_busy = true;
    doc.unlock();
    var outcome: ?SortedNavOutcome = null;
    const built = if (have_counters) true else buildSortedCounters(doc, c);
    if (built) outcome = resolveFromSortedCounters(doc, c, anchor, forward);
    doc.lock();
    doc.sort_scan_busy = false;
    doc.wakeWorker();

    if (doc.nav_gen != nav_gen or doc.search_gen != search_gen or
        doc.filter_gen != filter_gen or doc.sort_gen != sort_gen or !doc.nav_pending)
    {
        return; // superseded (or cancelled) while we worked
    }
    const res = outcome orelse {
        // An allocation failure or an interrupt. Report NONE rather than leave
        // the caller polling a navigation that will never resolve; a cancel
        // path has already cleared the slot, and the generation check above
        // means this only fires for the still-current request.
        doc.search_nav = .none;
        doc.nav_pending = false;
        return;
    };
    if (!res.found) {
        setExhausted(doc);
        return;
    }
    doc.search_found_row = res.pos;
    doc.search_found_col = res.col;
    doc.search_position = res.position;
    doc.search_nav = .found;
    doc.nav_pending = false;
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
            if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or
                b >= doc.block_counts.items.len or b >= doc.checkpoints.items.len)
            {
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
    // Both lists are indexed by block below, so the cursor must fit BOTH.
    const blocks = @min(doc.block_counts.items.len, doc.checkpoints.items.len);
    if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or blocks == 0) {
        doc.unlock();
        return null;
    }
    var b: u64 = (bound - 1) / checkpoint_interval;
    if (b >= blocks) b = blocks - 1;
    doc.unlock();
    while (true) {
        doc.lock();
        if (!navJobCurrentLocked(doc, nav_gen, search_gen, filter_gen) or
            b >= doc.block_counts.items.len or b >= doc.checkpoints.items.len)
        {
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
    // Case folding is driven SOLELY by the request flag: insensitive
    // (case_sensitive == false) folds ASCII case for the TEXT substring and
    // predicate EQ/NE; ordering predicates ignore it.
    const fold = !req.case_sensitive;
    if (kind_i == 0) { // TEXT
        if (value.len == 0) return false; // empty query means "no search"
        if (req.scope_ptr) |sp| {
            if (req.scope_len == 0) return false; // non-NULL empty scope
            var i: usize = 0;
            while (i < req.scope_len) : (i += 1) if (sp[i] >= d.column_count) return false;
        }
    } else { // PREDICATE
        if (req.column >= d.column_count) return false;
        const op_i = @intFromEnum(req.op);
        if (op_i < 0 or op_i > 5) return false;
        if (op_i >= 2 and !matcher.parseDecimal(value).valid) return false; // ordering value must parse
    }

    // Derive the query up front so an OOM rejects cleanly (no state change).
    var query = matcher.Query.init(d.gpa, value, fold, req.kind) catch return false;
    var mask: []bool = &.{};
    if (kind_i == 0 and req.scope_ptr != null) {
        mask = d.gpa.alloc(bool, d.column_count) catch {
            query.deinit(d.gpa);
            return false;
        };
        @memset(mask, false);
        const sp = req.scope_ptr.?;
        var i: usize = 0;
        while (i < req.scope_len) : (i += 1) mask[sp[i]] = true;
    }

    d.lock();
    const target: MatchCtx = .{ .kind = req.kind, .op = req.op, .column = req.column, .q = &query, .scope_mask = mask, .column_count = d.column_count };
    const reuse = d.search_state != .idle and base.sourceFaultCount(d) == 0 and
        @import("match_cache.zig").resumable(d.search_rows, d.search_total_exact, d.block_counts.items.len) and
        @import("match_cache.zig").same(docCtx(d), target);
    if (reuse) {
        // The request AND view are unchanged (view changes reset search to
        // IDLE). Keep the current cursor, worker snapshot and sorted tally.
        // A chunk still in flight belongs to this same scan and may commit.
        query.deinit(d.gpa);
        if (mask.len > 0) d.gpa.free(mask);
    } else {
        d.match_cache.remember(d, target, false);
        if (d.scope_mask.len > 0) d.gpa.free(d.scope_mask);
        d.search_query.deinit(d.gpa);
        d.search_query = query;
        d.scope_mask = mask;
        d.search_kind = req.kind;
        d.search_op = req.op;
        d.search_column = req.column;
        d.search_gen +%= 1;
        d.block_counts.clearRetainingCapacity();
        d.search_oversized_matches.clearRetainingCapacity();
        d.search_total = 0;
        d.search_total_exact = false;
        d.search_rows = 0;
        d.search_pos = d.data_start;
        d.search_progress = 0.0;
        sort.navResetLocked(d, d.search_gen);
        _ = d.match_cache.restore(d, docCtx(d), false);
    }

    // Take the scan slot: cancel a scanning jump (DONE persists; gains kept).
    if (d.jump_state == .scanning) {
        d.jump_state = .idle;
        d.jump_progress = 0.0;
    }

    // Every submission resets navigation, including a cached result. A
    // pending off-main navigation must not publish its previous landing.
    d.nav_gen +%= 1;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;
    d.search_nav = .none;
    d.nav_pending = false;
    d.search_to_eof = true;
    if (d.search_total_exact) {
        d.search_state = .done;
        d.unlock();
        return true;
    }

    if (d.reader.atEnd(d.source, d.data_start) or d.column_count == 0) {
        // Nothing to scan: already DONE with total 0.
        d.search_state = .done;
        d.search_total_exact = true;
        d.search_progress = 1.0;
        d.unlock();
        return true;
    }
    // A NETWORK search launches NO to-EOF match-scan. It parks immediately
    // (CANCELLED, retained prefix only, to_eof false); each ls_search_nav then
    // resumes it only as far as the next match via the existing
    // CANCELLED-resume machinery, so the full match total M is never computed
    // over the wire (total = the scanned-prefix count; total_exact only if a
    // nav genuinely reaches EOF). LOCAL is unchanged.
    if (d.net) {
        d.search_state = .cancelled;
        d.search_to_eof = false;
        d.unlock();
        return true;
    }
    d.search_state = .scanning;
    // A find that must SCAN takes the single slot from a building key pass:
    // the sort goes LS_SORT_PARKED with its request kept and its converging
    // prefix frozen at what it had reached (api/lesssheet.h SORTED VIEWS §8).
    sort.parkForSlot(d);
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
        const res = searchScanChunk(d, d.search_pos, d.search_rows, filtered, d.sort_nav_tally, generation);
        commitSearch(d, res, filtered);
        resolveNavLocked(d);
        // Without this the stalled chunk makes no progress and the loop never
        // exits (an unbounded hang holding the lock).
        if (res.stalled) finishStalledLocked(d);
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
        // Under a sort the navigation needs FULL coverage (a match at any
        // sorted position can come from anywhere), so a resume there runs to
        // EOF rather than stopping at the next match.
        d.search_to_eof = sort.presented(d);
    }
    if (d.search_state == .scanning) {
        if (d.jump_state == .scanning) { // re-take the slot from a scanning jump
            d.jump_state = .idle;
            d.jump_progress = 0.0;
        }
        sort.parkForSlot(d); // see startSearch: the same slot rule

        if (d.worker != null) {
            d.wakeWorker();
        } else if (d.net) {
            // A NETWORK document must NOT run the degraded synchronous loop
            // below. It calls searchScanChunk WHILE HOLDING THE DOCUMENT MUTEX,
            // and that scan is *supposed* to touch absent bytes (it fetches to
            // advance the frontier), so no commit-side guard can help: with
            // `search_to_eof` false it still runs until the nav resolves, i.e.
            // potentially to EOF, fetching over the wire with the mutex held —
            // every poll, cancel and close blocked behind it, and "No full
            // download, ever" broken. This arm is reachable whenever
            // `base.Document.startWorker`'s `netIo().concurrent(...)` failed at
            // open. Park exactly as `startSearch` and the filter's own net-park
            // already do, for the same reason: the nav resolves to NONE and the
            // search freezes at its last consistent state, which is a clean
            // answer rather than a wedged document. LOCAL is byte-identical
            // (d.net == false).
            failSearchLocked(d);
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
                const res = searchScanChunk(d, d.search_pos, d.search_rows, filtered, d.sort_nav_tally, generation);
                commitSearch(d, res, filtered);
                resolveNavLocked(d);
                if (d.search_state == .scanning and !d.search_to_eof and !d.nav_pending) d.search_state = .cancelled;
                // As the startSearch degraded loop: a stalled chunk would
                // otherwise never exit this loop.
                if (res.stalled) finishStalledLocked(d);
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
