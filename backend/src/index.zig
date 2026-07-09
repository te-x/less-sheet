//! The row index: checkpoints, the monotone scan frontier, the O(head) open
//! scan, and the background/jump worker (the sole frontier writer — see
//! api/lesssheet.h for the scan-frontier and threading-lanes model). The
//! worker also arbitrates the single scan slot among a jump, a find
//! (src/search.zig), and a filter-scan (src/filter.zig): jump > search >
//! filter > the AUTO background indexer.

const std = @import("std");
const api = @import("api");
const posix = std.posix;
const c = std.c;

const base = @import("base.zig");
const lexer = @import("lexer.zig");
const filter = @import("filter.zig");
const search = @import("search.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const checkpoint_interval = base.checkpoint_interval;
const head_budget = base.head_budget;

/// Background indexer madvise(DONTNEED) hygiene: after this many freshly
/// scanned bytes, drop the pages well behind the frontier so a multi-GB scan
/// keeps resident memory O(this), not O(file). Best-effort (errors ignored).
const madvise_release_chunk: u64 = 8 * 1024 * 1024;
const madvise_keepback: u64 = 2 * 1024 * 1024;

/// The O(head) SOURCE-byte scan bound shared by `root.buildShape`'s record-1
/// decode and `headScan`: `LS_OPEN_HEAD_MAX_BYTES` minus the BOM, clamped to
/// the file's true (post-BOM) content length.
pub fn headSourceLimit(doc: *const Document) usize {
    const budget: usize = if (head_budget > doc.bom_len) @intCast(head_budget - doc.bom_len) else 0;
    return @min(budget, doc.content.len);
}

/// Index the head region only: advance the frontier over data records while
/// they fit within the O(head) byte budget. Files no larger than the budget
/// are fully indexed here (complete + exact immediately, per the ABI pin).
pub fn headScan(doc: *Document) void {
    const content = doc.content;
    const lim = headSourceLimit(doc); // == min(budget, content.len)
    var i: usize = @intCast(doc.data_start);
    var row: u64 = 0;
    base.beginOversizedChunk(doc);
    while (i < lim) {
        const b = lexer.recordBounds(content, i, doc.sep, doc.quote, lim, doc.encoding);
        if (b.capped) break; // record spills past the head budget: leave for later
        if (doc.bom_len + b.next > head_budget) break; // keep bytes_scanned <= budget
        // ARCH-huge-row-budget: this row's source extent may exceed the
        // WINDOW's per-row scan cap (LS_WINDOW_ROW_SCAN_MAX_BYTES, much
        // smaller than the O(head) budget above) even though headScan itself
        // -- like every frontier scan -- always finds the row's true end.
        base.stageOversized(doc, row, @intCast(i), @intCast(b.next));
        i = b.next;
        row += 1;
        if (row % checkpoint_interval == 0) doc.checkpoints.append(doc.gpa, .{ .row = row, .offset = i }) catch {};
        if (b.next >= content.len) break;
    }
    // headScan is the document's very first frontier advance (the worker has
    // not spawned yet): always the leading edge, so always drained.
    base.drainOversized(doc, true);
    doc.frontier_offset = i;
    doc.frontier_rows = row;
    if (i >= content.len) {
        doc.complete = true;
        doc.total_rows = row;
    }
}

// ---------------------------------------------------------------------------
// The background/jump worker (sole frontier writer).
// ---------------------------------------------------------------------------

pub fn workerMain(doc: *Document) void {
    var released: u64 = 0; // content offset up to which pages were madvised away
    doc.lock();
    while (true) {
        if (doc.stop) break;
        // Slot priority: a scanning jump owns the frontier; else a scanning
        // search (find — which runs even after the index is complete; it must
        // re-lex behind the frontier to COUNT); else a scanning (or, under
        // AUTO, cancelled-but-resumable) filter-scan; else the AUTO background
        // indexer. See api/lesssheet.h FILTERED VIEWS "the single scan slot".
        const do_jump = doc.jump_state == .scanning and (doc.filter_state != .idle or !doc.complete);
        const do_search = !do_jump and doc.search_state == .scanning;
        const do_filter = !do_jump and !do_search and
            (doc.filter_state == .scanning or (doc.filter_state == .cancelled and doc.auto));
        const do_index = !do_jump and !do_search and !do_filter and doc.auto and !doc.complete;
        if (!(do_jump or do_search or do_filter or do_index)) {
            doc.waitWork();
            continue;
        }

        if (do_jump and doc.filter_state != .idle) {
            // FILTERED jump: target is an ORIGINAL row; drive the SAME
            // filter-scan machinery toward it (see FILTERED VIEWS JUMP).
            // Taking the slot cancels a scanning filter-scan (mode persists).
            if (doc.filter_state == .scanning) doc.filter_state = .cancelled;
            if (doc.filter_gen != doc.wf_gen) {
                if (!filter.refreshFilterWorkerCtx(doc)) {
                    filter.failFilterLocked(doc);
                    continue;
                }
                doc.wf_gen = doc.filter_gen;
            }
            const gen = doc.filter_gen;
            const start_off = doc.filter_offset;
            const start_row = doc.filter_rows;
            doc.unlock();

            const res = filter.filterScanChunk(doc, start_off, start_row);

            doc.lock();
            if (doc.filter_gen == gen and doc.jump_state == .scanning) {
                filter.commitFilter(doc, res);
                filter.resolveFilterJumpLocked(doc);
            }
            const advanced = doc.frontier_offset;
            doc.unlock();

            if (doc.mapping != null and advanced > released + madvise_release_chunk and advanced > madvise_keepback) {
                const rel_end = advanced - madvise_keepback;
                madviseDontNeed(doc, released, rel_end);
                released = rel_end;
            }
            doc.lock();
            continue;
        }

        if (do_filter) {
            // The filter's OWN job (not driven by a jump): a background
            // view-completion scan toward EOF (see FILTERED VIEWS).
            doc.filter_state = .scanning;
            if (doc.filter_gen != doc.wf_gen) {
                if (!filter.refreshFilterWorkerCtx(doc)) {
                    filter.failFilterLocked(doc);
                    continue;
                }
                doc.wf_gen = doc.filter_gen;
            }
            const gen = doc.filter_gen;
            const start_off = doc.filter_offset;
            const start_row = doc.filter_rows;
            doc.unlock();

            const res = filter.filterScanChunk(doc, start_off, start_row);

            doc.lock();
            if (doc.filter_gen == gen and doc.filter_state == .scanning) {
                filter.commitFilter(doc, res);
            }
            const advanced = doc.frontier_offset;
            doc.unlock();

            if (doc.mapping != null and advanced > released + madvise_release_chunk and advanced > madvise_keepback) {
                const rel_end = advanced - madvise_keepback;
                madviseDontNeed(doc, released, rel_end);
                released = rel_end;
            }
            doc.lock();
            continue;
        }

        if (do_search) {
            // Refresh the worker's request snapshot on a new search generation.
            if (doc.search_gen != doc.w_gen) {
                if (!search.refreshWorkerCtx(doc)) {
                    // OOM snapshotting the request: fail the search cleanly
                    // rather than scan against a truncated query. Lock still
                    // held; the loop top re-selects a job.
                    search.failSearchLocked(doc);
                    continue;
                }
                doc.w_gen = doc.search_gen;
            }
            // While filtered, find composes the filter predicate too (see
            // FILTERED VIEWS FIND) — refresh the worker's lock-free filter
            // snapshot alongside the find one.
            const filtered = doc.filter_state != .idle;
            if (filtered and doc.filter_gen != doc.wf_gen) {
                if (!filter.refreshFilterWorkerCtx(doc)) {
                    search.failSearchLocked(doc);
                    continue;
                }
                doc.wf_gen = doc.filter_gen;
            }
            const gen = doc.search_gen;
            const start_off = doc.search_offset;
            const start_row = doc.search_rows;
            doc.unlock();

            // Lex + match a chunk of rows lock-free (worker snapshot only).
            const res = search.searchScanChunk(doc, start_off, start_row, filtered);

            doc.lock();
            // Commit only if this is still the same, still-scanning search;
            // otherwise discard (a replace bumped the gen, or a jump/cancel took
            // the slot — counts freeze at the last committed chunk).
            if (doc.search_gen == gen and doc.search_state == .scanning) {
                search.commitSearch(doc, res, filtered);
                search.resolveNavLocked(doc);
                if (doc.search_state == .scanning and !doc.search_to_eof and !doc.nav_pending) {
                    // A nav-limited resume served its navigation before EOF.
                    doc.search_state = .cancelled;
                }
            }
            const advanced = doc.frontier_offset;
            doc.unlock();

            if (doc.mapping != null and advanced > released + madvise_release_chunk and advanced > madvise_keepback) {
                const rel_end = advanced - madvise_keepback;
                madviseDontNeed(doc, released, rel_end);
                released = rel_end;
            }
            doc.lock();
            continue;
        }

        // Jump or plain-index chunk: advance the frontier only (unchanged from
        // the viewer-ui worker; the sole frontier writer, so lock-free).
        const start_off = doc.frontier_offset;
        const start_row = doc.frontier_rows;
        doc.unlock();

        const res = scanChunk(doc, start_off, start_row);

        doc.lock();
        doc.frontier_offset = res.end_offset;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.append(doc.gpa, cp) catch {};
        // scanChunk always starts exactly at the frontier: always the leading
        // edge, so always drained (see base.drainOversized).
        base.drainOversized(doc, true);
        if (res.eof) {
            doc.complete = true;
            doc.total_rows = doc.frontier_rows;
        }
        if (doc.jump_state == .scanning) updateJump(doc);
        const advanced = doc.frontier_offset;
        doc.unlock();

        // Release pages far behind the frontier (bounded resident memory).
        if (doc.mapping != null and advanced > released + madvise_release_chunk and advanced > madvise_keepback) {
            const rel_end = advanced - madvise_keepback;
            madviseDontNeed(doc, released, rel_end);
            released = rel_end;
        }

        doc.lock();
    }
    doc.unlock();
}

const ChunkResult = struct {
    end_offset: u64,
    end_row: u64,
    eof: bool,
    checkpoint: ?Checkpoint,
};

/// Lex records from `start_off`/`start_row` up to the next `checkpoint_interval`
/// multiple, or EOF, or a stop request. Reads only immutable mmap bytes; also
/// stages any oversized row it crosses (base.stageOversized) for the caller
/// to drain at commit time (base.drainOversized) -- ARCH-huge-row-budget.
fn scanChunk(doc: *Document, start_off: u64, start_row: u64) ChunkResult {
    const content = doc.content;
    var i: usize = @intCast(start_off);
    var row = start_row;
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    base.beginOversizedChunk(doc);
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = null };
        if (i >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null };
        const b = lexer.recordBounds(content, i, doc.sep, doc.quote, content.len, doc.encoding);
        base.stageOversized(doc, row, @intCast(i), @intCast(b.next));
        i = b.next;
        row += 1;
        if (b.next >= content.len) return .{ .end_offset = i, .end_row = row, .eof = true, .checkpoint = null };
    }
    return .{ .end_offset = i, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .offset = i } };
}

