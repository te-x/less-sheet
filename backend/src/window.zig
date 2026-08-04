//! Windowed row access: the `ls_window_set` materialization (identity and
//! filtered-coordinate variants) and the cell/header-cell/source-row
//! accessors that serve the materialized window. See api/lesssheet.h for the
//! eviction-safe borrow rule and FILTERED VIEWS for the filtered-coordinate
//! remap. The `pub export fn` wrappers stay in root.zig; these are their
//! bodies (window state — win_buf/win_refs/win_source/win_first/win_rows —
//! lives on `Document`, touched only by the caller-serialized window lane,
//! so most of this needs no lock; windowSetFiltered is the one exception,
//! per its own doc comment). All parsing goes through `Document.reader`
//! (see docs/architecture/ARCH-reader-interface.md) — this module never
//! imports `lexer.zig`/`encoding.zig` and never assumes a row `Pos` is a
//! byte offset (reader.zig's module doc).

const api = @import("api");
const base = @import("base.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");
const filter = @import("filter.zig");
const search = @import("search.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const Pos = base.Pos;

const empty_str: api.Str = .{ .ptr = "", .len = 0 };
const aggregate_budget_max: u64 = 8 * 1024 * 1024;

fn clearWindow(d: *Document, first_row: u64) void {
    d.win_buf.clearRetainingCapacity();
    d.win_refs.clearRetainingCapacity();
    d.win_source.clearRetainingCapacity();
    d.win_pos.clearRetainingCapacity();
    d.win_oversized.clearRetainingCapacity();
    d.win_first = first_row;
    d.win_rows = 0;
    d.win_cursor_valid = false;
    d.win_filter_locating = false;
    d.win_filter_skip = 0;
    d.win_candidate_tested = false;
}

fn charge(d: *Document, from: Pos, to: Pos) void {
    const a = d.reader.logicalBytes(d.source, from);
    const b = d.reader.logicalBytes(d.source, to);
    d.window_charged_bytes += b -| a;
}

fn remainingBudget(d: *const Document) u64 {
    return aggregate_budget_max -| d.window_charged_bytes;
}

fn appendRowMetadata(d: *Document, source_row: u64, pos: Pos, oversized: bool, buf_mark: usize, refs_mark: usize) bool {
    d.win_source.append(d.gpa, source_row) catch {
        d.win_buf.items.len = buf_mark;
        d.win_refs.items.len = refs_mark;
        return false;
    };
    d.win_pos.append(d.gpa, pos) catch {
        d.win_source.items.len -= 1;
        d.win_buf.items.len = buf_mark;
        d.win_refs.items.len = refs_mark;
        return false;
    };
    d.win_oversized.append(d.gpa, oversized) catch {
        d.win_source.items.len -= 1;
        d.win_pos.items.len -= 1;
        d.win_buf.items.len = buf_mark;
        d.win_refs.items.len = refs_mark;
        return false;
    };
    return true;
}

/// ARCH-security-hardening (g) AC-g1 — the SOURCE-FAULT GUARD bracket around the
/// window re-lex. A window re-lexes source bytes BEHIND the frontier, which makes
/// it the one FOREGROUND (UI-thread) reader that can touch a page whose file no
/// longer has it. If the guard repaired a fault while `windowSetInner` ran, the
/// rows it built came from zero-fill: serve NO rows rather than rows whose cells
/// are empty or invented, and report the terminal truncated/faulted outcome.
///
/// The comparison is against a fault count taken around THIS call, not a sticky
/// "has ever faulted" flag — that is what lets a truncated document keep serving
/// the rows it CAN still read instead of going permanently blank.
pub fn windowSet(d: *Document, first_row: u64, row_count: u32) api.RowRange {
    const faults_before = base.sourceFaultCount(d);
    const res = windowSetInner(d, first_row, row_count);
    if (base.sourceFaultCount(d) == faults_before) return res;
    d.lock();
    base.reportSourceFaultLocked(d);
    d.unlock();
    clearWindow(d, first_row);
    return .{ .first_row = first_row, .row_count = 0 };
}

/// See api/lesssheet.h `ls_window_set`. Never advances the frontier; re-lexes
/// the requested rows (behind the frontier) from the nearest checkpoint into
/// the owned window buffer. Changed requests evict; identical requests retain
/// and extend their completed prefix. Every cell is
/// decoded through the Reader (the document's resolved encoding) and
/// display-capped to LS_CELL_MAX_BYTES (requirement 8). ARCH-huge-row-budget:
/// the SOURCE bytes scanned per row are ALSO bounded to
/// `api.window_row_scan_max_bytes`, so this stays O(min(row bytes, cap) x
/// rows) regardless of row size (see the materialize loop below).
fn windowSetInner(d: *Document, first_row: u64, row_count: u32) api.RowRange {
    // MATERIALIZATION EPOCH bump (thin-frontend-shared-core Phase 1): every
    // ls_window_set invalidates the match-flags borrow (win_gen keys the memo),
    // exactly like it invalidates the ls_cell borrow. Window-lane serialized
    // with matchFlags, so no lock is needed for this counter itself.
    d.win_gen +%= 1;
    d.window_charged_bytes = 0;
    const clamped: u64 = @min(@as(u64, row_count), @as(u64, api.window_max_rows));

    d.lock();
    const filtered = d.filter_state != .idle;
    const filter_gen = d.filter_gen;
    d.unlock();

    const identical = d.win_request_valid and
        d.win_first == first_row and
        d.win_request_count == clamped and
        d.win_request_filtered == filtered and
        d.win_request_filter_gen == filter_gen;
    if (!identical) {
        clearWindow(d, first_row);
        d.win_request_valid = true;
        d.win_request_count = clamped;
        d.win_request_filtered = filtered;
        d.win_request_filter_gen = filter_gen;
    }

    if (d.column_count == 0 or clamped == 0)
        return .{ .first_row = first_row, .row_count = 0 };

    // While filtered, first_row/row_count are FILTERED coordinates and rows
    // are served by counting into the filter's per-block counters + a bounded
    // in-block re-lex — see FILTERED VIEWS. The BOUNDED RECORD 1 pinned-row-0
    // special case below is an identity-view-only edge case.
    if (filtered) return windowSetFiltered(d, first_row, clamped);

    // BOUNDED RECORD 1 (requirement 9): when record 1 is ALSO data row 0
    // (header off) and never terminated within the O(head) budget, its
    // bounded decode was pinned at open (see buildShape) because the
    // frontier never claims a row whose true extent past the budget is
    // unknown. Served directly here so row 0 stays instantly available,
    // independent of the frontier/checkpoint machinery below.
    if (d.win_rows == 0 and first_row == 0 and d.record1_capped and !d.has_header and d.row0_pinned_refs.len > 0) {
        const buf_mark = d.win_buf.items.len;
        const refs_mark = d.win_refs.items.len;
        for (d.row0_pinned_refs) |ref| {
            const start = d.win_buf.items.len;
            d.win_buf.appendSlice(d.gpa, d.row0_pinned_buf[ref.start .. ref.start + ref.len]) catch {
                d.win_buf.items.len = buf_mark;
                d.win_refs.items.len = refs_mark;
                return .{ .first_row = first_row, .row_count = 0 };
            };
            d.win_refs.append(d.gpa, .{ .start = start, .len = ref.len, .truncated = ref.truncated }) catch {
                d.win_buf.items.len = buf_mark;
                d.win_refs.items.len = refs_mark;
                return .{ .first_row = first_row, .row_count = 0 };
            };
        }
        if (appendRowMetadata(d, 0, d.reader.start(d.source), true, buf_mark, refs_mark)) d.win_rows = 1;
    }
    if (d.win_rows >= clamped) return .{ .first_row = first_row, .row_count = d.win_rows };

    const next_row = first_row +| d.win_rows;
    if (!d.win_cursor_valid) {
        d.lock();
        const avail_end = if (d.complete) d.total_rows else d.frontier_rows;
        if (next_row < avail_end) {
            const cp = nav.bestCheckpoint(d, next_row);
            d.win_cursor_pos = cp.pos;
            d.win_cursor_row = cp.row;
            d.win_cursor_valid = true;
        }
        d.unlock();
        if (!d.win_cursor_valid) return .{ .first_row = first_row, .row_count = d.win_rows };
    }

    // First spend from the same aggregate meter locating the requested row.
    while (d.win_cursor_row < next_row) {
        const left = remainingBudget(d);
        if (left == 0) return .{ .first_row = first_row, .row_count = d.win_rows };
        const pos = d.win_cursor_pos;
        const limit = d.reader.posAtByteBudget(d.source, pos, left);
        const b = d.reader.boundsAfter(d.source, pos, limit);
        charge(d, pos, b.next);
        if (b.capped) return .{ .first_row = first_row, .row_count = d.win_rows };
        d.win_cursor_pos = b.next;
        d.win_cursor_row += 1;
    }

    while (d.win_rows < clamped) {
        d.lock();
        const avail_end = if (d.complete) d.total_rows else d.frontier_rows;
        d.unlock();
        if (d.win_cursor_row >= avail_end) break;

        const left = remainingBudget(d);
        if (left == 0) break;
        const allowance = @min(left, @as(u64, api.window_row_scan_max_bytes));
        const pos = d.win_cursor_pos;
        const row_limit = d.reader.posAtByteBudget(d.source, pos, allowance);
        const buf_mark = d.win_buf.items.len;
        const refs_mark = d.win_refs.items.len;
        const res = d.reader.materialize(d.source, pos, d.column_count, api.cell_max_bytes, row_limit, &d.win_buf, &d.win_refs, d.gpa) catch break;
        charge(d, pos, res.next);
        if (res.capped and allowance < api.window_row_scan_max_bytes) {
            d.win_buf.items.len = buf_mark;
            d.win_refs.items.len = refs_mark;
            break;
        }
        if (!appendRowMetadata(d, d.win_cursor_row, pos, res.capped, buf_mark, refs_mark)) break;
        d.win_rows += 1;
        d.win_cursor_row += 1;
        if (!res.capped) {
            d.win_cursor_pos = res.next;
        } else {
            d.lock();
            const cp = nav.bestCheckpoint(d, d.win_cursor_row);
            d.unlock();
            d.win_cursor_pos = cp.pos;
            d.win_cursor_row = cp.row;
        }
    }
    return .{ .first_row = first_row, .row_count = d.win_rows };
}

/// ls_window_set while a filter is active: `first_row`/`clamped` are FILTERED
/// coordinates (row i = the i-th matching data row). Locates the source
/// row/position of filtered index `first_row` via the filter's per-block
/// counters (O(checkpoints) + a bounded in-block re-lex — never O(matches)),
/// then walks forward, testing candidate rows to serve up to `clamped`
/// consecutive filtered rows.
///
/// ARCH-huge-row-filtered: the per-candidate TEST lex is bounded to
/// `api.window_row_scan_max_bytes` SOURCE bytes, exactly like windowSet's
/// identity path above. A candidate whose terminator isn't found within the
/// cap is OVERSIZED, and its FULL-cell match is NEVER re-decided here — that
/// would mean either deciding on a bounded prefix (wrong: could drop a row
/// that only matches in its tail) or re-lexing to its true end (the hang this
/// bounds) — it is instead taken from `d.filter_oversized_matches`, the
/// record the background filter-scan already staged for every oversized row
/// it crossed (see filter.filterScanChunk / base.OversizedMatch). A matching
/// oversized row is served as a bounded PREFIX (display-capped cells,
/// `ls_row_oversized` true), same as the identity huge-row path; either way
/// (matched or not) the walk advances past it via the checkpoint the
/// frontier drops immediately after it (ARCH-huge-row-budget decision 2),
/// never by re-scanning its remaining bytes. Holds the mutex for the whole
/// call (bounded: O(checkpoints) + O(budget) re-lex) — simpler and still safe
/// on the caller/UI thread; see api/lesssheet.h FILTERED VIEWS.
fn windowSetFiltered(d: *Document, first_row: u64, clamped: u64) api.RowRange {
    d.lock();
    defer d.unlock();
    const fctx = filter.filterCtx(d);
    if (d.win_rows >= clamped) return .{ .first_row = first_row, .row_count = d.win_rows };

    if (!d.win_cursor_valid) {
        if (first_row >= d.filter_total) return .{ .first_row = first_row, .row_count = d.win_rows };
        var cum: u64 = 0;
        var b: usize = 0;
        while (b < d.filter_block_counts.items.len) : (b += 1) {
            const count = d.filter_block_counts.items[b];
            if (cum + count > first_row) break;
            cum += count;
        }
        if (b >= d.filter_block_counts.items.len or b >= d.checkpoints.items.len)
            return .{ .first_row = first_row, .row_count = d.win_rows };
        const cp = d.checkpoints.items[b];
        d.win_cursor_pos = cp.pos;
        d.win_cursor_row = cp.row;
        d.win_cursor_valid = true;
        d.win_filter_locating = true;
        d.win_filter_skip = first_row - cum;
    }

    while (d.win_rows < clamped and d.win_cursor_row < d.filter_rows and !d.reader.atEnd(d.source, d.win_cursor_pos)) {
        if (!d.win_candidate_tested) {
            const left = remainingBudget(d);
            if (left == 0) break;
            const allowance = @min(left, @as(u64, api.window_row_scan_max_bytes));
            const pos = d.win_cursor_pos;
            const row_limit = d.reader.posAtByteBudget(d.source, pos, allowance);
            d.nav_scratch.clearRetainingCapacity();
            d.nav_refs.clearRetainingCapacity();
            const test_res = d.reader.materialize(d.source, pos, d.column_count, null, row_limit, &d.nav_scratch, &d.nav_refs, d.gpa) catch break;
            charge(d, pos, test_res.next);
            if (test_res.capped and allowance < api.window_row_scan_max_bytes) break;

            d.win_candidate_tested = true;
            d.win_candidate_capped = test_res.capped;
            d.win_candidate_matched = if (test_res.capped)
                nav.oversizedMatch(d.filter_oversized_matches.items, d.win_cursor_row) orelse false
            else
                matcher.matchRecord(fctx, d.nav_scratch.items, d.nav_refs.items) != null;
            if (test_res.capped) {
                const cp = nav.bestCheckpoint(d, d.win_cursor_row + 1);
                d.win_candidate_next_pos = cp.pos;
                d.win_candidate_next_row = cp.row;
            } else {
                d.win_candidate_next_pos = test_res.next;
                d.win_candidate_next_row = d.win_cursor_row + 1;
            }
        }

        if (d.win_filter_locating) {
            if (d.win_candidate_matched) {
                if (d.win_filter_skip == 0) {
                    d.win_filter_locating = false;
                } else {
                    d.win_filter_skip -= 1;
                }
            }
            if (d.win_filter_locating) {
                d.win_cursor_pos = d.win_candidate_next_pos;
                d.win_cursor_row = d.win_candidate_next_row;
                d.win_candidate_tested = false;
                continue;
            }
        }

        if (!d.win_candidate_matched) {
            d.win_cursor_pos = d.win_candidate_next_pos;
            d.win_cursor_row = d.win_candidate_next_row;
            d.win_candidate_tested = false;
            continue;
        }

        // A matching filtered row is visited a second time for display. If
        // the aggregate limit cuts this pass, retain the completed test
        // decision and retry only the display operation next call.
        const left = remainingBudget(d);
        if (left == 0) break;
        const allowance = @min(left, @as(u64, api.window_row_scan_max_bytes));
        const pos = d.win_cursor_pos;
        const row_limit = d.reader.posAtByteBudget(d.source, pos, allowance);
        const buf_mark = d.win_buf.items.len;
        const refs_mark = d.win_refs.items.len;
        const display_res = d.reader.materialize(d.source, pos, d.column_count, api.cell_max_bytes, row_limit, &d.win_buf, &d.win_refs, d.gpa) catch break;
        charge(d, pos, display_res.next);
        if (display_res.capped and allowance < api.window_row_scan_max_bytes) {
            d.win_buf.items.len = buf_mark;
            d.win_refs.items.len = refs_mark;
            break;
        }
        if (!appendRowMetadata(d, d.win_cursor_row, pos, d.win_candidate_capped, buf_mark, refs_mark)) break;
        d.win_rows += 1;
        d.win_cursor_pos = d.win_candidate_next_pos;
        d.win_cursor_row = d.win_candidate_next_row;
        d.win_candidate_tested = false;
    }
    return .{ .first_row = first_row, .row_count = d.win_rows };
}

/// See api/lesssheet.h `ls_cell`. Zero allocation; total function.
pub fn cell(d: *const Document, row: u64, col: u32) api.Str {
    if (col >= d.column_count) return empty_str;
    if (row < d.win_first or row >= d.win_first + d.win_rows) return empty_str;
    const idx = (row - d.win_first) * d.column_count + col;
    if (idx >= d.win_refs.items.len) return empty_str;
    const ref = d.win_refs.items[@intCast(idx)];
    if (ref.len == 0) return empty_str;
    return .{ .ptr = d.win_buf.items.ptr + ref.start, .len = ref.len };
}

/// See api/lesssheet.h `ls_window_match_flags` (MATCH-FLAGS EXTENSION,
/// thin-frontend-shared-core Phase 1). ONE flag byte per cell (1 = matches the
/// ACTIVE search request, 0 = not) over the materialized window's rows x the
/// requested column range [first_col, first_col + col_count), row-major with
/// stride col_count and len == win_rows * col_count. The per-cell verdict is
/// `matcher.cellMatches` — the SAME decision `matchRecord` (and thus ls_search_*)
/// is composed from — evaluated over the cell bytes AS MATERIALIZED IN THE
/// WINDOW (win_buf/win_refs, the display-capped bytes `cell` above serves), so
/// the flags are byte-identical to the core's matcher and never re-derive the
/// grammar. Empty ls_str when: the column range is empty / out of bounds
/// (col_count == 0, first_col >= column_count, or the range spills past it),
/// or the search is IDLE (no highlights). NEVER scans; ZERO heap allocation
/// beyond the one reused, memoized buffer; never fails.
///
/// MEMOIZED & BORROWED like `cell`: the buffer (`d.mf_flags`) is recomputed
/// lazily only when the window epoch (`win_gen`), the search (`search_gen`), or
/// the requested column range changed since the last compute; otherwise the
/// same bytes are returned with no further work. The returned pointer stays
/// valid until the next windowSet (which bumps win_gen) / ls_close (freeDoc).
/// The whole read is done under `d.lock()` so the request buffers docCtx
/// borrows (search_value / scope_mask / failure) can't be freed by a concurrent
/// ls_search_start mid-compute; win_buf/win_refs are window-lane state the
/// caller already serializes with this call.
pub fn matchFlags(d: *Document, first_col: u32, col_count: u32) api.Str {
    // Empty / out-of-range column range -> empty ls_str (never fails). Widen to
    // u64 so first_col + col_count can't wrap.
    if (col_count == 0 or first_col >= d.column_count or
        @as(u64, first_col) + @as(u64, col_count) > d.column_count)
        return empty_str;

    d.lock();
    defer d.unlock();

    // IDLE (no search since open, or after a reset) -> no highlights.
    if (d.search_state == .idle) return empty_str;
    const search_gen = d.search_gen;

    const total: usize = @intCast(d.win_rows * @as(u64, col_count));

    // Memo hit: same window epoch, same search, same requested range.
    if (!(d.mf_valid and d.mf_win_gen == d.win_gen and d.mf_search_gen == search_gen and
        d.mf_first_col == first_col and d.mf_col_count == col_count))
    {
        d.mf_valid = false; // invalid until fully recomputed (an OOM leaves it so)
        d.mf_flags.clearRetainingCapacity();
        d.mf_flags.ensureTotalCapacity(d.gpa, total) catch return empty_str;
        d.mf_flags.items.len = total;

        const ctx = search.docCtx(d);
        var wr: u64 = 0;
        while (wr < d.win_rows) : (wr += 1) {
            var c: u32 = 0;
            while (c < col_count) : (c += 1) {
                const col = first_col + c;
                const src_idx = wr * d.column_count + col;
                var verdict: u8 = 0;
                if (src_idx < d.win_refs.items.len) {
                    const ref = d.win_refs.items[@intCast(src_idx)];
                    if (matcher.cellMatches(ctx, col, d.win_buf.items[ref.start .. ref.start + ref.len]))
                        verdict = 1;
                }
                d.mf_flags.items[@intCast(wr * @as(u64, col_count) + c)] = verdict;
            }
        }

        d.mf_valid = true;
        d.mf_win_gen = d.win_gen;
        d.mf_search_gen = search_gen;
        d.mf_first_col = first_col;
        d.mf_col_count = col_count;
    }

    if (d.mf_flags.items.len == 0) return empty_str;
    return .{ .ptr = d.mf_flags.items.ptr, .len = d.mf_flags.items.len };
}

/// See api/lesssheet.h `ls_header_cell`. Zero allocation; total function.
pub fn headerCell(d: *const Document, col: u32) api.Str {
    if (!d.has_header or col >= d.column_count or col >= d.header_refs.len) return empty_str;
    const ref = d.header_refs[col];
    if (ref.len == 0) return empty_str;
    return .{ .ptr = d.header_buf.ptr + ref.start, .len = ref.len };
}

/// See api/lesssheet.h `ls_cell_truncated`. Same (row, col) domain and
/// window/borrow rules as ls_cell; reports whether the LS_CELL_MAX_BYTES
/// display cap cut the served cell (set alongside the cell's CellRef by
/// the Reader's `materialize`). Zero allocation; total function; never fails.
pub fn cellTruncated(d: *const Document, row: u64, col: u32) bool {
    if (col >= d.column_count) return false;
    if (row < d.win_first or row >= d.win_first + d.win_rows) return false;
    const idx = (row - d.win_first) * d.column_count + col;
    if (idx >= d.win_refs.items.len) return false;
    return d.win_refs.items[@intCast(idx)].truncated;
}

/// See api/lesssheet.h `ls_header_cell_truncated`. Same semantics as
/// ls_cell_truncated for the effective header record. Zero allocation; total
/// function; never fails.
pub fn headerCellTruncated(d: *const Document, col: u32) bool {
    if (!d.has_header or col >= d.column_count or col >= d.header_refs.len) return false;
    return d.header_refs[col].truncated;
}

/// See api/lesssheet.h `ls_source_row`. Same window/borrow domain as ls_cell
/// (win_source[i] is populated by ls_window_set alongside win_refs). Total
/// function; ZERO allocation; never fails; never scans.
pub fn sourceRow(d: *const Document, row: u64) u64 {
    if (row < d.win_first or row >= d.win_first + d.win_rows) return api.no_row;
    const idx: usize = @intCast(row - d.win_first);
    if (idx >= d.win_source.items.len) return api.no_row;
    return d.win_source.items[idx];
}

/// See api/lesssheet.h `ls_row_oversized`. Same window/borrow domain as ls_cell
/// / sourceRow (win_oversized[i] is populated by ls_window_set alongside
/// win_refs/win_source — ARCH-huge-row-budget / ARCH-huge-row-filtered).
/// Populated identically in either view: windowSet (identity) appends one
/// entry per materialized row, and windowSetFiltered (FILTERED VIEWS) does
/// too — including for a giant matching row served as a bounded prefix (true)
/// — so this reports the real per-row signal in both coordinate spaces.
/// Total function; ZERO allocation; never fails; never scans.
pub fn rowOversized(d: *const Document, row: u64) bool {
    if (row < d.win_first or row >= d.win_first + d.win_rows) return false;
    const idx: usize = @intCast(row - d.win_first);
    if (idx >= d.win_oversized.items.len) return false;
    return d.win_oversized.items[idx];
}

/// ARCH-stream-copy FR3: a forward gap beyond this many rows is "implausibly
/// large vs a checkpoint seek": a FRESH checkpoint lookup is bounded to ~one
/// checkpoint interval, so beyond this gap re-anchoring there is guaranteed
/// at least as cheap as stepping the cursor forward row-by-row — re-anchor
/// instead (never slower than today, for any access pattern). Reuses the
/// existing checkpoint spacing constant verbatim; NOT a new runtime tunable
/// (the planner rejected a per-document interval knob — see the hand-off).
const copy_reanchor_gap_max: u64 = base.checkpoint_interval;

/// ARCH-stream-copy FR1/FR3 (identity): the intended monotonic access
/// pattern (TSVCopyBuilder: row-major, so consecutive `cellCopy` calls have
/// `row - copy_cursor_row` == 0 -- another column of the same row -- or 1 --
/// the next row) is trusted to use the cursor UNCONDITIONALLY, without
/// comparing it to a fresh checkpoint: a checkpoint can beat it by at most
/// the single row it would otherwise step, so this keeps the well-known
/// exact "N-1 advances for an N-row row-major sweep" cost (sc3) — no "free"
/// checkpoint-aligned shortcuts. A LARGER gap is never produced by that
/// pattern, so it is NOT trusted blindly (Claude review finding A) — see
/// `cellCopy`, which compares it against a fresh `bestCheckpoint(row)` and
/// uses whichever starts closer, for a PROVABLE never-slower-than-today
/// guarantee on any gap, not just a small one.
const copy_cursor_trust_gap_max: u64 = 1;

/// TODAY'S locate-from-scratch skip: from (`from_row`,`from_pos`) — a
/// checkpoint obtained fresh for the FINAL target `row` — up to `row`,
/// counting one source-row-advance per step into `d.copy_advances` (via
/// `advances`). Used both as the cursor-OFF reference/baseline (AC1/AC3/AC5)
/// and as the cursor's own re-anchor fallback (FR3): SAFE by construction —
/// an unbounded `boundsAfter` here never actually crosses an oversized row's
/// bytes, because a FRESH `nav.bestCheckpoint(row)` never has an oversized
/// row strictly between `from_row` and `row` (its maximality guarantees any
/// oversized row in range would itself have produced a closer/bigger
/// checkpoint) — identical reasoning to windowSet's own skip loop.
fn skipFromCheckpoint(d: *Document, from_row: u64, from_pos: Pos, row: u64, advances: *u64) Pos {
    var pos = from_pos;
    var r = from_row;
    while (r < row) : (r += 1) {
        pos = d.reader.boundsAfter(d.source, pos, null).next;
        advances.* += 1;
    }
    return pos;
}

/// ARCH-stream-copy FR1: resume the identity copy cursor forward from
/// (`from_row`,`from_pos`) up to `row`, counting one source-row-advance per
/// step. Unlike `skipFromCheckpoint`, `from_row` is a STALE position (not
/// freshly anchored against `row`), so it may itself sit on an oversized row:
/// each step is bounded to the per-row window-scan cap and, when capped
/// (oversized), skips forward via the checkpoint the frontier already
/// dropped immediately after it (ARCH-huge-row-budget decision 2) instead of
/// re-scanning its remaining bytes — never crossing an oversized row's
/// bytes, exactly like windowSet's own oversized recovery. `row == from_row`
/// runs zero iterations: the "another column of the same row" case costs
/// zero advances.
fn advanceCursorForward(d: *Document, from_row: u64, from_pos: Pos, row: u64, advances: *u64) Pos {
    var pos = from_pos;
    var r = from_row;
    while (r < row) {
        const row_limit = d.reader.posAtByteBudget(d.source, pos, api.window_row_scan_max_bytes);
        const b = d.reader.boundsAfter(d.source, pos, row_limit);
        advances.* += 1;
        if (!b.capped) {
            pos = b.next;
            r += 1;
            continue;
        }
        d.lock();
        const skip_cp = nav.bestCheckpoint(d, r + 1);
        d.unlock();
        pos = skip_cp.pos;
        r = skip_cp.row;
    }
    return pos;
}

/// See api/lesssheet.h `ls_cell_copy`: the bounded, window-INDEPENDENT,
/// LOSSLESS full-cell read. Poll/control lane: never touches or evicts the
/// materialized window (win_buf/win_refs/win_first/win_rows are untouched
/// throughout — the read COPIES into the caller's buffer, so its output is
/// unaffected by a later ls_window_set, on any thread — the cc4 no-borrow
/// test pins this) and never scans or advances the frontier.
///
///   * NO_CELL when `d.column_count == 0` or `col >= d.column_count`
///     (checked first, independent of `row`); else `row` at/beyond an EXACT
///     end (identity: `row >= d.total_rows` while `d.complete`; filtered:
///     `row >= d.filter_total` while `d.filter_state == .done` — see
///     `cellCopyFiltered`).
///   * Located WITHOUT scanning: the pinned bounded record-1 row 0
///     (`record1_capped && !has_header`, identity view only — see
///     `windowSet`'s identical special case) sits at position `data_start`
///     directly, bypassing the frontier AND the cursor (which never claims a
///     row whose extent past the O(head) budget is unknown — that row is
///     pathologically "oversized" from its very first byte, so
///     `decodeCellAt` below naturally bounds it exactly like any other
///     oversized row). A filtered view defers entirely to
///     `cellCopyFiltered`. Otherwise (ARCH-stream-copy): when the forward
///     COPY CURSOR (`d.copy_cursor_*` on `Document`) is enabled, tagged for
///     THIS view + filter generation, and `row` is at/ahead of it by a
///     plausible gap, `advanceCursorForward` resumes from the cursor's last
///     position — zero checkpoint lookups, zero advances for another column
///     of the same row. Otherwise `nav.bestCheckpoint` (by value, under
///     `d.lock()`) plus `skipFromCheckpoint` locate `row` exactly like
///     today — never crosses an oversized row's bytes, for the same reason:
///     `row < avail_end` guarantees any oversized row before it was already
///     scanned, so `bestCheckpoint` already lands past it. This is both the
///     cursor-OFF REFERENCE (AC1) and the cursor's own re-anchor fallback
///     (FR3) — byte-identical either way, only the locate cost differs. A
///     `row` at/beyond the frontier (and not pinned) is PENDING: its
///     position isn't known yet.
///   * `decodeCellAt` (below) then decodes ONLY column `col` from that
///     position — never the rest of the row — bounded to the SAME per-row
///     SOURCE cap `windowSet` uses (`api.window_row_scan_max_bytes`) and to
///     the caller's `buf_len` OUTPUT cap (the Reader's `cell` op). Always
///     `.ok` once a row is located: a located row always has a well-defined
///     (possibly empty or bounded) cell. ZERO heap allocation on this path
///     (`Reader.cell`); the filtered path's use of the shared `nav_scratch`
///     re-lex scratch is the one exception, mirroring `windowSetFiltered`.
/// ARCH-security-hardening (g) AC-g1 — the SOURCE-FAULT GUARD bracket for the
/// copy cursor, which re-lexes source bytes of its own and so could otherwise put
/// the guard's zero-fill on the user's CLIPBOARD.
///
/// Deliberately NOT wrapped around `cellCopy` itself: the streaming job calls that
/// once per CELL, and two atomic loads per cell is a measurable tax on a
/// million-row copy (+3.5% on the 50/500 MB plain-CSV `copy_rows` bench). The
/// guard's granularity is the OPERATION, so root.zig brackets its two ABI entry
/// points — `ls_cell_copy` (one cell) and `ls_copy_next` (one bufferful) — with
/// this instead. Returns true when a fault landed inside the bracket, having
/// already reported the terminal outcome; the caller then serves nothing.
pub fn copyFaulted(d: *Document, faults_before: u32) bool {
    if (base.sourceFaultCount(d) == faults_before) return false;
    d.lock();
    base.reportSourceFaultLocked(d);
    d.unlock();
    return true;
}

pub fn cellCopy(d: *Document, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult {
    out_len.* = 0;
    out_truncated.* = false;
    if (d.column_count == 0 or col >= d.column_count) return .no_cell;

    // FILTER DISPATCH UNDER THE LOCK. `filter_state` is mutated by `ls_filter_set`
    // on another thread, so reading it here unsynchronized was both a data race and
    // a TOCTOU: a filter landing between the read and the work would serve an
    // IDENTITY row index as a FILTERED coordinate (or the reverse) — the wrong cell,
    // reported `.ok`. ONE acquisition now covers the decision AND the work it
    // selects, which is why the filtered path is `*Locked`.
    d.lock();
    if (d.filter_state != .idle) {
        defer d.unlock();
        return cellCopyFilteredLocked(d, row, col, buf, buf_len, out_len, out_truncated);
    }

    // BOUNDED RECORD 1 (identity view only — mirrors windowSet's pinned-row-0
    // branch): row 0's true extent runs past the O(head) budget, and
    // therefore past the (far smaller) window scan cap too, so it is served
    // exactly like any other oversized row, from `data_start`, bypassing the
    // frontier AND the cursor entirely. Reads only open-time immutable facts, so
    // it hands the lock back first (`decodeCellAt` never needed it).
    if (row == 0 and d.record1_capped and !d.has_header and d.row0_pinned_refs.len > 0) {
        d.unlock();
        return decodeCellAt(d, d.data_start, col, buf, buf_len, out_len, out_truncated);
    }

    const avail_end = if (d.complete) d.total_rows else d.frontier_rows;
    if (row >= avail_end) {
        const exact = d.complete;
        d.unlock();
        return if (exact) .no_cell else .pending;
    }

    // ARCH-stream-copy FR1/FR3 (see copy_cursor_trust_gap_max's comment): the
    // cursor applies when it's enabled, tagged for THIS view + filter
    // generation, and forward of `row`. Within the intended monotonic gap
    // (<=1) it is trusted unconditionally (no checkpoint lookup at all,
    // preserving the exact row-major N-1 cost). Beyond that, a fresh
    // `bestCheckpoint(row)` is compared: the cursor is used only if it
    // starts at/after the checkpoint (`copy_cursor_row >= cp.row`), so
    // `row - copy_cursor_row <= row - cp.row` — provably never costlier than
    // today's from-scratch locate, for ANY forward gap (Claude review finding
    // A: e.g. a cursor at row 100 asked for row 2048, where the checkpoint
    // alone reaches row 2048 in zero steps).
    const cursor_forward = d.copy_cursor_enabled and d.copy_cursor_valid and
        d.copy_cursor_view == .identity and d.copy_cursor_gen == d.filter_gen and
        row >= d.copy_cursor_row;
    var use_cursor = cursor_forward and (row - d.copy_cursor_row) <= copy_cursor_trust_gap_max;
    var from_row: u64 = undefined;
    var from_pos: Pos = undefined;
    if (use_cursor) {
        from_row = d.copy_cursor_row;
        from_pos = d.copy_cursor_pos;
    } else {
        const cp = nav.bestCheckpoint(d, row);
        if (cursor_forward and d.copy_cursor_row >= cp.row) {
            use_cursor = true;
            from_row = d.copy_cursor_row;
            from_pos = d.copy_cursor_pos;
        } else {
            from_row = cp.row;
            from_pos = cp.pos;
        }
    }
    d.unlock();

    var advances: u64 = 0;
    const pos = if (use_cursor)
        advanceCursorForward(d, from_row, from_pos, row, &advances)
    else
        skipFromCheckpoint(d, from_row, from_pos, row, &advances);

    d.lock();
    d.copy_advances += advances;
    if (d.copy_cursor_enabled) {
        // Thread-safety (see base.Document's cursor field comment): the lock
        // was dropped across the walk above, so if we EXTENDED an existing
        // cursor (`use_cursor`), a concurrent identity copy could have
        // already committed a further-along one in the meantime -- guard
        // against regressing it (only relevant when `use_cursor`, since
        // that's the only path that trusted/extended a value read before
        // the drop). A fresh RE-ANCHOR (`!use_cursor`: cold start, backward,
        // cross-view/generation, or an implausible gap) is never "extending"
        // anything, so it always commits unconditionally -- including over a
        // stale value left by a wholly separate, already-finished sweep
        // (e.g. a brand-new sweep restarting at row 0 after a previous one
        // ended at the last row). Either way this never changes the bytes
        // THIS call returns (`pos` above is already fixed) -- only whether a
        // LATER call gets to reuse it.
        const stale = use_cursor and d.copy_cursor_valid and d.copy_cursor_view == .identity and
            d.copy_cursor_gen == d.filter_gen and d.copy_cursor_row > row;
        if (!stale) {
            d.copy_cursor_valid = true;
            d.copy_cursor_view = .identity;
            d.copy_cursor_gen = d.filter_gen;
            d.copy_cursor_row = row;
            d.copy_cursor_pos = pos;
        }
    }
    d.unlock();

    return decodeCellAt(d, pos, col, buf, buf_len, out_len, out_truncated);
}

/// `ls_cell_copy` while a filter is active (FILTERED VIEWS): locate FILTERED
/// index `row`'s ORIGINAL row/position then decode column `col` from there,
/// exactly like the identity path. ARCH-stream-copy FR2/FR3: when the
/// forward copy cursor is enabled, tagged `.filtered` for the ACTIVE filter
/// generation, `row` sits at/ahead of it by a plausible gap, AND a plain
/// `filter_block_counts` lookup (O(1), no re-lex) proves the target still
/// falls within the cursor's OWN block, `nav.nthMatchForwardFrom` resumes the
/// match-walk from the cursor's last match — provably no costlier than a
/// fresh locate for the same row (it starts further along, inside the SAME
/// block a cold locate would relex from its start), so this is NEVER a
/// forward-attempt-plus-cold-locate double pay, for ANY match distribution
/// (Claude review finding 2: a clustered/sparse filter must not cost more
/// than the baseline). Zero advances for another column of the same filtered
/// row. Otherwise (no usable cursor, OR the target spills past the cursor's
/// block — decided WITHOUT ever starting a doomed row-walk)
/// `nav.nthMatchLocationCounted` — O(checkpoints) + a bounded in-block
/// re-lex, the same machinery `windowSetFiltered` uses — is both the
/// cursor-OFF reference (AC2) and the re-anchor fallback (FR3). Runs with the
/// Document mutex HELD by `cellCopy` for the whole call (bounded either way),
/// mirroring `windowSetFiltered` — the caller acquires it BEFORE deciding this is
/// the filtered path, so the decision and the work cannot straddle an
/// `ls_filter_set`.
fn cellCopyFilteredLocked(d: *Document, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult {
    if (row >= d.filter_total) return if (d.filter_state == .done) .no_cell else .pending;
    const fctx = filter.filterCtx(d);

    const use_cursor = d.copy_cursor_enabled and d.copy_cursor_valid and
        d.copy_cursor_view == .filtered and d.copy_cursor_gen == d.filter_gen and
        row >= d.copy_cursor_row and (row - d.copy_cursor_row) <= copy_reanchor_gap_max;

    var advances: u64 = 0;
    var pos: Pos = undefined;
    var source_row: u64 = undefined;
    var block_consumed: u64 = undefined;
    var resolved = false;

    if (use_cursor and row == d.copy_cursor_row) {
        // Another column of the same filtered row: zero advances.
        pos = d.copy_cursor_pos;
        source_row = d.copy_cursor_source_row;
        block_consumed = d.copy_cursor_block_consumed;
        resolved = true;
    } else if (use_cursor) {
        // Cheap (O(1), no re-lex) proof that the forward walk cannot run
        // past the end of `copy_cursor_source_row`'s own block: only then is
        // it guaranteed no costlier than a fresh locate (see
        // nthMatchForwardFrom's doc comment). If the remaining match count in
        // this block can't cover `gap`, the row-walk is skipped ENTIRELY —
        // any partial attempt here would be pure waste.
        const gap = row - d.copy_cursor_row;
        const from_block = d.copy_cursor_source_row / base.checkpoint_interval;
        const block_total = if (from_block < d.filter_block_counts.items.len) d.filter_block_counts.items[@intCast(from_block)] else 0;
        const remaining = block_total -| d.copy_cursor_block_consumed;
        if (gap <= remaining) {
            const block_hi = @min(d.filter_rows, (from_block + 1) * base.checkpoint_interval);
            if (nav.nthMatchForwardFrom(d, fctx, block_hi, d.copy_cursor_source_row, d.copy_cursor_pos, gap, &advances)) |loc| {
                pos = loc.pos;
                source_row = loc.row;
                block_consumed = d.copy_cursor_block_consumed + gap;
                resolved = true;
            }
            // else: the block-count proof said this should have been found;
            // treat as defensive-unreachable and fall through to the cold
            // locate below (never a wrong NO_CELL).
        } else {
            // Target spills past the cursor's block: RESUME the cross-block
            // cumulative scan from `from_block` (Claude review finding B)
            // instead of re-walking `filter_block_counts` from block 0 --
            // otherwise a monotonic sparse-filter sweep (~1 match/block) pays
            // O(blocks) EVERY step it crosses a block, O(blocks x matches)
            // total. `cum_before` (matches counted in blocks [0, from_block))
            // is derived in O(1) from already-known cursor state: the
            // cursor's 1-based total position (`copy_cursor_row + 1`) minus
            // its 1-based position WITHIN its own block
            // (`copy_cursor_block_consumed`).
            const cum_before = (d.copy_cursor_row + 1) -| d.copy_cursor_block_consumed;
            if (nav.nthMatchLocationCounted(d, d.filter_block_counts.items, fctx, d.filter_rows, row, from_block, cum_before, &advances)) |loc| {
                pos = loc.pos;
                source_row = loc.row;
                block_consumed = loc.block_consumed;
                resolved = true;
            }
            // else: defensive-unreachable (see below) -- falls through to
            // the true cold locate from block 0.
        }
    }

    if (!resolved) {
        const loc = nav.nthMatchLocationCounted(d, d.filter_block_counts.items, fctx, d.filter_rows, row, 0, 0, &advances) orelse {
            // Defensive only: `row < filter_total` guarantees the counted
            // region has this many matches already, so this should be
            // unreachable; if it ever triggers, retrying would not change
            // the outcome.
            return .no_cell;
        };
        pos = loc.pos;
        source_row = loc.row;
        block_consumed = loc.block_consumed;
    }

    d.copy_advances += advances;
    if (d.copy_cursor_enabled) {
        // No forward-only guard needed here (contrast cellCopy): this whole
        // function holds the lock throughout, so concurrent filtered copies
        // are already fully serialized — never an interleaved stale commit.
        d.copy_cursor_valid = true;
        d.copy_cursor_view = .filtered;
        d.copy_cursor_gen = d.filter_gen;
        d.copy_cursor_row = row;
        d.copy_cursor_pos = pos;
        d.copy_cursor_source_row = source_row;
        d.copy_cursor_block_consumed = block_consumed;
    }

    return decodeCellAt(d, pos, col, buf, buf_len, out_len, out_truncated);
}

/// Decode column `col` of the row starting at position `pos`, bounded to
/// `api.window_row_scan_max_bytes` SOURCE bytes (the SAME per-row cap
/// `windowSet` uses) and to `buf_len` OUTPUT bytes (the Reader's `cell` op).
/// Always `.ok`: a located row always has a well-defined (possibly empty or
/// bounded-prefix) cell.
fn decodeCellAt(d: *Document, pos: Pos, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult {
    const row_limit = d.reader.posAtByteBudget(d.source, pos, api.window_row_scan_max_bytes);
    const res = d.reader.cell(d.source, pos, col, row_limit, buf, buf_len);
    out_len.* = res.len;
    out_truncated.* = res.truncated;
    // security-hardening (f): neutralize a formula-injection lead byte on the
    // COPY output only. This is THE single choke point for every copy path
    // (identity / filtered / pinned-record-1, and the streaming ls_copy_next
    // sweep via readCell -> window.cellCopy), so it applies once, uniformly,
    // and BEFORE any TSV framing/quoting. Display (ls_cell) and search/filter
    // never reach here, so they keep the RAW bytes (sec_f3 scope guard).
    neutralizeCopyCell(buf, buf_len, out_len, out_truncated);
    return .ok;
}

/// security-hardening (f) AC-f1: the NUMBER-AWARE copy formula-injection
/// decision (single source of truth; every copy path shares it). Keyed on the
/// COPIED cell value's first byte:
///   - `=` (0x3D) / `@` (0x40): ALWAYS neutralized.
///   - `+` (0x2B) / `-` (0x2D): neutralized ONLY when the value is NOT a plain
///     number (`isPlainNumber` below) — a plain number like `-3` / `+2.5` is
///     inert text, not an injection vector, so it copies RAW.
///   - anything else (incl. a leading `'`, so re-copying never doubles): never.
/// A display-TRUNCATED value can never be confirmed a plain number (its tail is
/// not in the buffer), so a truncated `+`/`-` value neutralizes — the fail-safe
/// direction is to OVER-neutralize, never under. `value` is non-empty.
fn copyCellNeutralizes(value: []const u8, truncated: bool) bool {
    return switch (value[0]) {
        '=', '@' => true,
        '+', '-' => truncated or !isPlainNumber(value),
        else => false,
    };
}

/// security-hardening (f) AC-f1: the plain-number grammar, DELIBERATELY stricter
/// than the header/matcher numeric grammar (which trims whitespace and admits a
/// bare leading/trailing `.`) — reusing that here would UNDER-neutralize `-.5` /
/// `-3.`. `value` starts with the single leading `+`/`-` (the only callers);
/// after consuming it, the ENTIRE remainder must match
///     digit+ ( '.' digit+ )? ( ('e'|'E') ('+'|'-')? digit+ )?
/// with `digit` = ASCII 0-9 and the match consuming every remaining byte (no
/// whitespace, no separators, no bare/leading/trailing dot, no trailing bytes).
fn isPlainNumber(value: []const u8) bool {
    const rest = value[1..]; // drop the single leading sign
    const n = rest.len;
    var i: usize = 0;
    // digit+ (integer part, at least one digit)
    const int_start = i;
    while (i < n and asciiDigit(rest[i])) i += 1;
    if (i == int_start) return false;
    // optional ( '.' digit+ )
    if (i < n and rest[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < n and asciiDigit(rest[i])) i += 1;
        if (i == frac_start) return false; // a dot needs >= 1 fractional digit
    }
    // optional ( ('e'|'E') ('+'|'-')? digit+ )
    if (i < n and (rest[i] == 'e' or rest[i] == 'E')) {
        i += 1;
        if (i < n and (rest[i] == '+' or rest[i] == '-')) i += 1;
        const exp_start = i;
        while (i < n and asciiDigit(rest[i])) i += 1;
        if (i == exp_start) return false; // an exponent needs >= 1 digit
    }
    return i == n; // the whole remainder was consumed
}

fn asciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Prepend a single apostrophe to `buf[0..out_len]` iff `copyCellNeutralizes`
/// (number-aware, first-byte keyed). Applied at most once; never on an empty
/// cell; the apostrophe COUNTS toward out_len. The content is shifted one byte
/// right in place; if the prefix would exceed `buf_len` the trailing byte(s) are
/// dropped at a UTF-8 code-point boundary and out_truncated is set (the streaming
/// copy path grows its scratch, so this only bites a caller's small fixed
/// ls_cell_copy buffer).
fn neutralizeCopyCell(buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) void {
    const b = buf orelse return;
    const len = out_len.*;
    if (len == 0 or buf_len == 0) return;
    if (!copyCellNeutralizes(b[0..len], out_truncated.*)) return;
    var keep = @min(len, buf_len - 1);
    // Never split a UTF-8 code point when the prefix forces a drop.
    if (keep < len) while (keep > 0 and (b[keep] & 0xC0) == 0x80) : (keep -= 1) {};
    var i = keep;
    while (i > 0) : (i -= 1) b[i] = b[i - 1];
    b[0] = '\'';
    out_len.* = keep + 1;
    if (keep < len) out_truncated.* = true;
}
