// Scroll-driven paging + visible-row (re)configuration and highlights.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {
    // MARK: Scroll handling (paging + sync + probes)

    @objc func clipBoundsChanged() {
        let clip = scroll.contentView

        // Gate the fit on REAL viewport movement. Everything below is a pure
        // function of this identity, so a tick that moves none of it — an
        // elastic bounce whose whole travel is past a hard edge — must not
        // re-derive it: that is the only thing that can churn an established
        // column width. While the viewport is pinned past an edge it cannot
        // reveal new rows or columns either, so the fit waits for the settling
        // tick that lands back in range.
        let visible = table.rows(in: table.visibleRect)
        let over = overscrollAxes()
        let identity = GridFitViewport(top: currentTopDataRow(), length: visible.length,
                                       offsetX: clip.bounds.origin.x, width: clip.bounds.width)
        let moved: Bool = {
            guard let last = lastFitViewport else { return true }
            return last.top != identity.top || last.length != identity.length
                || abs(last.offsetX - identity.offsetX) > 0.5 || abs(last.width - identity.width) > 0.5
        }()
        let fitViewport = moved && !over.x && !over.y

        if fitViewport {
            lastFitViewport = identity
            // The hysteresis that decides whether this actually re-pages lives
            // in the model.
            if visible.length > 0 {
                let first = min(visible.location, max(0, dataRowCount - 1))
                model.viewportChanged(firstVisibleRow: first, visibleRowCount: visible.length)
            }
        }

        // The gutter widens when bigger numbers scroll in. Runs regardless of the
        // fit gate: a gutter change IS a real geometry change.
        let measuredGutterWidth = model.rowNumberColumnWidth()
        if abs(measuredGutterWidth - gutterWidth) > 0.5 {
            gutterWidth = measuredGutterWidth
            layoutContainer()
        }
        if fitViewport {
            // Re-derive against the now-settled clip. The clip's OWN width can
            // change independently of the gutter — a vertical scroller inserting
            // itself as the row-count estimate crosses its threshold — and that
            // settles a tick AFTER `layoutContainer` last read the width, since
            // that read races the scroller's own tile. Re-syncing here is what
            // stops a stale, too-wide column width from forcing a spurious
            // horizontal scroller (or hiding a genuine one), and gives a
            // horizontal fling the same newly-revealed-column treatment a
            // vertical scroll already gets.
            refreshColumnWindow()
            refreshColumnWidth(site: "scroll")
        }

        header.contentOffsetX = clip.bounds.origin.x
        header.needsDisplay = true
        gutter.needsDisplay = true

        // Every scroll tick lands here, the settling one included, so this is how
        // a reload deferred during an elastic bounce gets applied the instant it
        // is safe again.
        syncRowCountEstimate()

        // On EVERY scroll, not only when the window identity changes: during a
        // fast fling a row view is configured empty while the window lags, and if
        // the fling then settles inside a window that already covers those rows,
        // no window-change refresh fires and they stay blank until some later
        // scroll recycles them.
        refreshVisibleRows()

        ScrollProbe.note(clip.bounds.origin)        // inert unless LESSSHEET_LOG_OFFSET
        emitLayoutFramesIfEnabled()
    }

    // MARK: Row refresh (data / highlights)

    /// Draws the already-dirty viewport synchronously, without waiting for this
    /// window's next event. A Settings-window edit marks cells `needsDisplay`,
    /// but AppKit flushes that for a NON-KEY window only on its next event — so
    /// the header would update instantly while the data waited for a click.
    /// A no-op when nothing is dirty, and the scroll path never calls it.
    func flushGridDisplay() {
        table.displayIfNeeded()
        header.displayIfNeeded()
        gutter.displayIfNeeded()
    }

    func refreshVisibleRows() {
        // EVERY live row view, not just those in the current visible rect: after
        // a fling a row created empty can sit just off it when the window catches
        // up, and a visible-rect-only refresh would leave that gap until some
        // later scroll recycled it.
        table.enumerateAvailableRowViews { rowView, row in
            if let sheetRow = rowView as? SheetRowView {
                self.configure(sheetRow, row: row)
                sheetRow.needsDisplay = true
            }
        }
        gutter.needsDisplay = true
    }

    /// Recomputes only the configured column in each recycled row, and
    /// invalidates only that sub-column's rectangle. There is one physical
    /// `NSTableColumn`, so AppKit's own column-index reload would repaint the
    /// whole row; this is the equivalent targeted path.
    func refreshConfiguredColumns(_ columns: Set<Int>) {
        let targets = absoluteColumns.enumerated().filter { columns.contains($0.element) }
        guard !targets.isEmpty else { return }
        for (index, column) in targets where columnAlignments.indices.contains(index) {
            columnAlignments[index] = model.columnAlignment(column)
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard row < self.dataRowCount, let sheetRow = rowView as? SheetRowView else { return }
            for (index, column) in targets where sheetRow.cells.indices.contains(index) {
                let presentation = self.model.windowCellPresentation(forRow: row, column: column)
                sheetRow.cells[index] = presentation.text
                if sheetRow.formatUnavailable.indices.contains(index) {
                    sheetRow.formatUnavailable[index] = presentation.formatUnavailable
                }
                if sheetRow.conflicts.indices.contains(index) { sheetRow.conflicts[index] = presentation.conflict }
                self.refreshAccessibilityWarning(sheetRow, row: row, index: index)
                let rect = self.logicalCellRect(index: index, height: sheetRow.bounds.height)
                sheetRow.setNeedsDisplay(rect)
            }
            self.applyAccessibilityLabel(sheetRow, row: row)
        }
    }

    /// A one-column width change shifts the pixels after it without changing
    /// their content, so only the geometry is refreshed and only the shifted
    /// suffix invalidated. A horizontal-window boundary change falls back to a
    /// full reload.
    func refreshConfiguredColumnWidths(_ columns: Set<Int>) {
        let oldColumns = absoluteColumns
        let oldFirstX = columnFirstX
        let oldWidths = widths
        refreshLayoutMetrics()
        refreshColumnWindow()
        refreshColumnWidth(site: "column-config")
        guard absoluteColumns == oldColumns else {
            table.reloadData()
            refreshVisibleRows()
            header.needsDisplay = true
            return
        }
        refreshConfiguredColumns(columns)

        // An off-window width change moves the prefix-sum origin while leaving
        // the visible ids untouched, so every visible cell shifted. Otherwise
        // only the suffix from the first changed width needs repainting.
        if columnFirstX != oldFirstX {
            invalidateVisibleGeometry()
        } else if let firstChangedWidth = widths.indices.first(where: {
            !oldWidths.indices.contains($0) || oldWidths[$0] != widths[$0]
        }) {
            invalidateVisibleGeometry(from: firstChangedWidth)
        }
    }

    func invalidateVisibleGeometry(from index: Int? = nil) {
        table.enumerateAvailableRowViews { rowView, _ in
            guard let index else {
                rowView.setNeedsDisplay(rowView.bounds)
                return
            }
            let rect = self.logicalCellRect(index: index, height: rowView.bounds.height)
            rowView.setNeedsDisplay(NSRect(x: rect.minX, y: 0,
                                           width: max(0, rowView.bounds.maxX - rect.minX),
                                           height: rowView.bounds.height))
        }
        guard let index else {
            header.setNeedsDisplay(header.bounds)
            return
        }
        let rect = logicalCellRect(index: index, height: header.bounds.height)
        let localX = rect.minX - header.contentOffsetX
        header.setNeedsDisplay(NSRect(x: localX, y: 0,
                                      width: max(0, header.bounds.maxX - localX),
                                      height: header.bounds.height))
    }

    func logicalCellRect(index: Int, height: CGFloat) -> NSRect {
        var originX = columnFirstX
        if index > 0 { originX += widths.prefix(index).reduce(0, +) }
        let width = widths.indices.contains(index) ? widths[index] : 0
        return NSRect(x: originX, y: 0, width: width, height: height)
    }

    func configure(_ rowView: SheetRowView, row: Int) {
        rowView.controller = self
        if row < dataRowCount {
            rowView.isFiller = false
            // A not-yet-servable row is empty-padded exactly like a genuinely
            // empty one, so this flag is the only thing that lets the row view
            // draw a loading placeholder rather than silently blank cells.
            rowView.pending = !model.rowLoaded(forRow: row)
            let presentations = model.windowCellPresentations(forRow: row)
            rowView.cells = presentations.map(\.text)
            rowView.formatUnavailable = presentations.map(\.formatUnavailable)
            rowView.conflicts = presentations.map(\.conflict)
            rowView.truncated = model.windowBodyTruncated(forRow: row)
            rowView.highlights = model.windowCellHighlights(forRow: row)
            rowView.selectionMarks = model.windowSelectionMarks(forRow: row)
        } else {
            rowView.isFiller = true
            rowView.pending = false
            rowView.cells = []
            rowView.formatUnavailable = []
            rowView.conflicts = []
            rowView.truncated = []
            rowView.highlights = []
            rowView.selectionMarks = []
        }
        rowView.accessibilityWarnings.removeAll(keepingCapacity: true)
        for index in rowView.cells.indices { refreshAccessibilityWarning(rowView, row: row, index: index) }
        applyAccessibilityLabel(rowView, row: row)
    }

    func refreshAccessibilityWarning(_ rowView: SheetRowView, row: Int, index: Int) {
        var value = [String]()
        if index < rowView.truncated.count, rowView.truncated[index] { value.append("value truncated") }
        if index < rowView.conflicts.count, rowView.conflicts[index] { value.append("type conflict") }
        if index < rowView.formatUnavailable.count, rowView.formatUnavailable[index] {
            value.append("format unavailable")
        }
        guard !value.isEmpty else {
            rowView.accessibilityWarnings.removeValue(forKey: index)
            return
        }
        let column = index < absoluteColumns.count ? absoluteColumns[index] + 1 : index + 1
        rowView.accessibilityWarnings[index] = "column \(column) \(value.joined(separator: ", "))"
    }

    func applyAccessibilityLabel(_ rowView: SheetRowView, row: Int) {
        let states = rowView.accessibilityWarnings.keys.sorted().compactMap { rowView.accessibilityWarnings[$0] }
        rowView.setAccessibilityElement(true)
        rowView.setAccessibilityRole(.row)
        rowView.setAccessibilityLabel("Row \(row + 1)" + (states.isEmpty ? "" : ", \(states.joined(separator: ", "))"))
    }
}
