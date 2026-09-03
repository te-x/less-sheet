import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The monotone column-width grow over the current window, and the
// column-relative accessors into the materialized window.

extension DocumentModel {
    /// Grows — never shrinks — each column currently in the horizontal window to
    /// fit its OWN content over the just-materialized rows, capped and merged
    /// monotonically. Bounded to the window, never `columnCount`, so it stays
    /// cheap however wide the document is.
    func growColumnWidthsToFitWindow() {
        guard columnCount > 0, !window.rows.isEmpty, columnWidths.count == columnCount else { return }
        // Only the VISIBLE slice, not the whole buffered window: this sits on the
        // landing path, and growth keeps up incrementally as scrolling
        // re-materializes.
        let start = Int(window.firstRow)
        let lowerRow = max(start, firstVisibleRow)
        let upperRow = min(start + window.rows.count, firstVisibleRow + max(lastVisibleCount, 1))
        guard lowerRow < upperRow else { return }

        refreshLayoutWidthsIfNeeded()
        let cols = visibleColumns
        guard !cols.isEmpty else { return }
        let inWindow = columnWindow.range.clamped(to: 0..<cols.count)
        guard !inWindow.isEmpty else { return }

        let context = WidthMeasureContext(
            cols: cols, base: window.firstColumn, lowerRow: lowerRow, upperRow: upperRow, start: start,
            bodyFont: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            headFont: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        )
        var candidates: [Int: Double] = [:]
        for pos in inWindow {
            if let candidate = widthCandidate(forPosition: pos, in: context) { candidates[pos] = candidate }
        }
        guard !candidates.isEmpty else { return }

        let grownWidths = columnLayout.grown(cachedLayoutWidths, mergingCandidates: candidates)
        var widths = columnWidths
        for pos in candidates.keys {
            let column = cols[pos]
            let newWidth = CGFloat(grownWidths[pos])
            cachedTotalVisibleWidth += newWidth - widths[column]
            widths[column] = newWidth
        }
        columnWidths = widths
        cachedLayoutWidths = grownWidths   // stays in lockstep; no need to mark stale
    }

    /// Loop-invariant context for `widthCandidate`: the visible-column list and
    /// its window base, the visible row band, and the fonts the cells are drawn in.
    private struct WidthMeasureContext {
        let cols: [Int]
        let base: Int
        let lowerRow: Int
        let upperRow: Int
        let start: Int
        let bodyFont: NSFont
        let headFont: NSFont
    }

    /// The grown width candidate for the column at visible position `pos`, or nil
    /// when it should not grow. A cell the core already clipped — display
    /// truncated, or any cell of an oversized row — is excluded: that is not the
    /// cell's real content.
    private func widthCandidate(forPosition pos: Int, in context: WidthMeasureContext) -> Double? {
        let column = context.cols[pos]
        guard column < columnWidths.count else { return nil }
        // A manually-resized column is frozen: auto-grow never overrides it.
        guard manualColumnWidths[column] == nil else { return nil }
        let rel = column - context.base
        // Always measure the header. The open-time pass already baked it into
        // every column, so this is idempotent for the initial window — but a
        // column first revealed later still gets its header width the moment it
        // enters the window.
        var width = Self.textWidth(columnLabel(column), context.headFont)
        for row in context.lowerRow..<context.upperRow {
            let idx = row - context.start
            if idx < window.oversized.count, window.oversized[idx] { continue }
            let cells = window.rows[idx]
            guard rel >= 0, rel < cells.count else { continue }
            if idx < window.truncated.count, rel < window.truncated[idx].count,
               window.truncated[idx][rel] { continue }
            width = max(width, Self.textWidth(cells[rel], context.bodyFont))
        }
        let capped = min(width + GridMetrics.cellHPadding * 2, GridMetrics.maxColumnWidth)
        guard capped > columnWidths[column] + 0.5 else { return nil }
        return Double(capped)
    }

    /// Cells for a data row, COLUMN-RELATIVE to `window.firstColumn`: slot `j` is
    /// absolute column `firstColumn + j`, not absolute column `j`. Rows outside
    /// the window return nil, and the grid renders empty cells that fill in once
    /// the window catches up. Absolute-column callers use `cellsAt`.
    func cells(forRow row: Int) -> [String]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.rows.count else { return nil }
        return window.rows[idx]
    }

    /// Display-truncation flags parallel to `cells(forRow:)`, in the same
    /// column-relative shape and under the same window rule.
    func truncated(forRow row: Int) -> [Bool]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.truncated.count else { return nil }
        return window.truncated[idx]
    }

    /// Cells at ABSOLUTE `columns`, mapped through the fetched column window:
    /// column `c` reads slot `c - window.firstColumn`, empty-padded for anything
    /// outside that range. The eager and window-bound helpers differ only in
    /// which absolute columns they ask for.
    func cellsAt(_ columns: [Int], forRow row: Int) -> [String] {
        guard let full = cells(forRow: row) else { return Array(repeating: "", count: columns.count) }
        let base = window.firstColumn
        return columns.map { column in
            let rel = column - base
            return rel >= 0 && rel < full.count ? full[rel] : ""
        }
    }

    /// Truncation flags at ABSOLUTE `columns` — the `cellsAt` analog.
    func truncatedAt(_ columns: [Int], forRow row: Int) -> [Bool] {
        guard let full = truncated(forRow: row) else { return Array(repeating: false, count: columns.count) }
        let base = window.firstColumn
        return columns.map { column in
            let rel = column - base
            return rel >= 0 && rel < full.count ? full[rel] : false
        }
    }

    /// Whether a row's SOURCE extent exceeded the core's per-row scan cap, so it
    /// was served as a bounded prefix. False outside the materialized window,
    /// under the same rule as the accessors above.
    func rowOversized(forRow row: Int) -> Bool {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.oversized.count else { return false }
        return window.oversized[idx]
    }

    /// Whether a row's cells are SERVABLE yet, as opposed to inside the row-count
    /// estimate but past what the window has materialized. The two otherwise
    /// render identically empty, so this is the only thing that lets the grid draw
    /// a loading placeholder rather than silently blank cells.
    func rowLoaded(forRow row: Int) -> Bool {
        cells(forRow: row) != nil
    }

    var displayRowCount: Int {
        Int(min(rowCountInfo.count, UInt64(Int.max)))
    }
}
