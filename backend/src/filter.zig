//! Filtered views (filtered-views slice) — see api/lesssheet.h FILTERED VIEWS
//! for the full model. A FILTER is a persistent VIEW MODE (not a transient
//! job): it mirrors the search job's per-block counting machinery with its
//! OWN predicate, cursor, and counters — never a materialized match-row
//! list. `ls_filter_set` validates EXACTLY like `ls_search_start`
//! (duplicated rather than shared, so neither call site risks drifting the
//! other's already-frozen-green behavior — see src/search.zig). Parsing
//! goes through `Document.reader` (see docs/architecture/ARCH-reader-
//! interface.md) — this module never imports `lexer.zig`.

const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const MatchCtx = base.MatchCtx;
const Pos = base.Pos;
const checkpoint_interval = base.checkpoint_interval;
const searchProgress = base.searchProgress;

/// The active filter's matcher (caller holds the mutex; see search.docCtx).
/// Only meaningful when `doc.filter_state != .idle`.
pub fn filterCtx(doc: *Document) MatchCtx {
    return .{
        .kind = doc.filter_kind,
        .op = doc.filter_op,
        .column = doc.filter_column,
        .fold = doc.filter_fold,
        .value = doc.filter_value,
        .value_dec = doc.filter_value_dec,
        .scope_mask = doc.filter_scope_mask,
        .column_count = doc.column_count,
        .failure = doc.filter_failure,
    };
}

/// The filter_ctx argument for the generalized nav/count helpers (src/
/// nav.zig): the active filter while one is set (find-under-a-filter
/// composes both predicates), else null (plain find). Caller holds the mutex.
pub fn activeFilterCtxOrNull(doc: *Document) ?MatchCtx {
    return if (doc.filter_state != .idle) filterCtx(doc) else null;
}

/// Snapshot the active FILTER request into worker-owned buffers (caller holds
/// the mutex) — mirrors search.refreshWorkerCtx for `doc.wf_ctx`, the
/// lock-free filter predicate both the filter-scan and a concurrent
/// (filtered) search chunk compose against.
pub fn refreshFilterWorkerCtx(doc: *Document) bool {
    doc.wf_value.clearRetainingCapacity();
    doc.wf_value.appendSlice(doc.gpa, doc.filter_value) catch return false;
    doc.wf_mask.clearRetainingCapacity();
    doc.wf_mask.appendSlice(doc.gpa, doc.filter_scope_mask) catch return false;
    doc.wf_failure.clearRetainingCapacity();
    doc.wf_failure.appendSlice(doc.gpa, doc.filter_failure) catch return false;
    doc.wf_ctx = .{
        .kind = doc.filter_kind,
        .op = doc.filter_op,
        .column = doc.filter_column,
        .fold = doc.filter_fold,
        .value = doc.wf_value.items,
        .value_dec = matcher.parseDecimal(doc.wf_value.items),
        .scope_mask = doc.wf_mask.items,
        .column_count = doc.column_count,
        .failure = doc.wf_failure.items,
    };
    return true;
}

// ---------------------------------------------------------------------------
// The filter-scan itself (worker; lock-free chunk, mutex-batched commit) —
// mirrors the search match-scan (src/search.zig) but tests ONLY the filter
// predicate. Drives BOTH the standalone filter-scan job (do_filter) and a
// filtered jump's own scan (jump-under-filter reuses this exact machinery —
// see api/lesssheet.h FILTERED VIEWS JUMP).
// ---------------------------------------------------------------------------

const FilterChunk = struct {
    end_pos: Pos,
    end_row: u64,
    eof: bool,
    /// security-hardening (e) AC-e3: see search.SearchChunk.stalled — the next
    /// bytes are not present, so the chunk ended without counting anything and
    /// the caller must stop driving rather than spin on a zero-progress cursor.
    stalled: bool = false,
    checkpoint: ?Checkpoint,
    matches: u64,
};

