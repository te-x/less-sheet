//! Windowed row access: the `ls_window_set` materialization (identity and
//! filtered-coordinate variants) and the cell/header-cell/source-row
//! accessors that serve the materialized window. See api/lesssheet.h for the
//! eviction-safe borrow rule and FILTERED VIEWS for the filtered-coordinate
//! remap. The `pub export fn` wrappers stay in root.zig; these are their
//! bodies (window state — win_buf/win_refs/win_source/win_first/win_rows —
//! lives on `Document`, touched only by the caller-serialized window lane,
//! so most of this needs no lock; windowSetFiltered is the one exception,
//! per its own doc comment).

const api = @import("api");
const base = @import("base.zig");
const lexer = @import("lexer.zig");
const matcher = @import("matcher.zig");
const nav = @import("nav.zig");
const filter = @import("filter.zig");

const Document = base.Document;
const Checkpoint = base.Checkpoint;

const empty_str: api.Str = .{ .ptr = "", .len = 0 };

/// See api/lesssheet.h `ls_window_set`. Never advances the frontier; re-lexes
/// the requested rows (behind the frontier) from the nearest checkpoint into
/// the owned window buffer, evicting the previous window. Every cell is
/// decoded through `decodeUnit` (the document's resolved encoding) and
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
    var cp: Checkpoint = .{ .row = 0, .offset = d.data_start };
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
    var off: usize = @intCast(cp.offset);
    var r = cp.row;
    while (r < next_row) : (r += 1) {
        off = lexer.recordBounds(d.content, off, d.sep, d.quote, d.content.len, d.encoding).next;
    }

    const scan_cap: usize = @intCast(api.window_row_scan_max_bytes);
    var produced: u64 = 0;
    while (produced < materialize) {
        // Bound the SOURCE bytes scanned for this ONE row to the per-row cap:
        // a row whose terminator isn't found within it is served as a bounded
        // prefix (cells stay individually display-capped, as before) and
        // flagged oversized — this call never re-lexes a giant row's full
        // bytes.
        const row_limit = @min(off +| scan_cap, d.content.len);
        const res = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, api.cell_max_bytes, row_limit, d.encoding, &d.win_buf, &d.win_refs, d.gpa) catch break;
        d.win_source.append(d.gpa, next_row + produced) catch {}; // identity: source == physical row
        d.win_oversized.append(d.gpa, res.capped) catch {};
        produced += 1;
        if (!res.capped) {
            off = res.next;
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
        off = @intCast(skip_cp.offset);
        var rr = skip_cp.row;
        while (rr < target_row) : (rr += 1) {
            off = lexer.recordBounds(d.content, off, d.sep, d.quote, d.content.len, d.encoding).next;
        }
    }
    d.win_rows = pinned_rows + produced;
    return .{ .first_row = first_row, .row_count = pinned_rows + produced };
}

/// ls_window_set while a filter is active: `first_row`/`clamped` are FILTERED
/// coordinates (row i = the i-th matching data row). Locates the source
/// row/offset of filtered index `first_row` via the filter's per-block
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

    const scan_cap: usize = @intCast(api.window_row_scan_max_bytes);
    var produced: u64 = 0;
    var off: usize = @intCast(start.offset);
    var row = start.row;
    while (produced < materialize and row < d.filter_rows and off < d.content.len) {
        // Bound the SOURCE bytes scanned testing this ONE candidate to the
        // per-row cap (ARCH-huge-row-filtered), exactly like windowSet.
        const row_limit = @min(off +| scan_cap, d.content.len);
        // Test the FULL cell within the bound (cap = null), same rule as
        // SEARCH, using the nav scratch (mutex already held throughout this
        // call).
        d.nav_scratch.clearRetainingCapacity();
        d.nav_refs.clearRetainingCapacity();
        const test_res = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, null, row_limit, d.encoding, &d.nav_scratch, &d.nav_refs, d.gpa) catch break;
        if (test_res.capped) {
            // OVERSIZED candidate: consult the background filter-scan's
            // already-recorded FULL-cell match -- never re-tested on this
            // bounded prefix (would wrongly decide on a prefix) and never by
            // re-lexing to the row's true end (would hang).
            const matched = nav.oversizedMatch(d.filter_oversized_matches.items, row) orelse false;
            if (matched) {
                // Re-lex the same bounded prefix WITH the display cap
                // directly into the window -- a bounded prefix, flagged.
                _ = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, api.cell_max_bytes, row_limit, d.encoding, &d.win_buf, &d.win_refs, d.gpa) catch break;
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
            off = @intCast(skip_cp.offset);
            row = skip_cp.row;
            while (row < target_row) : (row += 1) {
                off = lexer.recordBounds(d.content, off, d.sep, d.quote, d.content.len, d.encoding).next;
            }
            continue;
        }
        if (matcher.matchRecord(fctx, d.nav_scratch.items, d.nav_refs.items) != null) {
            // Re-lex the same row WITH the display cap directly into the window.
            _ = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, api.cell_max_bytes, row_limit, d.encoding, &d.win_buf, &d.win_refs, d.gpa) catch break;
            d.win_source.append(d.gpa, row) catch break;
            d.win_oversized.append(d.gpa, false) catch break;
            produced += 1;
        }
        off = test_res.next;
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
/// lexInto). Zero allocation; total function; never fails.
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


