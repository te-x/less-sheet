import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The index-space rectangular selection, and the manual resize / auto-fit width
// overrides. The grid's event routing is the only caller.

extension DocumentModel {
    /// The selectable extent right now. `rowCountInfo.count` already reports the
    /// FILTERED count while a filter is active — the same domain every other row
    /// index in this model uses — so a selection is naturally scoped to the
    /// current view mode with no branching here.
    private func selectionExtent() -> GridExtent {
        GridExtent(rowCount: rowCountInfo.count, columnCount: columnCount)
    }

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

    /// A drag or shift-click: the anchor stays, the active corner moves. With
    /// nothing selected it falls back to a plain click.
    func extendSelection(toRow row: UInt64, column: Int) {
        guard let current = selection else { selectCell(row: row, column: column); return }
        selection = selectionModel.extend(current, to: GridCell(row: row, column: column), in: selectionExtent())
    }

    /// The arrow / page / document / line command set, plain or shift-extending.
    /// The grid supplies the viewport-derived context; the reducer owns the
    /// seeding, the visible-column stepping and the clamping, composing the SAME
    /// selection geometry rather than duplicating it.
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

    func selectWholeRow(_ row: UInt64) {
        selection = selectionModel.wholeRow(row, in: selectionExtent())
    }

    /// Plain gutter clicks toggle only an identical whole-row selection.
    func toggleWholeRow(_ row: UInt64) {
        let candidate = selectionModel.wholeRow(row, in: selectionExtent())
        selection = selection == candidate ? nil : candidate
    }

    func selectWholeColumn(_ column: Int) {
        selection = selectionModel.wholeColumn(column, in: selectionExtent())
    }

    /// Plain header clicks toggle only an identical whole-column selection.
    func toggleWholeColumn(_ column: Int) {
        let candidate = selectionModel.wholeColumn(column, in: selectionExtent())
        selection = selection == candidate ? nil : candidate
    }

    /// Shift-click on the gutter: keep the anchor, extend to the clicked row
    /// across every column.
    func extendSelectionToWholeRow(_ row: UInt64) {
        guard let current = selection else { selectWholeRow(row); return }
        let extent = selectionExtent()
        guard !extent.isEmpty else { return }
        selection = selectionModel.extend(current, to: GridCell(row: row, column: extent.lastColumn), in: extent)
    }

    /// Shift-click on the header — the whole-column analog.
    func extendSelectionToWholeColumn(_ column: Int) {
        guard let current = selection else { selectWholeColumn(column); return }
        let extent = selectionExtent()
        guard !extent.isEmpty else { return }
        selection = selectionModel.extend(current, to: GridCell(row: extent.lastRow, column: column), in: extent)
    }

    /// Cmd+A: the whole extent, O(1) for any document size.
    func selectAll() {
        selection = selectionModel.selectAll(in: selectionExtent())
    }

    /// Per-column selection-overlay state for a data row, precomputed so the row
    /// view's draw makes no per-cell model call.
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

    // MARK: - Column resize + auto-fit

    /// The width actually drawn for an absolute column: the manual override if
    /// present, else the auto baseline.
    func effectiveWidth(_ column: Int) -> CGFloat {
        if let manual = manualColumnWidths[column] { return CGFloat(manual) }
        return column < columnWidths.count ? columnWidths[column] : GridMetrics.minColumnWidth
    }

    /// Drag-resize. `windowIndex` is a position in the CURRENT column window —
    /// exactly what the grid hit-tests the trailing hairline against — so
    /// resolving the absolute column and its cache slot needs no search. The
    /// manual width then sticks: auto-grow skips the column from here on.
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

    /// Double-click auto-fit: clears the manual override AND resets the auto
    /// baseline to the exact fit over the VISIBLE rows, so the column is back in
    /// auto mode at that width and free to grow again as new content scrolls in.
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

    /// Patches the width caches for ONE changed column, so a resize drag never
    /// pays the full rebuild. `windowIndex` maps to its visible position with no
    /// search, by construction of `windowColumns()`. A no-op while the caches are
    /// already stale — the pending rebuild picks up the fresh value itself.
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

    /// The measured pixel widths — the header plus each VISIBLE row's cell — for
    /// one absolute column, padding included. Mirrors `growColumnWidthsToFitWindow`
    /// exactly (same fonts, same padding, same oversized and truncated
    /// exclusions), so a double-click and the passive auto-grow agree on what
    /// "fits".
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