/// Fold the current frontier into the active jump slot (mutex held).
fn updateJump(doc: *Document) void {
    if (doc.frontier_rows > doc.jump_target or doc.complete) {
        doc.jump_state = .done;
        doc.jump_landed = if (doc.jump_target < doc.frontier_rows)
            doc.jump_target
        else if (doc.frontier_rows > 0) doc.frontier_rows - 1 else 0;
        doc.jump_progress = 1.0;
    } else {
        const span = doc.jump_target - doc.jump_start_rows;
        if (span > 0) {
            const p = @as(f64, @floatFromInt(doc.frontier_rows - doc.jump_start_rows)) / @as(f64, @floatFromInt(span));
            if (p > doc.jump_progress) doc.jump_progress = p;
        }
    }
}

fn madviseDontNeed(doc: *Document, start_content: u64, end_content: u64) void {
    const m = doc.mapping orelse return;
    const psz: u64 = std.heap.page_size_min;
    const a_start = std.mem.alignForward(u64, doc.bom_len + start_content, psz);
    const a_end = std.mem.alignBackward(u64, doc.bom_len + end_content, psz);
    if (a_end <= a_start or a_end > m.len) return;
    const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@constCast(m.ptr + @as(usize, @intCast(a_start))));
    posix.madvise(ptr, @intCast(a_end - a_start), c.MADV.DONTNEED) catch {};
}

