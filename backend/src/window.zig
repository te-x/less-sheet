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
/// display-capped to LS_CELL_MAX_BYTES (requirement 8).
pub fn windowSet(d: *Document, first_row: u64, row_count: u32) api.RowRange {
    // Evict the previous window regardless of the outcome.
    d.win_buf.clearRetainingCapacity();
    d.win_refs.clearRetainingCapacity();
    d.win_source.clearRetainingCapacity();
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
        cp = findCheckpoint(d.checkpoints.items, next_row);
    }
    d.unlock();

    if (materialize == 0) return .{ .first_row = first_row, .row_count = pinned_rows };

    // Skip from the checkpoint to next_row, then decode `materialize` rows.
    var off: usize = @intCast(cp.offset);
    var r = cp.row;
    while (r < next_row) : (r += 1) {
        off = lexer.recordBounds(d.content, off, d.sep, d.quote, d.content.len, d.encoding).next;
    }
    var produced: u64 = 0;
    while (produced < materialize) : (produced += 1) {
        const res = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, api.cell_max_bytes, d.content.len, d.encoding, &d.win_buf, &d.win_refs, d.gpa) catch break;
        d.win_source.append(d.gpa, next_row + produced) catch {}; // identity: source == physical row
        off = res.next;
    }
    d.win_rows = pinned_rows + produced;
    return .{ .first_row = first_row, .row_count = pinned_rows + produced };
}

/// ls_window_set while a filter is active: `first_row`/`clamped` are FILTERED
/// coordinates (row i = the i-th matching data row). Locates the source
/// row/offset of filtered index `first_row` via the filter's per-block
/// counters (O(checkpoints) + a bounded in-block re-lex — never O(matches)),
/// then walks forward re-lexing candidate rows, skipping non-matches, to
/// serve up to `clamped` consecutive filtered rows. Holds the mutex for the
/// whole call (bounded: O(checkpoints) + O(window) re-lex) — simpler and
/// still safe on the caller/UI thread; see api/lesssheet.h FILTERED VIEWS.
fn windowSetFiltered(d: *Document, first_row: u64, clamped: u64) api.RowRange {
    d.lock();
    defer d.unlock();
    if (first_row >= d.filter_total) return .{ .first_row = first_row, .row_count = 0 };
    const materialize = @min(clamped, d.filter_total - first_row);
    const fctx = filter.filterCtx(d);
    const start = nav.nthMatchLocation(d, d.filter_block_counts.items, fctx, d.filter_rows, first_row) orelse
        return .{ .first_row = first_row, .row_count = 0 };

    var produced: u64 = 0;
    var off: usize = @intCast(start.offset);
    var row = start.row;
    while (produced < materialize and row < d.filter_rows and off < d.content.len) {
        // Test the FULL cell (cap = null), same rule as SEARCH, using the nav
        // scratch (mutex already held throughout this call).
        d.nav_scratch.clearRetainingCapacity();
        d.nav_refs.clearRetainingCapacity();
        const test_res = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, null, d.content.len, d.encoding, &d.nav_scratch, &d.nav_refs, d.gpa) catch break;
        if (matcher.matchRecord(fctx, d.nav_scratch.items, d.nav_refs.items) != null) {
            // Re-lex the same row WITH the display cap directly into the window.
            _ = lexer.lexInto(d.content, off, d.sep, d.quote, d.column_count, api.cell_max_bytes, d.content.len, d.encoding, &d.win_buf, &d.win_refs, d.gpa) catch break;
            d.win_source.append(d.gpa, row) catch break;
            produced += 1;
        }
        off = test_res.next;
        row += 1;
    }
    d.win_rows = produced;
    return .{ .first_row = first_row, .row_count = produced };
}

/// Largest checkpoint with `.row <= row` (checkpoints[0].row == 0 always).
fn findCheckpoint(checkpoints: []const Checkpoint, row: u64) Checkpoint {
    var best: Checkpoint = checkpoints[0];
    var lo: usize = 0;
    var hi: usize = checkpoints.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (checkpoints[mid].row <= row) {
            best = checkpoints[mid];
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return best;
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
/// / sourceRow. SEED STUB (RED): windowSet does not yet bound the per-row
/// source scan to `api.window_row_scan_max_bytes`, so no row is flagged — this
/// always returns false. The build-cell implementer will (per ARCH-huge-row-
/// budget) bound windowSet's skip + materialize loops to that cap, store the
/// per-row oversized flag on the Document parallel to `win_source`, drop a
/// checkpoint after each oversized row, and return the stored flag here. Total
/// function; ZERO allocation; never fails; never scans.
pub fn rowOversized(_: *const Document, _: u64) bool {
    return false;
}
