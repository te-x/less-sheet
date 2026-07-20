// Scroll-driven paging + visible-row (re)configuration and highlights.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {
    // MARK: Scroll handling (paging + sync + probes)

    @objc func clipBoundsChanged() {
        let clip = scroll.contentView

        // Gate the scroll-driven column fit on REAL viewport movement. The
        // row-window paging (`viewportChanged`), the horizontal column window
        // (`refreshColumnWindow`), and the table/filler width
        // (`refreshColumnWidth`) are a pure function of the visible-window
        // identity below — so a clip-bounds tick that moves none of it (a
        // top/bottom/side elastic bounce, whose whole travel is past a hard
        // edge) must not re-derive them: that re-derivation is the only thing
        // that could churn an established column width (the reported
        // "columns resize on first interaction" when already at the top). The
        // overscroll bail makes the same point explicitly for the in-flight
        // bounce: while the viewport is pinned past an edge it cannot reveal
        // new rows/columns, so the fit is deferred to the settling tick that
        // lands back in range. The downstream window/width guards are no-ops on
        // an unchanged window too, but gating here keeps the bounce from ever
        // reaching `growColumnWidthsToFitWindow` in the first place.
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
            // Page the core window to the visible span (O(1) setWindow off the
            // scroll path; hysteresis lives in the model).
            if visible.length > 0 {
                let first = min(visible.location, max(0, dataRowCount - 1))
                model.viewportChanged(firstVisibleRow: first, visibleRowCount: visible.length)
            }
        }

        // The row-number gutter may widen when bigger numbers scroll in — a
        // full relayout (frames + column/filler width) when it does. Runs
        // regardless of the fit gate above: a gutter change IS a real geometry
        // change, and `layoutContainer` re-derives the window/width itself.
        let measuredGutterWidth = model.rowNumberColumnWidth()
        if abs(measuredGutterWidth - gutterWidth) > 0.5 {
            gutterWidth = measuredGutterWidth
            layoutContainer()
        }
        if fitViewport {
            // The clip's OWN width can also change independent of the gutter —
            // e.g. a vertical scroller inserting/removing itself as the
            // row-count estimate crosses its need threshold (this can settle a
            // tick AFTER `layoutContainer` last read
            // `scroll.contentView.bounds.width`, since that read races the
            // scroller's own internal tile — PROVEN by LESSSHEET_LOG_COLWIDTH: a
            // "layout" reading can show `colwidth` matching a since-shrunk
            // `viewport` one tick later; that width change moves `identity.width`
            // above, so this branch runs). Re-sync the column/filler width to
            // the FRESH, now-settled clip width (cheap: O(visibleColumns)) so a
            // stale, too-wide `column.width` can never linger and force a
            // spurious horizontal scroller (or hide a genuine one) —
            // `layoutContainer` already covers this when the gutter branch above
            // ran; harmless to re-run.
            //
            // Re-derive the horizontal column window for the CURRENT scroll x,
            // so a horizontal drag/fling reveals newly-in-window columns
            // (measured, fetched, drawn) exactly like `viewportChanged` does for
            // a vertical one — O(window), never O(columnCount)
            // (ARCH-column-windowing); a no-op once the window and widths
            // settle. Already re-derived by `layoutContainer` when the gutter
            // branch above ran; harmless (cheap) to re-run against the settled
            // clip.
            refreshColumnWindow()
            refreshColumnWidth(site: "scroll")
        }

        header.contentOffsetX = clip.bounds.origin.x
        header.needsDisplay = true
        gutter.needsDisplay = true

        // Flush a row-count-estimate reload `apply()` deferred while this same
        // clip was mid an elastic overscroll bounce (see `syncRowCountEstimate`):
        // EVERY scroll tick lands here, including the bounce's settling one, so
        // this is how a deferred reload gets applied the instant it is safe
        // again, without waiting for the next poll-driven `apply()`.
        syncRowCountEstimate()

        // Reconfigure the visible rows from the CURRENT window on every scroll,
        // not only when the window identity changes. During a fast fling a row
        // view is configured empty while the window lags; when the fling settles
        // inside a window that already covers those rows, no window-change refresh
        // fires — so without this they stay blank until recycled by another
        // scroll (the reported gaps). configure is O(viewport); cheap per tick.
        refreshVisibleRows()

        ScrollProbe.note(clip.bounds.origin)        // inert unless LESSSHEET_LOG_OFFSET
        emitLayoutFramesIfEnabled()
    }

    // MARK: Row refresh (data / highlights)

    /// Forces the grid's already-marked-dirty viewport (rows, header, gutter)
    /// to draw synchronously, without waiting for the next event in this
    /// window. A column-config or visibility mutation arrives from the SEPARATE
    /// (key) Settings window; SwiftUI observation still re-runs `GridView.body`
    /// -> `apply()` promptly on the main actor, and the branches above mark the
    /// affected cells/columns needsDisplay — but AppKit only flushes that draw
    /// for a non-key window on its next event (the reported "instant in the
    /// header, but the data waits for a click"). `displayIfNeeded` repaints just
    /// what is dirty in the visible viewport (O(viewport), never a full-file
    /// rescan) and is a no-op when nothing is dirty, so the config path is
    /// instant while the scroll path — which never calls this — pays nothing.
    func flushGridDisplay() {
        table.displayIfNeeded()
        header.displayIfNeeded()
        gutter.displayIfNeeded()
    }

    func refreshVisibleRows() {
        // Reconfigure EVERY live row view, not just those in the current
        // visibleRect: after a fast fling a row view can be created empty (the
        // viewport outran the window), then sit just off the visible rect when
        // the window catches up — so a visibleRect-only refresh leaves stale
        // gaps that only fill when the row is recycled by another scroll.
        // enumerateAvailableRowViews covers the whole live pool.
        table.enumerateAvailableRowViews { rowView, row in
            if let sheetRow = rowView as? SheetRowView {
                self.configure(sheetRow, row: row)
                sheetRow.needsDisplay = true
            }
        }
        gutter.needsDisplay = true
    }

    /// Recomputes only the configured logical column in each recycled row and
    /// invalidates only that subcolumn's rectangle. There is one physical
    /// NSTableColumn, so NSTableView's column-index reload API would reload the
    /// whole custom row; this is the equivalent targeted path for our packed
    /// logical columns.
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

    /// A one-column width remeasure can shift following pixels, but it does
    /// not require recomputing their cell presentations. Refresh geometry,
    /// update only the configured column's arrays, and invalidate the shifted
    /// suffix. A rare horizontal-window boundary change falls back globally.
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

        // An upstream off-window width changes the exact prefix-sum origin
        // while leaving the visible IDs untouched. In that case every visible
        // cell moved, so repaint the shifted viewport (presentations remain
        // reusable). Otherwise invalidate only from the first changed visible
        // width; the common in-window edit therefore stays a suffix repaint.
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
            // Not-yet-servable (within the estimated range but past the
            // materialized scan frontier): `windowBodyCells` already empty-
            // pads it exactly like a genuinely empty row, so this flag is
            // what lets the row view tell the two apart and draw a loading
            // placeholder instead of silently blank cells (PROJECT: constant
            // feedback, no silent stalls).
            rowView.pending = !model.rowLoaded(forRow: row)
            // Column-WINDOW bound (ARCH-column-windowing) — O(window), never
            // O(columnCount): the live grid only ever needs the columns it is
            // about to draw, unlike the eager dump grid (FrameDump).
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