// ---------------------------------------------------------------------------
// Row-count knowledge and index progress (see api/lesssheet.h ls_row_count_get
// / ls_index_poll). The `pub export fn` wrappers stay in root.zig.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_row_count_get`.
pub fn rowCount(d: *Document) api.RowCount {
    d.lock();
    defer d.unlock();
    // While filtered, report the FILTERED match count (see FILTERED VIEWS):
    // identical semantics to the unfiltered count during indexing (a
    // converging lower bound that becomes exact at LS_FILTER_DONE).
    if (d.filter_state != .idle) return .{ .count = d.filter_total, .exact = d.filter_total_exact };
    if (d.complete) return .{ .count = d.total_rows, .exact = true };
    // Estimate = total data bytes / mean indexed row bytes.
    const scanned_data = d.frontier_offset - d.data_start;
    const total_data = d.content_len - d.data_start;
    var count: u64 = 0;
    if (d.frontier_rows == 0 or scanned_data == 0) {
        count = if (total_data > 0) 1 else 0;
    } else {
        count = @intCast(@as(u128, total_data) * @as(u128, d.frontier_rows) / @as(u128, scanned_data));
    }
    return .{ .count = count, .exact = false };
}

/// See api/lesssheet.h `ls_index_poll`.
pub fn indexPoll(d: *Document) api.ScanProgress {
    d.lock();
    defer d.unlock();
    return .{
        .bytes_scanned = d.bom_len + d.frontier_offset,
        .bytes_total = d.file_size,
        .complete = d.complete,
    };
}

