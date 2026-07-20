import CLessSheet
import Contracts
import Foundation

// MARK: - Window lane (ls_window_set / ls_cell / ls_source_row).
// Split out of CoreDocumentSession.swift as a same-module extension (pure code
// motion). Everything here is the window lane: it takes the session's `lock`
// (now `internal` so this file can reach it) around `ls_window_set` and the
// per-cell reads, exactly as before. `fetchWindow` stays `private` — it is used
// only by the two `setWindow` overloads in this same file.
extension CoreDocumentSession {
    public func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow {
        lock.lock()
        defer { lock.unlock() }
        let clamped = UInt32(clamping: max(rowCount, 0))
        let range = ls_window_set(doc, firstRow, clamped)
        // The dense overload always asks for every column — no clamp needed,
        // `0..<columnCount` is already exactly the valid domain.
        return fetchWindow(range, columns: 0..<columnCount)
    }

    /// COLUMN-WINDOWED override (ARCH-column-windowing AC7 — the round-2
    /// amendment): identical ROW handling to the dense overload above, but
    /// reads cells/flags for ONLY `columns` (clamped to `0..<columnCount`)
    /// instead of every column, so the fetch is O(rows x columns.count) FFI
    /// calls, never O(rows x columnCount). `ViewerModel.materialize` routes
    /// through this with the live horizontal column window as `columns`,
    /// which is what carries a wide document's cold-open (and every
    /// scroll-materialize) back under budget — the dense overload's own
    /// `ls_cell`/`ls_cell_truncated` fetch of ALL columns, on EVERY
    /// materialize, was measured (round-1 hand-off) at ~180 ms for
    /// wide_100k_cols alone. Overriding the PROTOCOL REQUIREMENT (not just the
    /// default extension) means this is what `any DocumentSession` dispatches
    /// to — exactly what flips AC7 from the frozen RED seed (the dense
    /// fallback) to GREEN.
    public func setWindow(firstRow: UInt64, rowCount: Int, columns: Range<Int>) -> RowWindow {
        lock.lock()
        defer { lock.unlock() }
        let clamped = UInt32(clamping: max(rowCount, 0))
        let range = ls_window_set(doc, firstRow, clamped)
        return fetchWindow(range, columns: columns.clamped(to: 0..<columnCount))
    }

    /// Shared row+column materialize (window lane; caller already holds
    /// `lock`): copies cells/truncation/oversized flags for exactly `columns`
    /// (already clamped to `0..<columnCount` by the caller) over the row
    /// range `ls_window_set` just served, producing a `RowWindow` whose
    /// `firstColumn` is `columns.lowerBound` and whose rows are exactly
    /// `columns.count` wide — `columns == 0..<columnCount` (the dense
    /// overload's call) yields `firstColumn == 0` and full-width rows,
    /// byte-identical to what `setWindow(firstRow:rowCount:)` served before
    /// this override existed.
    private func fetchWindow(_ range: ls_row_range, columns: Range<Int>) -> RowWindow {
        var rows = [[String]]()
        var truncated = [[Bool]]()
        var oversized = [Bool]()
        rows.reserveCapacity(Int(range.row_count))
        truncated.reserveCapacity(Int(range.row_count))
        oversized.reserveCapacity(Int(range.row_count))
        for row in range.first_row..<(range.first_row + range.row_count) {
            rows.append(columns.map { Self.copyCell(ls_cell(doc, row, UInt32($0))) })
            truncated.append(columns.map { ls_cell_truncated(doc, row, UInt32($0)) })
            // Per-row OVERSIZED flag (ls_row_oversized): true iff the row's
            // source extent exceeded LS_WINDOW_ROW_SCAN_MAX_BYTES and it was
            // served as a bounded prefix. Window lane, so under the same lock.
            oversized.append(ls_row_oversized(doc, row))
        }
        return RowWindow(
            firstRow: range.first_row, firstColumn: columns.lowerBound,
            rows: rows, truncated: truncated, oversized: oversized
        )
    }

    /// OVERRIDES the RED default (`DocumentSession`'s `[]`-for-everything
    /// extension): the per-window MATCH FLAGS bridge (ARCH-thin-frontend-
    /// shared-core Phase 1; `ls_window_match_flags`). Calls the core ONCE for
    /// the window last set by `setWindow` and copies the borrowed flag bytes
    /// (1 = matches the active search request, 0 = not; row-major, stride
    /// `columnCount`, `count == windowRowCount * columnCount`) straight into an
    /// owned `[UInt8]` — the UTF-8-copy-out discipline of `copyCell(_:)`, so the
    /// core's window-tied borrow is never held past this call. WINDOW LANE like
    /// `setWindow` / `ls_cell`: takes the window-lane `lock` (NOT the copy
    /// `copyBufferLock`), so it is serialized with window materialization —
    /// exactly the caller contract `ls_window_match_flags` documents. A
    /// `firstColumn < 0` or `columnCount <= 0` (empty/invalid range) returns
    /// `[]` without touching the core; larger-than-`UInt32` indices clamp, which
    /// the core then reports as out of range (the empty buffer). The core
    /// returns `[]` for IDLE / no window / out-of-range, so those surface as an
    /// empty array here — no highlights.
    public func windowMatchFlags(firstColumn: Int, columnCount: Int) -> [UInt8] {
        guard firstColumn >= 0, columnCount > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let flags = ls_window_match_flags(doc, UInt32(clamping: firstColumn), UInt32(clamping: columnCount))
        guard flags.len > 0, let ptr = flags.ptr else { return [] }
        return [UInt8](UnsafeBufferPointer(start: ptr, count: flags.len))
    }

    public func sourceRow(_ viewRow: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let row = ls_source_row(doc, viewRow)
        return row == UInt64(LS_NO_ROW) ? nil : row
    }
}