/// ARCH-huge-row-filtered: stage row `row`'s FULL-cell filter-match decision
/// (`matched`) IFF its extent [start, end) exceeded the per-row window scan
/// cap -- mirrors base.stageOversized's size test, but records the match
/// decision itself (never scan-relevant positions) so the FILTERED window
/// path can honor it later without re-scanning (see base.OversizedMatch /
/// window.windowSetFiltered / nav.nthMatchInBlock). Lock-free: exclusive to
/// the ONE filter-scan chunk currently executing (same guarantee as
/// `oversized_stage` — see filterScanChunk's caller-serialization note on
/// Document). `bytesConsumed` is the size test's only look at a position's
/// byte meaning (see reader.zig's module doc).
fn stageOversizedMatch(doc: *Document, row: u64, start: Pos, end: Pos, matched: bool) void {
    const size = doc.reader.bytesConsumed(doc.source, end) - doc.reader.bytesConsumed(doc.source, start);
    if (size <= api.window_row_scan_max_bytes) return;
    doc.filter_oversized_stage.append(doc.gpa, .{ .row = row, .matched = matched }) catch {};
}

/// Fold this filter-scan chunk's staged oversized-row match records (see
/// stageOversizedMatch) into the persistent `filter_oversized_matches` list —
/// UNCONDITIONALLY, unlike base.drainOversized's `advancing`-gated drain of
/// the SHARED `oversized_checkpoints`: filterScanChunk always starts exactly
/// where the filter's OWN cursor (filter_rows) left off, so it can never
/// re-stage an already-recorded row, regardless of whether this chunk was
/// also the one advancing the shared frontier. Caller holds the document
/// mutex. Best-effort: an OOM here only costs a future re-scan of the
/// affected row, never correctness.
fn drainOversizedMatches(doc: *Document) void {
    if (doc.filter_oversized_stage.items.len > 0) {
        doc.filter_oversized_matches.appendSlice(doc.gpa, doc.filter_oversized_stage.items) catch {};
    }
}

/// Lex + test the filter predicate for one block of data rows. Reads only via
/// the Reader (immutable mmap bytes, for CSV) + the worker's lock-free filter
/// snapshot (doc.wf_ctx, refreshed by refreshFilterWorkerCtx). Matches the
/// FULL cell (cap = null), same rule as SEARCH.
pub fn filterScanChunk(doc: *Document, start_pos: Pos, start_row: u64, generation: u64) FilterChunk {
    var pos = start_pos;
    var row = start_row;
    var matches: u64 = 0;
    const reader_mod = @import("reader.zig");
    const scan = doc.beginMatchScan(.filter, generation, start_pos);
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    base.beginOversizedChunk(doc);
    doc.filter_oversized_stage.clearRetainingCapacity(); // ARCH-huge-row-filtered
    // FRONTIER COMMIT GUARD (source.Source.commitBound) -- see the hoist and the
    // withhold in search.searchScanChunk; identical rule, identical reasons.
    const guarded = doc.source.commitGuarded();
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) {
            doc.endMatchScanIf(.filter, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = null, .matches = matches };
        }
        if (doc.reader.atEnd(doc.source, pos)) {
            doc.endMatchScanIf(.filter, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null, .matches = matches };
        }
        const res = if (scan) |cur|
            reader_mod.readerMatchRowAtScanCursor(doc.reader, cur, doc.wf_ctx, null)
        else
            reader_mod.readerMatchRow(doc.reader, doc.source, pos, doc.wf_ctx, null, .{});
        // security-hardening (e) AC-e3: see search.searchScanChunk — a row that
        // consumed no bytes is an un-fetched tail, never a row.
        if (base.scanStalled(doc, pos, res.next)) {
            doc.endMatchScanIf(.filter, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = false, .stalled = true, .checkpoint = null, .matches = matches };
        }
        // FRONTIER COMMIT GUARD: see search.searchScanChunk's withhold. The filtered
        // JUMP is the LIVE network filter driver (`do_filter` is net-gated), so this
        // is the arm a network filtered view actually reaches.
        if (guarded) {
            const row_end = doc.reader.logicalBytes(doc.source, res.next);
            if (row_end > doc.source.commitBound(row_end)) {
                doc.endMatchScanIf(.filter, generation);
                return .{ .end_pos = pos, .end_row = row, .eof = false, .stalled = true, .checkpoint = null, .matches = matches };
            }
        }
        const matched = res.matched_col != null;
        if (matched) matches += 1;
        // This scan also feeds the base row index (ARCH-huge-row-budget): see
        // the matching comment in search.searchScanChunk.
        base.stageOversized(doc, row, pos, res.next);
        stageOversizedMatch(doc, row, pos, res.next, matched);
        pos = res.next;
        row += 1;
        if (doc.source == .gzip) doc.gz_match_resident_bytes = @max(doc.gz_match_resident_bytes, @sizeOf(matcher.StreamCell));
        if (doc.reader.atEnd(doc.source, pos)) {
            doc.endMatchScanIf(.filter, generation);
            return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null, .matches = matches };
        }
    }
    return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .pos = pos }, .matches = matches };
}

