import CLessSheet
import Contracts
import Foundation

// The WINDOW lane (`ls_window_set` / `ls_cell` / `ls_source_row`): every call
// here holds the session's `lock` across the window set and the reads that
// borrow from it.
extension CoreDocumentSession {
    public func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow {
        lock.lock()
        defer { lock.unlock() }
        let clamped = UInt32(clamping: max(rowCount, 0))
        let range = ls_window_set(doc, firstRow, clamped)
        return fetchWindow(range, columns: 0..<columnCount)
    }

    /// Identical row handling to the dense overload, but reads cells and flags
    /// for ONLY `columns`, so the fetch costs O(rows × columns.count) FFI calls
    /// rather than O(rows × columnCount). The live grid always routes through
    /// this with its horizontal column window; the dense fetch of every column
    /// on every materialize is what put a 100k-column document far over the
    /// cold-open budget.
    public func setWindow(firstRow: UInt64, rowCount: Int, columns: Range<Int>) -> RowWindow {
        lock.lock()
        defer { lock.unlock() }
        let clamped = UInt32(clamping: max(rowCount, 0))
        let range = ls_window_set(doc, firstRow, clamped)
        return fetchWindow(range, columns: columns.clamped(to: 0..<columnCount))
    }

    /// Copies cells, truncation and oversized flags for exactly `columns`
    /// (already clamped by the caller) over the row range `ls_window_set` just
    /// served. The caller holds `lock`.
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
            oversized.append(ls_row_oversized(doc, row))
        }
        return RowWindow(
            firstRow: range.first_row, firstColumn: columns.lowerBound,
            rows: rows, truncated: truncated, oversized: oversized
        )
    }

    /// The per-window match-flag mask for the window `setWindow` last served:
    /// one byte per cell (1 = matches the active search request), row-major with
    /// stride `columnCount`. The core's borrow is tied to that window, so the
    /// bytes are copied out before returning. An empty range, or no active
    /// search, yields `[]` — no highlights.
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
