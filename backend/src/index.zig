//! The row index: checkpoints, the monotone scan frontier, the O(head) open
//! scan, and the background/jump worker (the sole frontier writer — see
//! api/lesssheet.h for the scan-frontier and threading-lanes model). The
//! worker also arbitrates the single scan slot among a jump, a find
//! (src/search.zig), and a filter-scan (src/filter.zig): jump > search >
//! filter > the AUTO background indexer. Parsing goes through
//! `Document.reader` (see docs/architecture/ARCH-reader-interface.md) — this
//! module never imports `lexer.zig`.

const std = @import("std");
const api = @import("api");
const posix = std.posix;

const base = @import("base.zig");
const filter = @import("filter.zig");
const search = @import("search.zig");
const column = @import("column.zig");
const source_mod = @import("source.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const Pos = base.Pos;
const checkpoint_interval = base.checkpoint_interval;
const head_budget = base.head_budget;

/// Background indexer madvise(DONTNEED) hygiene: after this many freshly
/// scanned bytes, drop the pages well behind the frontier so a multi-GB scan
/// keeps resident memory O(this), not O(file). Best-effort (errors ignored).
const madvise_release_chunk: u64 = 8 * 1024 * 1024;
const madvise_keepback: u64 = 2 * 1024 * 1024;

/// The effective O(head) budget for THIS document — the SINGLE net-vs-local
/// decision site. NETWORK docs use the small net head (base.net_head_budget,
/// ~256 KiB — the author's "speed over row estimation" perf choice, matching
/// net_source's prefetch); every LOCAL mmap/gzip doc keeps the full 4 MiB
/// head_budget byte-identically. No other site branches on doc.net for the head.
fn headBudget(doc: *const Document) u64 {
    return if (doc.net) base.net_head_budget else head_budget;
}

/// The O(head) SOURCE-byte scan bound shared by `root.buildShape`'s record-1
/// decode and `headScan`: the effective head budget minus the BOM, clamped to
/// the file's true (post-BOM) content length. Obtained from the Reader (see
/// reader.zig's `posAtByteBudget`) rather than computed here, so this stays a
/// plain byte-COUNT-to-position request, never arithmetic on a position.
pub fn headSourceLimit(doc: *const Document) Pos {
    const hb = headBudget(doc);
    const budget: u64 = if (hb > doc.bom_len) hb - doc.bom_len else 0;
    return doc.reader.posAtByteBudget(doc.source, doc.reader.start(doc.source), budget);
}

/// Index the head region only: advance the frontier over data records while
/// they fit within the O(head) byte budget. Files no larger than the budget
/// are fully indexed here (complete + exact immediately, per the ABI pin).
pub fn headScan(doc: *Document) void {
    const hb = headBudget(doc); // net -> ~256 KiB, local -> 4 MiB (one decision site)
    const lim = headSourceLimit(doc); // == min(hb, source end)
    var pos = doc.data_start;
    var row: u64 = 0;
    base.beginOversizedChunk(doc);
    while (!doc.reader.atEnd(doc.source, pos)) {
        const b = doc.reader.boundsAfter(doc.source, pos, lim);
        if (b.capped) break; // record spills past the head budget: leave for later
        if (doc.bom_len + doc.reader.bytesConsumed(doc.source, b.next) > hb) break; // keep bytes_scanned <= budget
        // ARCH-huge-row-budget: this row's source extent may exceed the
        // WINDOW's per-row scan cap (LS_WINDOW_ROW_SCAN_MAX_BYTES, much
        // smaller than the O(head) budget above) even though headScan itself
        // -- like every frontier scan -- always finds the row's true end.
        base.stageOversized(doc, row, pos, b.next);
        pos = b.next;
        row += 1;
        if (row % checkpoint_interval == 0) doc.checkpoints.append(doc.gpa, .{ .row = row, .pos = pos }) catch {};
        if (doc.reader.atEnd(doc.source, pos)) break;
    }
    // headScan is the document's very first frontier advance (the worker has
    // not spawned yet): always the leading edge, so always drained.
    base.drainOversized(doc, true);
    doc.frontier_pos = pos;
    doc.frontier_rows = row;
    if (doc.reader.atEnd(doc.source, pos)) {
        doc.complete = true;
        doc.total_rows = row;
    }
}

// ---------------------------------------------------------------------------
// The background/jump worker (sole frontier writer).
// ---------------------------------------------------------------------------

pub fn workerMain(doc: *Document) void {
    var released: u64 = 0; // bytes up to which pages were madvised away
    doc.lock();
    while (true) {
        if (doc.stop) {
            doc.endMatchScan();
            break;
        }
        // TEST-ONLY (base.Document.scan_park; DEFAULT false => byte-identical
        // behavior): while parked, a test owns the gzip FILTER/SEARCH match-scan
        // and drives it one 2048-row block at a time on its OWN thread. The
        // worker must touch NOTHING here -- not even the match_scan_owner
        // reconciliation below -- or it would tear the test's leased scan cursor
        // down mid-chunk. It re-checks on every wake, so unpark resumes normally.
        if (doc.scan_park.load(.acquire)) {
            doc.waitWork();
            continue;
        }
        // Slot priority: a scanning jump owns the frontier; else a scanning
        // search (find — which runs even after the index is complete; it must
        // re-lex behind the frontier to COUNT); else exact filtered navigation;
        // else a scanning (or, under AUTO, cancelled-but-resumable) filter-scan;
        // else the AUTO background indexer. See api/lesssheet.h FILTERED VIEWS
        // "the single scan slot".
        const do_jump = doc.jump_state == .scanning and (doc.filter_state != .idle or !doc.complete);
        const do_search = !do_jump and doc.search_state == .scanning;
        const do_nav = !do_jump and !do_search and doc.filter_state != .idle and
            doc.nav_pending and doc.search_nav == .searching and
            doc.search_state == .done and doc.filter_total_exact;
        // never-full-download-streaming (TD1): a NETWORK document has NO
        // background frontier drive — neither the AUTO indexer nor the filter's
        // auto-drive-to-completion. The frontier advances only on concrete demand
        // (viewport jump / search nav / filtered jump), all on this same worker
        // but never as an unbidden to-EOF scan over the wire. LOCAL docs
        // (doc.net == false) are byte-identical.
        const do_filter = !do_jump and !do_search and !do_nav and !doc.net and
            (doc.filter_state == .scanning or (doc.filter_state == .cancelled and doc.auto));
        // Column inference is deliberately behind every interactive scan
        // owner, but ahead of the opportunistic AUTO frontier indexer. Its
        // bounded sampler only re-reads the already-known head.
        const do_column = !do_jump and !do_search and !do_nav and !do_filter and
            doc.column_store.job_state == .queued;
        const do_index = !do_jump and !do_search and !do_nav and !do_filter and !do_column and doc.auto and !doc.complete and !doc.net;
        const wanted_scan: base.MatchScanOwner = if (do_jump and doc.filter_state != .idle)
            .filter
        else if (do_search)
            .search
        else if (do_filter)
            .filter
        else
            .none;
        if (doc.match_scan_owner != wanted_scan) doc.endMatchScan();
        if (!(do_jump or do_search or do_nav or do_filter or do_column or do_index)) {
            doc.waitWork();
            continue;
        }

        if (do_column) {
            column.workerRunLocked(doc);
            // Every inference chunk hands the control mutex back before the
            // worker arbitrates again, so cancel/poll and newly-arrived
            // jump/Find/filter work take effect at this boundary.
            doc.unlock();
            std.Thread.yield() catch {};
            doc.lock();
            continue;
        }

        if (do_nav) {
            if (doc.search_gen != doc.w_gen) {
                if (!search.refreshWorkerCtx(doc)) {
                    search.failSearchLocked(doc);
                    continue;
                }
                doc.w_gen = doc.search_gen;
            }
            if (doc.filter_gen != doc.wf_gen) {
                if (!filter.refreshFilterWorkerCtx(doc)) {
                    search.failSearchLocked(doc);
                    continue;
                }
                doc.wf_gen = doc.filter_gen;
            }
            const nav_gen = doc.nav_gen;
            const search_gen = doc.search_gen;
            const filter_gen = doc.filter_gen;
            const anchor = doc.nav_anchor;
            const dir = doc.nav_dir;
            const pctx = doc.w_ctx;
            const fctx = doc.wf_ctx;
            doc.unlock();

            const outcome = search.resolveFilteredNavOffMain(doc, nav_gen, search_gen, filter_gen, anchor, dir, pctx, fctx);

            doc.lock();
            if (outcome) |result| {
                if (doc.nav_pending and doc.search_nav == .searching and
                    doc.nav_gen == nav_gen and doc.search_gen == search_gen and
                    doc.filter_gen == filter_gen)
                {
                    if (result.found) {
                        doc.search_found_row = result.row;
                        doc.search_found_col = result.col;
                        doc.search_position = result.position;
                        doc.search_nav = .found;
                    } else {
                        doc.search_nav = .exhausted;
                    }
                    doc.nav_pending = false;
                }
            }
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
            const start_pos = doc.filter_pos;
            const start_row = doc.filter_rows;
            doc.unlock();

            const res = filter.filterScanChunk(doc, start_pos, start_row, gen);

            doc.lock();
            if (doc.filter_gen == gen and doc.jump_state == .scanning) {
                filter.commitFilter(doc, res);
                filter.resolveFilterJumpLocked(doc);
                column.sourceCompletedLocked(doc);
                // security-hardening (e) AC-e3: the filtered jump is the LIVE
                // network filter driver (`do_filter` is gated off for net docs),
                // so this is where a short body strands it. The scan made no
                // progress and cannot: end the jump at the last match we DO have
                // (mirroring resolveFilterJumpLocked's clamp, but WITHOUT
                // filter_total_exact — the tail is un-fetched, not empty) and
                // re-park the filter, so the worker stops re-entering on a
                // zero-progress cursor.
                if (res.stalled and doc.jump_state == .scanning) {
                    doc.jump_state = .done;
                    doc.jump_progress = 1.0;
                    doc.jump_landed = if (doc.filter_total > 0) doc.filter_total - 1 else 0;
                }
                if (res.stalled) filter.finishStalledLocked(doc);
            }
            const advanced = doc.reader.physicalBytes(doc.source, doc.frontier_pos);
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
            const start_pos = doc.filter_pos;
            const start_row = doc.filter_rows;
            doc.unlock();

            const res = filter.filterScanChunk(doc, start_pos, start_row, gen);

            doc.lock();
            if (doc.filter_gen == gen and doc.filter_state == .scanning) {
                filter.commitFilter(doc, res);
                column.sourceCompletedLocked(doc);
                // security-hardening (e) AC-e3: the scan stalled on un-fetched
                // bytes. Freeze the filter at its last consistent state
                // (CANCELLED — counts exact for what IS present, view NOT
                // complete) instead of re-entering on a zero-progress cursor.
                if (res.stalled) filter.finishStalledLocked(doc);
            }
            const advanced = doc.reader.physicalBytes(doc.source, doc.frontier_pos);
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
            const start_pos = doc.search_pos;
            const start_row = doc.search_rows;
            doc.unlock();

            // Lex + match a chunk of rows lock-free (worker snapshot only).
            const res = search.searchScanChunk(doc, start_pos, start_row, filtered, gen);

            doc.lock();
            // Commit only if this is still the same, still-scanning search;
            // otherwise discard (a replace bumped the gen, or a jump/cancel took
            // the slot — counts freeze at the last committed chunk).
            if (doc.search_gen == gen and doc.search_state == .scanning) {
                search.commitSearch(doc, res, filtered);
                column.sourceCompletedLocked(doc);
                search.resolveNavLocked(doc);
                if (doc.search_state == .scanning and !doc.search_to_eof and !doc.nav_pending) {
                    // A nav-limited resume served its navigation before EOF.
                    doc.search_state = .cancelled;
                }
                // security-hardening (e) AC-e3: the scan stalled on un-fetched
                // bytes. `resolveNavLocked` above already served any navigation
                // reachable within the PRESENT rows; freeze the search there
                // (CANCELLED, counts frozen, pending nav -> NONE) rather than
                // spinning and inflating the row/match counts. Runs after the
                // commit so everything actually scanned is kept.
                if (res.stalled) search.finishStalledLocked(doc);
            }
            const advanced = doc.reader.physicalBytes(doc.source, doc.frontier_pos);
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
        const start_pos = doc.frontier_pos;
        const start_row = doc.frontier_rows;
        doc.unlock();

        const res = scanChunk(doc, start_pos, start_row);

        doc.lock();
        doc.frontier_pos = res.end_pos;
        doc.frontier_rows = res.end_row;
        if (res.checkpoint) |cp| doc.checkpoints.append(doc.gpa, cp) catch {};
        // scanChunk always starts exactly at the frontier: always the leading
        // edge, so always drained (see base.drainOversized).
        base.drainOversized(doc, true);
        if (res.eof) {
            doc.complete = true;
            doc.total_rows = doc.frontier_rows;
        } else if (doc.jump_state == .scanning and !doc.stop_atomic.load(.monotonic) and
            res.end_row == start_row and base.scanStalled(doc, start_pos, res.end_pos))
        {
            // security-hardening (e) AC-e3: a NETWORK jump that made NO forward
            // progress because the next bytes are un-fetched (a short/failed range
            // left them not-present, below the known end) is a STALL, not EOF. End
            // the jump at the current frontier WITHOUT marking the doc complete (the
            // un-fetched tail is never zero-filled or counted) and stop driving, so
            // the worker neither spins nor hammers the transport re-fetching a byte
            // that will not arrive. A retry, or a demand for already-present bytes,
            // still resolves normally.
            // The predicate is exact, not a proxy (see base.scanStalled: LOGICAL
            // bytes — a net gzip shares one physical offset across many logical
            // positions). `stop_atomic` is excluded explicitly: `scanChunk`
            // returns the same no-progress shape on cancellation, which would
            // otherwise land here and publish a bogus `.done` / 1.0 jump.
            doc.jump_state = .done;
            doc.jump_progress = 1.0;
            doc.jump_landed = if (doc.frontier_rows > 0) doc.frontier_rows - 1 else 0;
        }
        column.sourceCompletedLocked(doc);
        if (doc.jump_state == .scanning) updateJump(doc);
        const advanced = doc.reader.physicalBytes(doc.source, doc.frontier_pos);
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
    end_pos: Pos,
    end_row: u64,
    eof: bool,
    checkpoint: ?Checkpoint,
};

/// Lex records from `start_pos`/`start_row` up to the next `checkpoint_interval`
/// multiple, or EOF, or a stop request. Reads only via the Reader (immutable
/// mmap bytes, for CSV); also stages any oversized row it crosses
/// (base.stageOversized) for the caller to drain at commit time
/// (base.drainOversized) -- ARCH-huge-row-budget.
fn scanChunk(doc: *Document, start_pos: Pos, start_row: u64) ChunkResult {
    var pos = start_pos;
    var row = start_row;
    const target = ((start_row / checkpoint_interval) + 1) * checkpoint_interval;
    base.beginOversizedChunk(doc);
    if (doc.source != .mmap) {
        if (doc.stop_atomic.load(.monotonic)) return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = null };
        const batch = doc.reader.scanRows(doc.source, pos, target - row);
        pos = batch.next;
        row += batch.rows;
        if (batch.eof) return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null };
        return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .pos = pos } };
    }
    while (row < target) {
        if (doc.stop_atomic.load(.monotonic)) return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = null };
        if (doc.reader.atEnd(doc.source, pos)) return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null };
        const b = doc.reader.boundsAfter(doc.source, pos, null);
        base.stageOversized(doc, row, pos, b.next);
        pos = b.next;
        row += 1;
        if (doc.reader.atEnd(doc.source, pos)) return .{ .end_pos = pos, .end_row = row, .eof = true, .checkpoint = null };
    }
    return .{ .end_pos = pos, .end_row = row, .eof = false, .checkpoint = .{ .row = row, .pos = pos } };
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
        // Byte-frontier progress (bug #6): the fraction of BYTES the scan has
        // covered toward where the target row is PROJECTED to sit, capped at the
        // resource end — so a BEYOND-EOF target tracks the advance toward EOF and
        // climbs high near the end, instead of a ratio against an UNREACHABLE
        // target ROW that caps near 0. The DONE branch above still delivers the
        // exact 1.0 at completion; this monotone guard only ever RAISES progress,
        // so [0,1] + monotone + exactly-1.0-at-DONE (the JumpStatus contract, and
        // the local-jump tests c6 et al.) all hold. Byte-denominated like
        // base.searchProgress (physicalBytes + file_size are the same unit).
        const start_bytes = doc.reader.physicalBytes(doc.source, doc.data_start);
        const frontier_bytes = doc.reader.physicalBytes(doc.source, doc.frontier_pos);
        const covered = frontier_bytes -| start_bytes;
        const data_span = doc.file_size -| start_bytes;
        if (data_span > 0 and doc.frontier_rows > 0) {
            // Project the target's byte offset from the scanned byte/row rate,
            // capped at the data end (a beyond-EOF target => scan toward EOF).
            const projected = @as(u128, doc.jump_target) * @as(u128, covered) / @as(u128, doc.frontier_rows);
            const target_span: u64 = if (projected < data_span) @intCast(projected) else data_span;
            if (target_span > 0) {
                const raw = @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(target_span));
                const p = if (raw > 1.0) 1.0 else raw;
                if (p > doc.jump_progress) doc.jump_progress = p;
            }
        } else {
            // Unknown-length stream (no byte total) / no rows yet: the original
            // row ratio (safe fallback; no test pins those to a high value).
            const span = doc.jump_target - doc.jump_start_rows;
            if (span > 0) {
                const p = @as(f64, @floatFromInt(doc.frontier_rows - doc.jump_start_rows)) / @as(f64, @floatFromInt(span));
                if (p > doc.jump_progress) doc.jump_progress = p;
            }
        }
    }
}