/// security-hardening (e) AC-e3: terminate a filter-scan whose chunk STALLED on
/// un-fetched bytes (`FilterChunk.stalled`) — the mirror of
/// search.finishStalledLocked. Counts stay exact for the rows that ARE present;
/// the view is NEVER marked complete/exact over an un-fetched tail. Idempotent.
pub fn finishStalledLocked(d: *Document) void {
    if (d.filter_state == .scanning) failFilterLocked(d);
}

/// Terminate the active filter-scan cleanly at its last consistent state
/// (caller holds the mutex): mirrors search.failSearchLocked. The filter MODE
/// persists (CANCELLED, not idle) — only an OOM-degraded fail-safe.
pub fn failFilterLocked(doc: *Document) void {
    doc.filter_state = .cancelled;
}

/// Fold a completed filter-scan chunk into the filter's counted region
/// (caller holds the mutex): mirrors search.commitSearch, advancing the
/// shared frontier where the scan broke new ground beyond it (paid once —
/// fv9). Does NOT itself decide SCANNING vs CANCELLED (the caller — the
/// plain filter job or a filtered jump — owns that per the shared-slot
/// rules); only EOF unconditionally resolves to LS_FILTER_DONE (the total is
/// final however it got there).
pub fn commitFilter(doc: *Document, res: FilterChunk) void {
    const advancing = doc.reader.bytesConsumed(doc.source, res.end_pos) > doc.reader.bytesConsumed(doc.source, doc.frontier_pos);
    const need_cp = advancing and res.checkpoint != null;
    doc.filter_block_counts.ensureUnusedCapacity(doc.gpa, 1) catch {
        failFilterLocked(doc);
        return;
    };
    if (need_cp) doc.checkpoints.ensureUnusedCapacity(doc.gpa, 1) catch {
        failFilterLocked(doc);
        return;
    };
    doc.filter_block_counts.appendAssumeCapacity(res.matches);
    doc.filter_rows = res.end_row;
    doc.filter_pos = res.end_pos;
    doc.filter_total +%= res.matches;
    if (advancing) {
        doc.frontier_pos = res.end_pos;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.appendAssumeCapacity(cp);
    }
    // ARCH-huge-row-budget: see the matching comment in search.commitSearch.
    base.drainOversized(doc, advancing);
    // ARCH-huge-row-filtered: drain this chunk's staged oversized-row filter-
    // match records UNCONDITIONALLY (never gated on `advancing`, unlike the
    // shared oversized_checkpoints above) — see drainOversizedMatches.
    drainOversizedMatches(doc);
    if (res.eof) {
        doc.complete = true;
        doc.total_rows = doc.filter_rows;
        doc.filter_state = .done;
        doc.filter_total_exact = true;
        doc.filter_progress = 1.0;
    } else {
        doc.filter_progress = searchProgress(doc, res.end_pos);
    }
}

/// Resolve a pending FILTERED jump from the filter's counted region if
/// determined, mirroring index.updateJump's role for the plain (unfiltered)
/// jump. `jump_target` is an ORIGINAL row number; once resolved, `jump_landed`
/// is the FILTERED index of the first matching row with original index >=
/// target (clamped to the last match once the filter-scan is exact; 0 when
/// the filtered view has no rows). Caller holds the mutex; called only while
/// doc.jump_state == .scanning and a filter is active — see api/lesssheet.h
/// FILTERED VIEWS JUMP.
pub fn resolveFilterJumpLocked(doc: *Document) void {
    const target = doc.jump_target;
    const counted = doc.filter_rows;
    const fctx = filterCtx(doc);
    if (target < counted) {
        if (nav.findForwardMatch(doc, doc.filter_block_counts.items, null, fctx, target, counted)) |m| {
            doc.jump_state = .done;
            doc.jump_landed = nav.positionOf(doc, doc.filter_block_counts.items, null, fctx, m.row) - 1;
            doc.jump_progress = 1.0;
            return;
        }
    }
    if (doc.filter_total_exact) {
        // EOF: no match at/after target anywhere -> clamp to the last match
        // (0 for an empty filtered view).
        doc.jump_state = .done;
        doc.jump_landed = if (doc.filter_total > 0) doc.filter_total - 1 else 0;
        doc.jump_progress = 1.0;
        return;
    }
    if (target > doc.jump_start_rows) {
        const span = target - doc.jump_start_rows;
        const p = @as(f64, @floatFromInt(counted - doc.jump_start_rows)) / @as(f64, @floatFromInt(span));
        if (p > doc.jump_progress) doc.jump_progress = p;
    }
}

