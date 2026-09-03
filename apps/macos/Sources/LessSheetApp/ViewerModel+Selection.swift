import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the pure index-space rectangular selection (ARCH-select-copy
// AC1) and the manual column resize / double-click auto-fit width overrides
// (AC5). Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    // MARK: - Selection (ARCH-select-copy AC1) — pure index-space state
    // driven by `Selecting` (`SelectionModel`); the grid's mouse/keyboard/
    // gutter/header event routing (NativeGridController) is the only caller.
    // O(1) in the extent, so Cmd+A on the largest document is free.

    /// The document's selectable extent RIGHT NOW: `rowCountInfo.count`
    /// already reports the FILTERED count while a filter is active (the
    /// same domain every other row index in this model uses), so a
    /// selection is naturally scoped to the current view mode with no extra
    /// branching here.
    private func selectionExtent() -> GridExtent {
        GridExtent(rowCount: rowCountInfo.count, columnCount: columnCount)
    }

    /// A plain click.
    func selectCell(row: UInt64, column: Int) {
        selection = selectionModel.select(GridCell(row: row, column: column), in: selectionExtent())
    }

    /// Whether the live selection is exactly this one cell. Kept in the app
    /// layer because the frozen selection algebra intentionally defines only
    /// geometry, while click-again toggling is an input-routing concern.
    func isOnlySelectedCell(_ cell: GridCell) -> Bool {
        selection?.anchor == cell && selection?.active == cell
    }

    func clearSelection() {
        selection = nil
    }

    /// A drag or shift-click: anchor kept, active moves to the clicked cell.
    /// Nothing selected yet: falls back to a plain click (there is no
    /// anchor to extend from).
    func extendSelection(toRow row: UInt64, column: Int) {
        guard let current = selection else { selectCell(row: row, column: column); return }
        selection = selectionModel.extend(current, to: GridCell(row: row, column: column), in: selectionExtent())
    }

    /// Keyboard navigation (ARCH-macos-kbdnav FR1): the arrow / page / document
    /// / line command set, plain or shift-extending, routed through the pure
    /// `KeyboardNavigator` — which COMPOSES the SAME `selectionModel` geometry
    /// (no duplicated clamp / anchor-active algebra). The grid supplies the
    /// viewport-derived context (top visible row, leading visible column, page
    /// size); the reducer owns seed-no-step, visible-column stepping, the
    /// document/line targets, and clamping. With nothing selected ANY command
    /// seeds a 1×1 cursor at the top-left visible cell (no step). Assigns only a
    /// non-nil result, so an empty (nothing-selectable) extent is a no-op.
    func navigate(_ motion: NavigationMotion, extending: Bool,
                  topVisibleRow: UInt64, firstVisibleColumn: Int, pageRows: UInt64) {
        let context = NavigationContext(
            extent: selectionExtent(), visibleColumns: visibleColumns,
            topVisibleRow: topVisibleRow, firstVisibleColumn: firstVisibleColumn, pageRows: pageRows)
        let navigator = KeyboardNavigator(selecting: selectionModel)
        if let updated = navigator.navigate(from: selection, motion, extending: extending, in: context) {
            selection = updated
        }
    }

    /// A gutter click: the whole (capped) row.
    func selectWholeRow(_ row: UInt64) {
        selection = selectionModel.wholeRow(row, in: selectionExtent())
    }

    /// Plain gutter clicks toggle only an identical whole-row selection.
    func toggleWholeRow(_ row: UInt64) {
        let candidate = selectionModel.wholeRow(row, in: selectionExtent())
        selection = selection == candidate ? nil : candidate
    }

    /// A header click: the whole (capped) column.
    func selectWholeColumn(_ column: Int) {
        selection = selectionModel.wholeColumn(column, in: selectionExtent())
    }

    /// Plain header clicks toggle only an identical whole-column selection.
    func toggleWholeColumn(_ column: Int) {
        let candidate = selectionModel.wholeColumn(column, in: selectionExtent())
        selection = selection == candidate ? nil : candidate
    }

    /// A shift-click on the gutter (ARCH: whole-row EXTEND is "composed by
    /// the frontend from extend(_:to:in:)"): keep the anchor, extend to the
    /// clicked row spanning every column. Nothing selected yet: falls back
    /// to a plain whole-row select.
    func extendSelectionToWholeRow(_ row: UInt64) {
        guard let current = selection else { selectWholeRow(row); return }
        let extent = selectionExtent()
        guard !extent.isEmpty else { return }
        selection = selectionModel.extend(current, to: GridCell(row: row, column: extent.lastColumn), in: extent)
    }

    /// A shift-click on the header — the whole-column analog of
    /// `extendSelectionToWholeRow`.
    func extendSelectionToWholeColumn(_ column: Int) {
        guard let current = selection else { selectWholeColumn(column); return }
        let extent = selectionExtent()
        guard !extent.isEmpty else { return }
        selection = selectionModel.extend(current, to: GridCell(row: extent.lastRow, column: column), in: extent)
    }

    /// Cmd+A: the capped extent from the origin — O(1) for any document size.
    func selectAll() {
        selection = selectionModel.selectAll(in: selectionExtent())
    }

    /// Per-column selection-overlay state for a data row over the current
    /// column WINDOW (ARCH AC1), O(window) — the selection analog of
    /// `windowCellHighlights`; `SheetRowView.draw` reads this directly (no
    /// per-cell model call on the draw path).
    func windowSelectionMarks(forRow row: Int) -> [SelectionMark] {
        guard let selection else { return [] }
        let rect = selection.rect
        let active = selection.active
        let cols = windowColumns()
        guard !cols.isEmpty else { return [] }
        let rowValue = UInt64(row)
        return cols.map { column in
            let cell = GridCell(row: rowValue, column: column)
            guard rect.contains(cell) else { return .none }
            return SelectionMark(
                isSelected: true,
                borderTop: rowValue == rect.top, borderBottom: rowValue == rect.bottom,
                borderLeft: column == rect.left, borderRight: column == rect.right,
                isActive: cell == active
            )
        }
    }

    // MARK: - Column resize + auto-fit (ARCH-select-copy AC5)

    /// The width actually drawn for absolute `column`: the manual override
    /// if present, else the auto baseline — `ColumnSizing`'s "manual wins"
    /// rule, O(1) (a single dictionary lookup).
    func effectiveWidth(_ column: Int) -> CGFloat {
        if let manual = manualColumnWidths[column] { return CGFloat(manual) }
        return column < columnWidths.count ? columnWidths[column] : GridMetrics.minColumnWidth
    }

    /// Drag-resize: `windowIndex` is a position in the CURRENT column window
    /// (`windowWidths()`'s index space — exactly what the grid hit-tests the
    /// trailing hairline against), so resolving the absolute column and its
    /// cache slot is O(1) — no all-visible-columns search ("ride the
    /// column-window offsets"). Sets an explicit manual width (floored at
    /// `minColumnWidth`) that STICKS: `windowWidths()`/`totalVisibleWidth`
    /// return it regardless of what auto-grow measures underneath from here
    /// on (`growColumnWidthsToFitWindow` skips it).
    func resizeWindowColumn(_ windowIndex: Int, toWidth width: Double) {
        let cols = windowColumns()
        guard cols.indices.contains(windowIndex) else { return }
        let column = cols[windowIndex]
        let previous = effectiveWidth(column)
        manualColumnWidths = columnSizer.resized(
            manual: manualColumnWidths, column: column, to: width, minWidth: Double(GridMetrics.minColumnWidth)
        )
        var settings = userSettings(for: column)
        settings.manualWidth = manualColumnWidths[column]
        storeColumnSettings(settings, column: column)
        syncEffectiveWidthCache(column: column, windowIndex: windowIndex, previous: previous)
    }

    /// Double-click auto-fit: clears the manual override AND resets the
    /// column's AUTO baseline to the exact fit over its VISIBLE window
    /// content (O(visible rows), never O(rows)) — so it is back in auto
    /// mode at the fitted width and can grow again as new content scrolls
    /// in (`ColumnSizing.autoFit`'s contract).
    func autoFitWindowColumn(_ windowIndex: Int) {
        let cols = windowColumns()
        guard cols.indices.contains(windowIndex) else { return }
        let column = cols[windowIndex]
        let previous = effectiveWidth(column)
        let fitted = columnSizer.autoFit(
            contentWidths: measuredContentWidths(forColumn: column),
            minWidth: Double(GridMetrics.minColumnWidth), maxWidth: Double(GridMetrics.maxColumnWidth)
        )
        manualColumnWidths = columnSizer.cleared(manual: manualColumnWidths, column: column)
        if column < columnWidths.count { columnWidths[column] = CGFloat(fitted) }
        var settings = userSettings(for: column)
        settings.manualWidth = nil
        storeColumnSettings(settings, column: column)
        syncEffectiveWidthCache(column: column, windowIndex: windowIndex, previous: previous)
    }

    /// O(1) sync of the visible-position caches (`cachedLayoutWidths`/
    /// `cachedTotalVisibleWidth` — otherwise rebuilt only on a STRUCTURAL
    /// change, see `refreshLayoutWidthsIfNeeded`) after ONE column's
    /// effective width changed, so a resize drag never pays that O(visible
    /// columns) rebuild (ARCH AC5: "O(1) per resize... no all-column
    /// relayout"). `windowIndex` maps to visible-position `columnWindow.
    /// first + windowIndex` with no search, by construction of
    /// `windowColumns()`. A no-op while the caches are already stale (a
    /// pending full rebuild picks up the fresh value on its own).
    private func syncEffectiveWidthCache(column: Int, windowIndex: Int, previous: CGFloat) {
        guard !layoutWidthsStale else { return }
        let updated = effectiveWidth(column)
        guard updated != previous else { return }
        let position = columnWindow.first + windowIndex
        if cachedLayoutWidths.indices.contains(position) {
            cachedLayoutWidths[position] = Double(updated)
        }
        cachedTotalVisibleWidth += updated - previous
    }

    /// The measured pixel widths — header + each VISIBLE row's cell,
    /// O(visible rows) — for absolute `column` (`ColumnSizing.autoFit`'s
    /// `contentWidths` input; padding pre-added per the contract doc).
    /// Mirrors `growColumnWidthsToFitWindow`'s own measurement (same fonts/
    /// padding/oversized-row and truncated-cell exclusions) so a double-click
    /// and the passive auto-grow agree on what "fits."
    func measuredContentWidths(forColumn column: Int) -> [Double] {
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let padding = GridMetrics.cellHPadding * 2
        var widths = [Double(Self.textWidth(columnLabel(column), headFont) + padding)]

        let start = Int(window.firstRow)
        let lowerRow = max(start, firstVisibleRow)
        let upperRow = min(start + window.rows.count, firstVisibleRow + max(lastVisibleCount, 1))
        guard lowerRow < upperRow else { return widths }
        let rel = column - window.firstColumn
        guard rel >= 0 else { return widths }
        // Off-window columns have no presentation to format; they are measured
        // from the raw window cell.
        let inWindow = windowColumns().contains(column)

        for viewRow in lowerRow..<upperRow {
            let idx = viewRow - start
            if idx < window.oversized.count, window.oversized[idx] { continue }
            let row = window.rows[idx]
            guard rel < row.count else { continue }
            if idx < window.truncated.count, rel < window.truncated[idx].count, window.truncated[idx][rel] { continue }
            let displayed = inWindow
                ? windowCellPresentation(forRow: viewRow, column: column).text
                : row[rel]
            widths.append(Double(Self.textWidth(displayed, bodyFont) + padding))
        }
        return widths
    }
}
