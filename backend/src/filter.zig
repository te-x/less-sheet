//! Filtered views (filtered-views slice) — see api/lesssheet.h FILTERED VIEWS
//! for the full model. A FILTER is a persistent VIEW MODE (not a transient
//! job): it mirrors the search job's per-block counting machinery with its
//! OWN predicate, cursor, and counters — never a materialized match-row
//! list. `ls_filter_set` validates EXACTLY like `ls_search_start`
//! (duplicated rather than shared, so neither call site risks drifting the
//! other's already-frozen-green behavior — see src/search.zig).

const api = @import("api");
const base = @import("base.zig");
const lexer = @import("lexer.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const MatchCtx = base.MatchCtx;
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
    doc.wf_ctx = .{
        .kind = doc.filter_kind,
        .op = doc.filter_op,
        .column = doc.filter_column,
        .fold = doc.filter_fold,
        .value = doc.wf_value.items,
        .value_dec = matcher.parseDecimal(doc.wf_value.items),
        .scope_mask = doc.wf_mask.items,
        .column_count = doc.column_count,
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
    end_offset: u64,
    end_row: u64,
    eof: bool,
    checkpoint: ?Checkpoint,
    matches: u64,
};

/// Lex + test the filter predicate for one block of data rows. Reads only
/// immutable mmap bytes + the worker's lock-free filter snapshot (doc.wf_ctx,
/// refreshed by refreshFilterWorkerCtx). Matches the FULL cell (cap = null),
/// same rule as SEARCH.
pub fn filterScanChunk(doc: *Document, start_off: u64, start_row: u64) FilterChunk {
    const content = doc.content;
    var i: usize = @intCast(start_off);
    var row = start_row;
    var matches: u64 = 0;
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = null, .matches = matches };
        if (i >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null, .matches = matches };
        doc.filter_scratch.clearRetainingCapacity();
        doc.filter_refs.clearRetainingCapacity();
        const res = lexer.lexInto(content, i, doc.sep, doc.quote, doc.column_count, null, content.len, doc.encoding, &doc.filter_scratch, &doc.filter_refs, doc.gpa) catch {
            const nb = lexer.recordBounds(content, i, doc.sep, doc.quote, content.len, doc.encoding);
            i = nb.next;
            row += 1;
            if (nb.next >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null, .matches = matches };
            continue;
        };
        if (matcher.matchRecord(doc.wf_ctx, doc.filter_scratch.items, doc.filter_refs.items) != null) matches += 1;
        i = res.next;
        row += 1;
        if (res.next >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null, .matches = matches };
    }
    return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .offset = i }, .matches = matches };
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
    const advancing = res.end_offset > doc.frontier_offset;
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
    doc.filter_offset = res.end_offset;
    doc.filter_total +%= res.matches;
    if (advancing) {
        doc.frontier_offset = res.end_offset;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.appendAssumeCapacity(cp);
    }
    if (res.eof) {
        doc.complete = true;
        doc.total_rows = doc.filter_rows;
        doc.filter_state = .done;
        doc.filter_total_exact = true;
        doc.filter_progress = 1.0;
    } else {
        doc.filter_progress = searchProgress(doc, res.end_offset);
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
    var fold = false;
    if (kind_i == 0) { // TEXT
        if (value.len == 0) return false; // empty query means "no filter"
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
    // Replace any previous filter ENTIRELY.
    if (d.filter_value.len > 0) d.gpa.free(d.filter_value);
    if (d.filter_scope_mask.len > 0) d.gpa.free(d.filter_scope_mask);
    d.filter_value = value_copy;
    d.filter_scope_mask = mask;
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
    d.filter_total = 0;
    d.filter_total_exact = false;
    d.filter_rows = 0;
    d.filter_offset = d.data_start;
    d.filter_progress = 0.0;

    if (d.data_start >= d.content_len or d.column_count == 0) {
        // Nothing to scan: already DONE with total 0.
        d.filter_state = .done;
        d.filter_total_exact = true;
        d.filter_progress = 1.0;
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
    while (d.filter_state == .scanning) {
        const res = filterScanChunk(d, d.filter_offset, d.filter_rows);
        commitFilter(d, res);
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
    d.filter_offset = 0;
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