/// `ls_jump_start` while a filter is active: `target_row` is an ORIGINAL
/// data-row number; the jump lands on the FILTERED index of the first
/// matching row with original index >= target (clamped to the last match at/
/// after EOF; 0 when the filtered view has no rows) — see api/lesssheet.h
/// FILTERED VIEWS JUMP. Caller holds the mutex.
pub fn jumpStartFiltered(d: *Document, target_row: u64) void {
    const fctx = filterCtx(d);
    // Instant path 1: already answerable from the filter's counted region.
    if (target_row < d.filter_rows) {
        if (nav.findForwardMatch(d, d.filter_block_counts.items, null, fctx, target_row, d.filter_rows)) |m| {
            d.jump_state = .done;
            d.jump_landed = nav.positionOf(d, d.filter_block_counts.items, null, fctx, m.row) - 1;
            d.jump_progress = 1.0;
            return;
        }
    }
    // Instant path 2: the filter is exact and there is no match at/after
    // target anywhere -> clamp to the last match (0 for an empty view).
    if (d.filter_total_exact) {
        d.jump_state = .done;
        d.jump_landed = if (d.filter_total > 0) d.filter_total - 1 else 0;
        d.jump_progress = 1.0;
        return;
    }
    if (d.worker == null) {
        // Degraded mode: no scan can advance the filter-scan either.
        d.jump_state = .done;
        d.jump_landed = if (d.filter_total > 0) d.filter_total - 1 else 0;
        d.jump_progress = 1.0;
        return;
    }
    // Must scan: take the slot (cancel a scanning search; a scanning
    // filter-scan goes CANCELLED — its mode persists, now driven by this jump).
    if (d.search_state == .scanning) {
        d.search_state = .cancelled;
        if (d.search_nav == .searching) {
            d.search_nav = .none;
            d.nav_pending = false;
        }
    }
    if (d.filter_state == .scanning) d.filter_state = .cancelled;
    d.jump_state = .scanning;
    d.jump_target = target_row;
    d.jump_start_rows = d.filter_rows;
    d.jump_progress = 0.0;
    d.wakeWorker();
}

