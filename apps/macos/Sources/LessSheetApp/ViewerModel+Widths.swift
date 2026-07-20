import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the monotone column-width grow over the current window, plus
// the column-relative window cell/truncation/oversized accessors. Pure code
// motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    /// The DECIDED width behaviour (ARCH-column-windowing "Column-width
    /// behaviour" / AC5b): grow — never shrink — each column CURRENTLY IN THE
    /// HORIZONTAL WINDOW to fit its OWN content over the just-materialized
    /// vertical row window, capped at maxColumnWidth, and merged through
    /// `ColumnLayouting.grown` so the merge is provably independent and
    /// monotone. Bounded to `columnWindow` — never `columnCount` — so this
    /// stays cheap however wide the document is.
    func growColumnWidthsToFitWindow() {
        guard columnCount > 0, !window.rows.isEmpty, columnWidths.count == columnCount else { return }
        // Measure only the VISIBLE slice (~a viewport), not the whole buffered
        // window — keeps this off the landing hot path (<100 ms budget); growth
        // keeps up incrementally as further scrolls re-materialize.
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

    /// Loop-invariant context for `widthCandidate` (bundled to keep the helper
    /// under the parameter-count bar): the visible-column list + its window base,
    /// the visible row band, and the two fonts each measured cell is drawn in.
    private struct WidthMeasureContext {
        let cols: [Int]
        let base: Int
        let lowerRow: Int
        let upperRow: Int
        let start: Int
        let bodyFont: NSFont
        let headFont: NSFont
    }

    /// The grown width CANDIDATE for the column at visible position `pos`, or
    /// nil when it should not grow (a manual override, out of range, or already
    /// wide enough). Extracted from `growColumnWidthsToFitWindow` so that method
    /// stays under the cyclomatic-complexity bar; behavior is identical. A cell
    /// the core already clipped — display-TRUNCATED, or any cell of an OVERSIZED
    /// row — is excluded from the measurement (it isn't the cell's real content).
    private func widthCandidate(forPosition pos: Int, in context: WidthMeasureContext) -> Double? {
        let column = context.cols[pos]
        guard column < columnWidths.count else { return nil }
        // A manually-resized column is FROZEN (ARCH-select-copy AC5: auto-grow
        // never overrides a manual width) — skip measuring it so its auto
        // baseline (and the effective-width cache) stay exactly as the user set
        // them until they clear/auto-fit it.
        guard manualColumnWidths[column] == nil else { return nil }
        let rel = column - context.base
        // Always measure the header (its accurate semibold width): the open-time
        // measurement already baked the header into every column's width, so for
        // the initial window this is idempotent, while a column revealed LATER
        // (past the open-time fetch range on a wide document) still gets its
        // header width the moment it enters the window, monotone.
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

    /// Cells for a data row, read from the currently materialized window —
    /// COLUMN-RELATIVE to `window.firstColumn` (ARCH-column-windowing
    /// round-2): slot `j` is absolute column `window.firstColumn + j`, NOT
    /// absolute column `j` itself, whenever the window is narrower than
    /// `columnCount`. Rows outside the window return `nil` (the grid renders
    /// empty cells that fill in once the frontier advances and the window
    /// re-materializes). Absolute-column callers go through `cellsAt`, below.
    func cells(forRow row: Int) -> [String]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.rows.count else { return nil }
        return window.rows[idx]
    }

    /// Per-cell display-truncation flags for a data row, PARALLEL to
    /// `cells(forRow:)` (mirrors `RowWindow.truncated`, ARCH req. 13/20) —
    /// same column-RELATIVE shape as `cells(forRow:)`. Rows outside the
    /// window return `nil`, same rule as `cells(forRow:)`.
    func truncated(forRow row: Int) -> [Bool]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.truncated.count else { return nil }
        return window.truncated[idx]
    }

    /// Cells at ABSOLUTE `columns` of data row `row`, mapped through the
    /// CURRENTLY FETCHED column window (`window.firstColumn`): absolute
    /// column `c` reads slot `c - window.firstColumn` of `cells(forRow:)`,
    /// empty-padded for a column outside the fetched range — not yet
    /// materialized, or past the row's width — exactly like a not-yet-loaded
    /// row (ARCH-column-windowing round-2). Shared by the eager, all-visible-
    /// columns dump-grid helpers and the live grid's window-bound helpers
    /// below; they differ only in which absolute columns they ask for.
    func cellsAt(_ columns: [Int], forRow row: Int) -> [String] {
        guard let full = cells(forRow: row) else { return Array(repeating: "", count: columns.count) }
        let base = window.firstColumn
        return columns.map { column in
            let rel = column - base
            return rel >= 0 && rel < full.count ? full[rel] : ""
        }
    }

    /// Truncation flags at ABSOLUTE `columns` of data row `row` — the
    /// `truncated(forRow:)` analog of `cellsAt`.
    func truncatedAt(_ columns: [Int], forRow row: Int) -> [Bool] {
        guard let full = truncated(forRow: row) else { return Array(repeating: false, count: columns.count) }
        let base = window.firstColumn
        return columns.map { column in
            let rel = column - base
            return rel >= 0 && rel < full.count ? full[rel] : false
        }
    }

    /// Whether a data row is OVERSIZED (ARCH-huge-row-budget req. 3/7): its
    /// SOURCE extent exceeded the core's per-row window scan cap, so it was
    /// served as a bounded prefix (mirrors `RowWindow.oversized`). `false` for
    /// rows outside the currently materialized window, same rule as
    /// `cells(forRow:)` / `truncated(forRow:)` — the gutter simply shows no
    /// marker until a re-window catches up, exactly like a blank row.
    func rowOversized(forRow row: Int) -> Bool {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.oversized.count else { return false }
        return window.oversized[idx]
    }

    /// Whether a data row's cells are already SERVABLE — the materialized
    /// window has reached it — as opposed to being within the row-count
    /// estimate but past the scan frontier (the case `cells(forRow:)` /
    /// `visibleBodyCells(forRow:)` return `nil` / empty-padded for). The grid
    /// uses this to distinguish "still loading" from a genuinely empty row —
    /// both otherwise render identically empty — and draws a subtle loading
    /// placeholder for the former instead of silently blank cells (PROJECT:
    /// constant feedback, no silent stalls). Same window-membership rule as
    /// `cells(forRow:)`; unrelated to filtering (a filtered window's `cells`
    /// already reflect the filtered view under that same rule).
    func rowLoaded(forRow row: Int) -> Bool {
        cells(forRow: row) != nil
    }

    var displayRowCount: Int {
        Int(min(rowCountInfo.count, UInt64(Int.max)))
    }
}