// ---------------------------------------------------------------------------
// Jump-scans (see api/lesssheet.h ls_jump_start/cancel/poll). The `pub export
// fn` wrappers stay in root.zig.
// ---------------------------------------------------------------------------

/// See api/lesssheet.h `ls_jump_start`. Caller (root.zig) holds no lock; this
/// takes the document mutex itself, mirroring the original ABI body.
pub fn jumpStart(d: *Document, target_row: u64) void {
    d.lock();
    defer d.unlock();
    if (d.filter_state != .idle) {
        filter.jumpStartFiltered(d, target_row);
        return;
    }
    if (target_row < d.frontier_rows) {
        // Behind the frontier: complete before this call returns.
        d.jump_state = .done;
        d.jump_landed = target_row;
        d.jump_progress = 1.0;
        return;
    }
    if (d.complete) {
        // At/past EOF with an exact count: clamp to the last data row.
        d.jump_state = .done;
        d.jump_landed = if (d.frontier_rows > 0) d.frontier_rows - 1 else 0;
        d.jump_progress = 1.0;
        return;
    }
    if (d.worker == null) {
        // Degraded mode: the background worker failed to spawn at open, so no
        // scan can advance the frontier and AUTO indexing is frozen at the
        // head. Fail OPEN — land at the frontier edge (the last row the head
        // window can serve) and report DONE, instead of leaving the jump
        // SCANNING forever (which would hang the caller's poll loop).
        d.jump_state = .done;
        d.jump_landed = if (d.frontier_rows > 0) d.frontier_rows - 1 else 0;
        d.jump_progress = 1.0;
        return;
    }
    // Taking the scan slot cancels a search in LS_SEARCH_SCANNING (its counts,
    // found results, and frontier gains are kept; a pending nav resolves to
    // NONE). Instant jumps (handled above) never reach here, so they never
    // disturb a running search.
    if (d.search_state == .scanning) {
        d.search_state = .cancelled;
        if (d.search_nav == .searching) {
            d.search_nav = .none;
            d.nav_pending = false;
        }
    }

    // Asynchronous scan toward the target (retargets any running jump).
    d.jump_state = .scanning;
    d.jump_target = target_row;
    d.jump_start_rows = d.frontier_rows;
    d.jump_progress = 0.0;
    d.wakeWorker();
}

/// See api/lesssheet.h `ls_jump_cancel`.
pub fn jumpCancel(d: *Document) void {
    d.lock();
    defer d.unlock();
    if (d.jump_state == .scanning) {
        d.jump_state = .idle; // frontier gains are kept (we never rewind it)
        d.jump_progress = 0.0;
    }
}

/// See api/lesssheet.h `ls_jump_poll`.
pub fn jumpPoll(d: *Document) api.JumpStatus {
    d.lock();
    defer d.unlock();
    return .{ .state = d.jump_state, .progress = d.jump_progress, .landed_row = d.jump_landed };
}