/// See api/lesssheet.h `ls_cell_copy`. RED SEED — the bounded full-cell read is
/// NOT yet implemented: it serves the EMPTY string for every servable cell
/// (out_len 0), so the frozen behavior test (cc*) is RED on the full-cell
/// content, on truncation, on the no-borrow copy, and on the PENDING / NO_CELL
/// status machine, while `zig build` still compiles (the comptime pin + C-ABI
/// export are satisfied). It touches only `column_count` (immutable), so it
/// cannot fault, overrun `buf`, or race.
///
/// GREEN path (the build implementer's work — window-INDEPENDENT, poll/control
/// lane, ZERO heap alloc, NEVER scans/advances the frontier):
///   * NO_CELL when `d.column_count == 0` or `col >= d.column_count`, or when
///     `row` is at/beyond an EXACT end (identity: `row >= d.total_rows` while
///     `d.complete`; filtered: `row >= d.filter_total` while `d.filter_state ==
///     .done`).
///   * Locate `row`'s content offset WITHOUT scanning: the pinned bounded
///     record-1 row 0 (`row0_pinned_*`, identity view) serves directly; else,
///     under `d.lock()`, read `avail_end = if (d.complete) d.total_rows else
///     d.frontier_rows` and, if `row < avail_end`, take `nav.bestCheckpoint(d,
///     row)` (by value) and unlock. A `row >= avail_end` that is not pinned is
///     PENDING (its offset is unknown until the frontier advances). Filtered
///     (`d.filter_state != .idle`): interpret `row` in FILTERED coordinates via
///     `nav.nthMatchLocation` over `d.filter_block_counts` (like
///     windowSetFiltered); `row >= d.filter_total` counted-so-far is PENDING.
///   * From the checkpoint, skip to `row` (`lexer.recordBounds`) and decode
///     ONLY column `col` into `buf[0..buf_len]`, reusing the lexer's
///     storeCapped/utf8TrimToBoundary discipline with `cap = buf_len` and a
///     per-row SOURCE bound of `api.window_row_scan_max_bytes` (identical to
///     windowSet, so cost stays O(min(row bytes, cap))). Set `out_len.*` to the
///     bytes written and `out_truncated.*` iff the cell's full transcoded
///     content exceeds them (buf_len OR the per-row source cap — an OVERSIZED
///     row is a bounded prefix, `out_truncated` true). Return `.ok`.
/// The read COPIES into the caller buffer (no ls_str borrow), so its output is
/// unaffected by a later ls_window_set — the cc no-borrow test pins this.
pub fn cellCopy(d: *Document, row: u64, col: u32, buf: ?[*]u8, buf_len: usize, out_len: *usize, out_truncated: *bool) api.CopyResult {
    _ = row;
    _ = buf;
    _ = buf_len;
    out_len.* = 0;
    out_truncated.* = false;
    if (d.column_count == 0 or col >= d.column_count) return .no_cell;
    return .ok; // RED: serves nothing (out_len 0) instead of the full cell.
}
