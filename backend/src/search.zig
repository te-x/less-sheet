//! Search (find-seek slice) — the streaming match-scan with O(checkpoints)
//! per-block counts, navigation over the counted region, and the shared
//! scan-slot state machine (jump / search / filter priority is arbitrated by
//! the worker in src/index.zig). See api/lesssheet.h SEARCH for the pinned
//! model; api/lesssheet.h FILTERED VIEWS FIND for how a concurrent filter
//! composes into the same scan.

const api = @import("api");
const base = @import("base.zig");
const lexer = @import("lexer.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");
const filter = @import("filter.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const MatchCtx = base.MatchCtx;
const Match = nav.Match;
const checkpoint_interval = base.checkpoint_interval;
const searchProgress = base.searchProgress;

// ---------------------------------------------------------------------------
// The streaming match-scan (worker; lock-free chunk, mutex-batched commit).
// ---------------------------------------------------------------------------

const SearchChunk = struct {
    end_offset: u64,
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
    doc.w_ctx = .{
        .kind = doc.search_kind,
        .op = doc.search_op,
        .column = doc.search_column,
        .fold = doc.search_fold,
        .value = doc.w_value.items,
        .value_dec = matcher.parseDecimal(doc.w_value.items),
        .scope_mask = doc.w_mask.items,
        .column_count = doc.column_count,
    };
    return true;
}

/// Lex + match one block of data rows (up to the next checkpoint boundary, EOF,
/// or a stop request) from `start_off`/`start_row`, counting matches. Reads only
/// immutable mmap bytes + the worker snapshot; reuses the scan scratch per row.
/// `filtered` composes `doc.wf_ctx` (the worker's lock-free filter snapshot,
/// refreshed alongside `doc.w_ctx` — see filter.refreshFilterWorkerCtx) with
/// the find predicate: a row counts toward `matches` only if it ALSO
/// satisfies the filter (see api/lesssheet.h FILTERED VIEWS FIND);
/// `filter_matches` tallies the filter alone, letting the caller re-drive the
/// filter's own counted region as a side effect (maybeAdvanceFilterFromSearch).
pub fn searchScanChunk(doc: *Document, start_off: u64, start_row: u64, filtered: bool) SearchChunk {
    const content = doc.content;
    var i: usize = @intCast(start_off);
    var row = start_row;
    var matches: u64 = 0;
    var filter_matches: u64 = 0;
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    base.beginOversizedChunk(doc);
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
        if (i >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
        doc.search_scratch.clearRetainingCapacity();
        doc.search_refs.clearRetainingCapacity();
        // SEARCH matches the FULL cell, not the display-capped bytes (cap =
        // null; see requirement 10 / api/lesssheet.h SEARCH). Never bounded by
        // the WINDOW's per-row scan cap either -- ARCH-huge-row-budget only
        // byte-bounds ls_window_set, never find/filter.
        const res = lexer.lexInto(content, i, doc.sep, doc.quote, doc.column_count, null, content.len, doc.encoding, &doc.search_scratch, &doc.search_refs, doc.gpa) catch {
            // Decode allocation failure: count no match and advance the boundary.
            const nb = lexer.recordBounds(content, i, doc.sep, doc.quote, content.len, doc.encoding);
            base.stageOversized(doc, row, @intCast(i), @intCast(nb.next));
            i = nb.next;
            row += 1;
            if (nb.next >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
            continue;
        };
        var filt_ok = true;
        if (filtered) {
            filt_ok = matcher.matchRecord(doc.wf_ctx, doc.search_scratch.items, doc.search_refs.items) != null;
            if (filt_ok) filter_matches += 1;
        }
        if (filt_ok and matcher.matchRecord(doc.w_ctx, doc.search_scratch.items, doc.search_refs.items) != null) matches += 1;
        // This scan also feeds the base row index (ARCH-huge-row-budget): stage
        // a post-row checkpoint if this row's source extent exceeds the
        // WINDOW's per-row scan cap, so a later ls_window_set reaching a row
        // this search's own frontier advance passed can skip it.
        base.stageOversized(doc, row, @intCast(i), @intCast(res.next));
        i = res.next;
        row += 1;
        if (res.next >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null, .matches = matches, .filter_matches = filter_matches };
    }
    return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .offset = i }, .matches = matches, .filter_matches = filter_matches };
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
    const advancing = res.end_offset > doc.frontier_offset;
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
    doc.search_offset = res.end_offset;
    doc.search_total +%= res.matches;
    if (advancing) {
        doc.frontier_offset = res.end_offset;
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
        doc.search_progress = searchProgress(doc, res.end_offset);
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
    doc.filter_offset = res.end_offset;
    doc.filter_total +%= res.filter_matches;
    if (res.eof) {
        doc.filter_total_exact = true;
        doc.filter_progress = 1.0;
        if (doc.filter_state == .cancelled) doc.filter_state = .done;
    } else {
        doc.filter_progress = searchProgress(doc, res.end_offset);
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
    var mask: []bool = &.{};
    if (kind_i == 0 and req.scope_ptr != null) {
        mask = d.gpa.alloc(bool, d.column_count) catch {
            d.gpa.free(value_copy);
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
    d.search_value = value_copy;
    d.scope_mask = mask;
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
    d.search_offset = d.data_start;
    d.search_progress = 0.0;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;
    d.search_nav = .none;
    d.nav_pending = false;
    d.search_to_eof = true;

    if (d.data_start >= d.content_len or d.column_count == 0) {
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
    while (d.search_state == .scanning) {
        const res = searchScanChunk(d, d.search_offset, d.search_rows, filtered);
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
    if (d.search_state == .idle) return; // no active search: no-op
    const dir_i = @intFromEnum(dir);
    if (dir_i != 0 and dir_i != 1) return; // out-of-domain direction: no-op

    // Replace any pending navigation; clear the previous found result.
    d.nav_pending = true;
    d.nav_anchor = anchor_row;
    d.nav_dir = dir;
    d.search_nav = .searching;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;

    // Instant fast path: answer from the counted region when already determined.
    resolveNavLocked(d);
    if (!d.nav_pending) return;

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
            while (d.nav_pending and d.search_state == .scanning) {
                const res = searchScanChunk(d, d.search_offset, d.search_rows, filtered);
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