fn madviseDontNeed(doc: *Document, start_physical: u64, end_physical: u64) void {
    const m = doc.mapping orelse return;
    const psz: u64 = std.heap.page_size_min;
    const a_start = std.mem.alignForward(u64, start_physical, psz);
    const a_end = std.mem.alignBackward(u64, end_physical, psz);
    if (a_end <= a_start or a_end > m.len) return;
    const ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@constCast(m.ptr + @as(usize, @intCast(a_start))));
    posix.madvise(ptr, @intCast(a_end - a_start), posix.MADV.DONTNEED) catch {};
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
    // never-full-download-streaming (TD6): an UNKNOWN-length network stream has
    // no total to project from, so it reports a discovered-rows LOWER BOUND
    // (frontier_rows, exact=false) that firms only as the user navigates. A
    // KNOWN-length network doc keeps the free projection below (no fetch).
    if (d.net and source_mod.netPhysicalTotal(d.source) == null)
        return .{ .count = d.frontier_rows, .exact = false };
    // Estimate = total data bytes / mean indexed row bytes. `bytesConsumed`
    // is the only place a position is turned back into a byte count here
    // (see reader.zig's module doc).
    const start_bytes = d.reader.physicalBytes(d.source, d.data_start);
    const frontier_bytes = d.reader.physicalBytes(d.source, d.frontier_pos);
    const scanned_data = frontier_bytes - start_bytes;
    const total_data = d.content_len - start_bytes;
    var count: u64 = 0;
    if (d.frontier_rows == 0 or scanned_data == 0) {
        count = if (total_data > 0) 1 else 0;
    } else {
        count = @intCast(@as(u128, total_data) * @as(u128, d.frontier_rows) / @as(u128, scanned_data));
    }
    return .{ .count = @max(count, d.frontier_rows), .exact = false };
}

/// See api/lesssheet.h `ls_index_poll`.
pub fn indexPoll(d: *Document) api.ScanProgress {
    d.lock();
    defer d.unlock();
    // never-full-download-streaming (TD5): a network document's total comes from
    // the Source (known length, or the received size once EOF firmed it), or the
    // UINT64_MAX sentinel while an unknown-length stream's total is not yet
    // known. bytes_scanned is the frontier's physical high-water. `complete` is
    // true only when navigation has reached EOF (the lazy gate never drives it).
    if (d.net) {
        const frontier_phys = d.reader.physicalBytes(d.source, d.frontier_pos);
        if (source_mod.netPhysicalTotal(d.source)) |phys_total| return .{
            .bytes_scanned = if (d.complete) phys_total else @min(phys_total, frontier_phys),
            .bytes_total = phys_total,
            .complete = d.complete,
        };
        return .{
            .bytes_scanned = frontier_phys,
            .bytes_total = api.bytes_total_unknown,
            .complete = d.complete,
        };
    }
    return .{
        .bytes_scanned = if (d.complete) d.file_size else @min(d.file_size, d.reader.physicalBytes(d.source, d.frontier_pos)),
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