// ---------------------------------------------------------------------------
// Filter C-ABI logic (see api/lesssheet.h ls_filter_set/clear/poll). The
// `pub export fn` wrappers stay in root.zig; these are their bodies.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_filter_set`.
pub fn setFilter(d: *Document, request: *const api.SearchRequest) bool {
    const req = request.*;

    // Validate first — a rejected request changes NOTHING (same rules as
    // ls_search_start; see api/lesssheet.h ls_search_request).
    const kind_i = @intFromEnum(req.kind);
    if (kind_i != 0 and kind_i != 1) return false;
    if (req.value_ptr == null and req.value_len != 0) return false;
    const value: []const u8 = if (req.value_ptr) |vp| vp[0..req.value_len] else &[_]u8{};
    // Case folding is driven SOLELY by the request flag (smart-case retired):
    // insensitive (case_sensitive == false) folds ASCII case for the TEXT
    // substring and predicate EQ/NE; ordering predicates ignore it.
    const fold = !req.case_sensitive;
    if (kind_i == 0) { // TEXT
        if (value.len == 0) return false; // empty query means "no filter"
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
    // Replace any previous filter ENTIRELY.
    if (d.filter_value.len > 0) d.gpa.free(d.filter_value);
    if (d.filter_scope_mask.len > 0) d.gpa.free(d.filter_scope_mask);
    if (d.filter_failure.len > 0) d.gpa.free(d.filter_failure);
    d.filter_value = value_copy;
    d.filter_scope_mask = mask;
    d.filter_failure = failure;
    d.filter_kind = req.kind;
    d.filter_op = req.op;
    d.filter_column = req.column;
    d.filter_fold = fold;
    d.filter_value_dec = if (kind_i == 1 and @intFromEnum(req.op) >= 2) matcher.parseDecimal(value_copy) else .{};
    d.filter_gen +%= 1;

    // Takes the scan slot: a scanning jump is cancelled (LS_JUMP_IDLE, gains
    // kept); RESETS any active search to IDLE (the coordinate space changed).
    // Setting a filter ALSO forces the jump slot to IDLE even if it was DONE
    // (a completed jump's landing does not persist across a coordinate
    // change) — see api/lesssheet.h FILTERED VIEWS RESET.
    d.jump_state = .idle;
    d.jump_progress = 0.0;
    d.jump_landed = 0;
    d.search_state = .idle;
    d.search_nav = .none;
    d.search_progress = 0.0;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;
    d.search_total = 0;
    d.search_total_exact = false;
    d.nav_pending = false;

    // Reset the counted region / counters; the filter-scan restarts from row 0.
    d.filter_block_counts.clearRetainingCapacity();
    d.filter_oversized_matches.clearRetainingCapacity(); // ARCH-huge-row-filtered
    d.filter_total = 0;
    d.filter_total_exact = false;
    d.filter_rows = 0;
    d.filter_pos = d.data_start;
    d.filter_progress = 0.0;

    if (d.reader.atEnd(d.source, d.data_start) or d.column_count == 0) {
        // Nothing to scan: already DONE with total 0.
        d.filter_state = .done;
        d.filter_total_exact = true;
        d.filter_progress = 1.0;
        d.unlock();
        return true;
    }
    // never-full-download-streaming (TD1/TD7): a NETWORK filtered view launches
    // NO to-EOF filter scan. It parks immediately (CANCELLED — the filter MODE is
    // active and the view IS filtered; counts firm only as the user navigates),
    // mirroring the startSearch net-park. The frontier then advances only on a
    // filtered demand (a filtered ls_jump_start / scroll, which drives
    // filterScanChunk via the worker's do_jump path and re-parks), never as a
    // background drive over the wire. This guard sits BEFORE the `.scanning`
    // assignment so it also bypasses the degraded (worker == null) synchronous
    // to-completion loop below — which for a net doc would otherwise fetch and
    // scan the whole resource ("No full download, ever"). LOCAL is byte-identical
    // (doc.net == false; AC21).
    if (d.net) {
        d.filter_state = .cancelled;
        d.unlock();
        return true;
    }
    d.filter_state = .scanning;
    if (d.worker != null) {
        d.wakeWorker();
        d.unlock();
        return true;
    }
    // Degraded (no worker): scan to completion synchronously, mirroring
    // ls_search_start's degraded fallback — the caller is blocked here so no
    // other thread observes intermediate state.
    if (refreshFilterWorkerCtx(d)) d.wf_gen = d.filter_gen else failFilterLocked(d);
    const generation = d.filter_gen;
    while (d.filter_state == .scanning) {
        const res = filterScanChunk(d, d.filter_pos, d.filter_rows, generation);
        commitFilter(d, res);
        // security-hardening (e) AC-e3: a stalled chunk makes no progress, so
        // without this the loop never exits.
        if (res.stalled) finishStalledLocked(d);
    }
    d.unlock();
    return true;
}

/// See api/lesssheet.h `ls_filter_clear`. ZERO allocation.
pub fn clearFilter(d: *Document) void {
    d.lock();
    defer d.unlock();
    if (d.filter_state == .idle) return; // no-op

    d.filter_state = .idle;
    d.filter_progress = 0.0;
    d.filter_total = 0;
    d.filter_total_exact = false;
    d.filter_rows = 0;
    d.filter_pos = d.reader.start(d.source);
    d.filter_gen +%= 1; // discard any in-flight filter/jump-driven chunk

    // RESETS any active search to IDLE and returns the jump slot to IDLE
    // (frontier gains — the base index — are KEPT; see FILTERED VIEWS RESET).
    d.jump_state = .idle;
    d.jump_progress = 0.0;
    d.jump_landed = 0;
    d.search_state = .idle;
    d.search_nav = .none;
    d.search_progress = 0.0;
    d.search_found_row = 0;
    d.search_found_col = 0;
    d.search_position = 0;
    d.search_total = 0;
    d.search_total_exact = false;
    d.nav_pending = false;
}

/// See api/lesssheet.h `ls_filter_poll`. ZERO allocation; never fails.
pub fn pollFilter(d: *Document) api.FilterStatus {
    d.lock();
    defer d.unlock();
    return .{
        .state = d.filter_state,
        .progress = d.filter_progress,
        .total = d.filter_total,
        .total_exact = d.filter_total_exact,
    };
}
