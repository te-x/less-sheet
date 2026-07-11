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

const Document = base.Document;
const Checkpoint = base.Checkpoint;
const Pos = base.Pos;

const empty_str: api.Str = .{ .ptr = "", .len = 0 };

/// See api/lesssheet.h `ls_window_set`. Never advances the frontier; re-lexes
/// the requested rows (behind the frontier) from the nearest checkpoint into
/// the owned window buffer, evicting the previous window. Every cell is
/// decoded through the Reader (the document's resolved encoding) and
/// display-capped to LS_CELL_MAX_BYTES (requirement 8). ARCH-huge-row-budget:
/// the SOURCE bytes scanned per row are ALSO bounded to
/// `api.window_row_scan_max_bytes`, so this stays O(min(row bytes, cap) x
/// rows) regardless of row size (see the materialize loop below).
pub fn windowSet(d: *Document, first_row: u64, row_count: u32) api.RowRange {
    // Evict the previous window regardless of the outcome.
    d.win_buf.clearRetainingCapacity();
    d.win_refs.clearRetainingCapacity();
    d.win_source.clearRetainingCapacity();
    d.win_oversized.clearRetainingCapacity();
    d.win_first = first_row;
    d.win_rows = 0;

    if (d.column_count == 0) return .{ .first_row = first_row, .row_count = 0 };
    const clamped: u64 = @min(@as(u64, row_count), @as(u64, api.window_max_rows));
    if (clamped == 0) return .{ .first_row = first_row, .row_count = 0 };

    // While filtered, first_row/row_count are FILTERED coordinates and rows
    // are served by counting into the filter's per-block counters + a bounded
    // in-block re-lex — see FILTERED VIEWS. The BOUNDED RECORD 1 pinned-row-0
    // special case below is an identity-view-only edge case.
    if (d.filter_state != .idle) return windowSetFiltered(d, first_row, clamped);

    // BOUNDED RECORD 1 (requirement 9): when record 1 is ALSO data row 0
    // (header off) and never terminated within the O(head) budget, its
    // bounded decode was pinned at open (see buildShape) because the
    // frontier never claims a row whose true extent past the budget is
    // unknown. Served directly here so row 0 stays instantly available,
    // independent of the frontier/checkpoint machinery below.
    var pinned_rows: u64 = 0;
    if (first_row == 0 and d.record1_capped and !d.has_header and d.row0_pinned_refs.len > 0) {
        for (d.row0_pinned_refs) |ref| {
            const start = d.win_buf.items.len;
            d.win_buf.appendSlice(d.gpa, d.row0_pinned_buf[ref.start .. ref.start + ref.len]) catch break;
            d.win_refs.append(d.gpa, .{ .start = start, .len = ref.len, .truncated = ref.truncated }) catch break;
        }
        d.win_source.append(d.gpa, 0) catch {}; // identity: row 0's source is row 0
        // Record 1 spilled past the (far larger) O(head) budget, so it also
        // exceeds the window scan cap: this pinned prefix is OVERSIZED by the
        // same "served bounded; more source exists" definition (ARCH-huge-
        // row-budget / requirement 9).
        d.win_oversized.append(d.gpa, true) catch {};
        pinned_rows = 1;
        d.win_rows = 1;
    }
    if (pinned_rows >= clamped) return .{ .first_row = first_row, .row_count = pinned_rows };

    const next_row = first_row + pinned_rows;
    const remaining = clamped - pinned_rows;

    d.lock();
    const avail_end = if (d.complete) d.total_rows else d.frontier_rows;
    var materialize: u64 = 0;
    var cp: Checkpoint = .{ .row = 0, .pos = d.data_start };
    if (next_row < avail_end) {
        materialize = @min(remaining, avail_end - next_row);
        cp = nav.bestCheckpoint(d, next_row);
    }
    d.unlock();

    if (materialize == 0) return .{ .first_row = first_row, .row_count = pinned_rows };

    // Skip from the checkpoint to next_row. This never crosses an oversized
    // row's bytes: `cp` already lands at/after the checkpoint the frontier
    // drops immediately after every oversized row it scans (ARCH-huge-row-
    // budget decision 2), and any oversized row before next_row has
    // necessarily already been scanned (next_row < avail_end).
    var pos = cp.pos;
    var r = cp.row;
    while (r < next_row) : (r += 1) {
        pos = d.reader.boundsAfter(d.source, pos, null).next;
    }

    var produced: u64 = 0;
    while (produced < materialize) {
        // Bound the SOURCE bytes scanned for this ONE row to the per-row cap:
        // a row whose terminator isn't found within it is served as a bounded
        // prefix (cells stay individually display-capped, as before) and
        // flagged oversized — this call never re-lexes a giant row's full
        // bytes.
        const row_limit = d.reader.posAtByteBudget(d.source, pos, api.window_row_scan_max_bytes);
        const res = d.reader.materialize(d.source, pos, d.column_count, api.cell_max_bytes, row_limit, &d.win_buf, &d.win_refs, d.gpa) catch break;
        d.win_source.append(d.gpa, next_row + produced) catch {}; // identity: source == physical row
        d.win_oversized.append(d.gpa, res.capped) catch {};
        produced += 1;
        if (!res.capped) {
            pos = res.next;
            continue;
        }
        if (produced >= materialize) break; // that was the last row wanted
        // Oversized: `res.next` is only the cap boundary, not the row's true
        // end — locate the next row via the checkpoint the frontier already
        // dropped right after this one (decision 2) instead of re-scanning
        // its (possibly gigabytes of) remaining bytes.
        const target_row = next_row + produced;
        d.lock();
        const skip_cp = nav.bestCheckpoint(d, target_row);
        d.unlock();
        pos = skip_cp.pos;
        var rr = skip_cp.row;
        while (rr < target_row) : (rr += 1) {
            pos = d.reader.boundsAfter(d.source, pos, null).next;
        }
    }
    d.win_rows = pinned_rows + produced;
    return .{ .first_row = first_row, .row_count = pinned_rows + produced };
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
    if (first_row >= d.filter_total) return .{ .first_row = first_row, .row_count = 0 };
    const materialize = @min(clamped, d.filter_total - first_row);
    const fctx = filter.filterCtx(d);
    const start = nav.nthMatchLocation(d, d.filter_block_counts.items, fctx, d.filter_rows, first_row) orelse
        return .{ .first_row = first_row, .row_count = 0 };

    var produced: u64 = 0;
    var pos = start.pos;
    var row = start.row;
    while (produced < materialize and row < d.filter_rows and !d.reader.atEnd(d.source, pos)) {
        // Bound the SOURCE bytes scanned testing this ONE candidate to the
        // per-row cap (ARCH-huge-row-filtered), exactly like windowSet.
        const row_limit = d.reader.posAtByteBudget(d.source, pos, api.window_row_scan_max_bytes);
        // Test the FULL cell within the bound (cap = null), same rule as
        // SEARCH, using the nav scratch (mutex already held throughout this
        // call).
        d.nav_scratch.clearRetainingCapacity();
        d.nav_refs.clearRetainingCapacity();
        const test_res = d.reader.materialize(d.source, pos, d.column_count, null, row_limit, &d.nav_scratch, &d.nav_refs, d.gpa) catch break;
        if (test_res.capped) {
            // OVERSIZED candidate: consult the background filter-scan's
            // already-recorded FULL-cell match -- never re-tested on this
            // bounded prefix (would wrongly decide on a prefix) and never by
            // re-lexing to the row's true end (would hang).
            const matched = nav.oversizedMatch(d.filter_oversized_matches.items, row) orelse false;
            if (matched) {
                // Re-lex the same bounded prefix WITH the display cap
                // directly into the window -- a bounded prefix, flagged.
                _ = d.reader.materialize(d.source, pos, d.column_count, api.cell_max_bytes, row_limit, &d.win_buf, &d.win_refs, d.gpa) catch break;
                d.win_source.append(d.gpa, row) catch break;
                d.win_oversized.append(d.gpa, true) catch break;
                produced += 1;
                if (produced >= materialize) break; // that was the last row wanted
            }
            // Advance past the oversized row's true end via the checkpoint
            // the frontier drops immediately after it (decision 2), instead
            // of re-scanning its (possibly gigabytes of) remaining bytes.
            const target_row = row + 1;
            const skip_cp = nav.bestCheckpoint(d, target_row);
            pos = skip_cp.pos;
            row = skip_cp.row;
            while (row < target_row) : (row += 1) {
                pos = d.reader.boundsAfter(d.source, pos, null).next;
            }
            continue;
        }
        if (matcher.matchRecord(fctx, d.nav_scratch.items, d.nav_refs.items) != null) {
            // Re-lex the same row WITH the display cap directly into the window.
            _ = d.reader.materialize(d.source, pos, d.column_count, api.cell_max_bytes, row_limit, &d.win_buf, &d.win_refs, d.gpa) catch break;
            d.win_source.append(d.gpa, row) catch break;
            d.win_oversized.append(d.gpa, false) catch break;
            produced += 1;
        }
        pos = test_res.next;
        row += 1;
    }
    d.win_rows = produced;
    return .{ .first_row = first_row, .row_count = produced };
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
///     directly, bypassing the frontier (which never claims a row whose
///     extent past the O(head) budget is unknown — that row is
///     pathologically "oversized" from its very first byte, so
///     `decodeCellAt` below naturally bounds it exactly like any other
///     oversized row). A filtered view defers entirely to
///     `cellCopyFiltered` (FILTERED coordinates, `nav.nthMatchLocation` —
///     the same machinery `windowSetFiltered` uses). Otherwise a `row`
///     behind the frontier is found via `nav.bestCheckpoint` (by value,
///     under `d.lock()`) plus the SAME checkpoint-to-row skip loop
///     `windowSet` uses — never crosses an oversized row's bytes, for the
///     same reason: `row < avail_end` guarantees any oversized row before it
///     was already scanned, so `bestCheckpoint` already lands past it. A
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
pub fn cellCopy(d: *Document, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult {
    out_len.* = 0;
    out_truncated.* = false;
    if (d.column_count == 0 or col >= d.column_count) return .no_cell;

    if (d.filter_state != .idle) return cellCopyFiltered(d, row, col, buf, buf_len, out_len, out_truncated);

    // BOUNDED RECORD 1 (identity view only — mirrors windowSet's pinned-row-0
    // branch): row 0's true extent runs past the O(head) budget, and
    // therefore past the (far smaller) window scan cap too, so it is served
    // exactly like any other oversized row, from `data_start`, bypassing the
    // frontier entirely.
    if (row == 0 and d.record1_capped and !d.has_header and d.row0_pinned_refs.len > 0) {
        return decodeCellAt(d, d.data_start, col, buf, buf_len, out_len, out_truncated);
    }

    d.lock();
    const avail_end = if (d.complete) d.total_rows else d.frontier_rows;
    if (row >= avail_end) {
        const exact = d.complete;
        d.unlock();
        return if (exact) .no_cell else .pending;
    }
    const cp = nav.bestCheckpoint(d, row);
    d.unlock();

    // Skip from the checkpoint to `row` — identical to windowSet's skip loop,
    // and safe for the same reason (see windowSet's comment on its own loop).
    var pos = cp.pos;
    var r = cp.row;
    while (r < row) : (r += 1) {
        pos = d.reader.boundsAfter(d.source, pos, null).next;
    }
    return decodeCellAt(d, pos, col, buf, buf_len, out_len, out_truncated);
}

/// `ls_cell_copy` while a filter is active (FILTERED VIEWS): locate FILTERED
/// index `row`'s ORIGINAL row/position via `nav.nthMatchLocation` — O(checkpoints)
/// + a bounded in-block re-lex, the same machinery `windowSetFiltered` uses —
/// then decode column `col` from there exactly like the identity path. Holds
/// the mutex for the whole call (bounded: O(checkpoints) + one scan-capped
/// row decode), mirroring `windowSetFiltered`.
fn cellCopyFiltered(d: *Document, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult {
    d.lock();
    defer d.unlock();
    if (row >= d.filter_total) return if (d.filter_state == .done) .no_cell else .pending;
    const fctx = filter.filterCtx(d);
    const loc = nav.nthMatchLocation(d, d.filter_block_counts.items, fctx, d.filter_rows, row) orelse {
        // Defensive only: `row < filter_total` guarantees the counted region
        // has this many matches already, so this should be unreachable; if
        // it ever triggers, retrying would not change the outcome.
        return .no_cell;
    };
    return decodeCellAt(d, loc.pos, col, buf, buf_len, out_len, out_truncated);
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
    return .ok;
}
