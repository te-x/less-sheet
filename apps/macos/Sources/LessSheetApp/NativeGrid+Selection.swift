// Cell, row and column selection, copy, and column resize.
import AppKit
import Contracts
import LessSheetKit
import SwiftUI

extension NativeGridController {

    // Mouse and keyboard events, plus the responder chain's standard
    // `selectAll:` and `copy:`, drive the pure selection and sizing models on
    // `DocumentModel`. This file only maps AppKit geometry to and from the
    // (row, column) and window-index space those models speak. The header owns
    // its own resize hit-testing; the shared row/column arithmetic is here.

    /// The cell under a point in the TABLE's local space — the read side of the
    /// row view's own layout, since one real `NSTableColumn` carries every
    /// custom-drawn column and AppKit has no per-sub-column hit test. Clamps to
    /// the nearest data row and in-window column, so dragging past an edge
    /// extends to that edge.
    func cellAt(_ point: NSPoint) -> GridCell? {
        guard let index = windowColumnIndex(atX: point.x), index < absoluteColumns.count else { return nil }
        return GridCell(row: UInt64(rowAt(point)), column: absoluteColumns[index])
    }

    /// The data row at a table-local point, clamped so it never lands in the
    /// filler strip or below row 0.
    func rowAt(_ point: NSPoint) -> Int {
        guard dataRowCount > 0 else { return 0 }
        if point.y < 0 { return 0 }
        let row = table.row(at: point)
        return row < 0 ? dataRowCount - 1 : min(row, dataRowCount - 1)
    }

    /// The window-local index at an x-offset in the TABLE's coordinate space,
    /// walking the same sequential accumulation the row view uses to position
    /// each column. Clamps to the nearest edge column past the window's ends.
    func windowColumnIndex(atX offsetX: CGFloat) -> Int? {
        guard !widths.isEmpty else { return nil }
        var cursor = columnFirstX
        for (index, width) in widths.enumerated() {
            if offsetX < cursor + width { return index }
            cursor += width
        }
        return widths.count - 1
    }

    /// Plain click selects, shift-click extends. Makes the table first responder
    /// so keyboard navigation and ⌘A / ⌘C follow immediately.
    func mouseDown(_ event: NSEvent, in view: NSView) {
        container.window?.makeFirstResponder(table)
        guard let cell = cellAt(view.convert(event.locationInWindow, from: nil)) else { return }
        cellMouseDown(cell, shift: event.modifierFlags.contains(.shift))
    }

    /// The event-free seam the headless probe drives; the mouse path maps
    /// coordinates once and then runs this exact transition.
    func cellMouseDown(_ cell: GridCell, shift: Bool) {
        if shift {
            pendingCellToggle = nil
            model.extendSelection(toRow: cell.row, column: cell.column)
        } else {
            // Stay selected during mouse-down so a drag still begins at the
            // original anchor; only a mouse-up without a drag deselects.
            pendingCellToggle = model.isOnlySelectedCell(cell) ? cell : nil
            model.selectCell(row: cell.row, column: cell.column)
        }
        refreshSelectionDisplay()
    }

    /// Extends the selection to whatever cell is under the drag point, which
    /// `cellAt` clamps if it is out of bounds.
    func mouseDragged(_ event: NSEvent, in view: NSView) {
        guard let cell = cellAt(view.convert(event.locationInWindow, from: nil)) else { return }
        cellMouseDragged(to: cell)
    }

    func cellMouseDragged(to cell: GridCell) {
        pendingCellToggle = nil
        model.extendSelection(toRow: cell.row, column: cell.column)
        refreshSelectionDisplay()
    }

    /// Completes click-again toggling; a drag has already cleared the candidate,
    /// so ordinary rectangle selection is unaffected.
    func mouseUp(_ event: NSEvent, in view: NSView) {
        cellMouseUp(at: cellAt(view.convert(event.locationInWindow, from: nil)))
    }

    func cellMouseUp(at cell: GridCell?) {
        defer { pendingCellToggle = nil }
        guard let candidate = pendingCellToggle, cell == candidate else { return }
        model.clearSelection()
        refreshSelectionDisplay()
    }

    /// Gutter click: whole-row select, shift-click extends to this row.
    func gutterMouseDown(atY offsetY: CGFloat, shift: Bool) {
        container.window?.makeFirstResponder(table)
        let row = UInt64(rowAt(NSPoint(x: 0, y: offsetY)))
        if shift {
            model.extendSelectionToWholeRow(row)
        } else {
            model.toggleWholeRow(row)
        }
        refreshSelectionDisplay()
    }

    /// Header click outside a resize hit-zone: whole-column select, shift-click
    /// extends. `offsetX` is ABSOLUTE — the same `columnFirstX`-rooted space the
    /// cell path uses, NOT the header's own descrolled local space, which the
    /// header re-bases before calling here.
    func headerMouseDown(atX offsetX: CGFloat, shift: Bool) {
        guard let index = windowColumnIndex(atX: offsetX), index < absoluteColumns.count else { return }
        container.window?.makeFirstResponder(table)
        let column = absoluteColumns[index]
        if shift {
            model.extendSelectionToWholeColumn(column)
        } else {
            model.toggleWholeColumn(column)
        }
        refreshSelectionDisplay()
    }

    /// The header context menu, deep-linked to the clicked column.
    func configureColumnFromHeader(atX offsetX: CGFloat) {
        guard let index = windowColumnIndex(atX: offsetX), index < absoluteColumns.count else { return }
        AppDelegate.shared?.presentSettings(selecting: absoluteColumns[index])
    }

    /// Probe adapter: reveals the requested header horizontally, then takes the
    /// same coordinate route the context-menu action does.
    func configureColumnFromHeaderForProbe(_ column: Int) -> Bool {
        guard ProcessInfo.processInfo.environment["LESSSHEET_SETTINGS_HEADER_LINK"] != nil else { return false }
        let columns = model.visibleColumns
        let allWidths = model.visibleWidths()
        guard let position = columns.firstIndex(of: column), allWidths.indices.contains(position) else { return false }

        let targetX = allWidths.prefix(position).reduce(0, +) + allWidths[position] / 2
        let clip = scroll.contentView
        let revealX = max(0, targetX - clip.bounds.width / 2)
        clip.scroll(to: NSPoint(x: revealX, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        refreshColumnWindow()
        header.contentOffsetX = clip.bounds.origin.x

        guard absoluteColumns.contains(column) else { return false }
        configureColumnFromHeader(atX: targetX)
        return true
    }

    /// ⌘A, via the stock Edit menu's standard responder-chain action.
    func selectAll() {
        model.selectAll()
        refreshSelectionDisplay()
    }

    /// ⌘C, same standard-action path. Nothing to refresh: copying never changes
    /// the selection or the viewport.
    func copySelection() {
        model.copySelection()
    }

    /// Cancels an in-flight copy, exactly like the notice's own Cancel button.
    func cancelCopy() {
        model.cancelCopy()
    }

    /// Esc while the GRID is first responder — the common case once the user has
    /// clicked a cell after searching, or during a scan the field never held
    /// focus for. The precedence lives once, in the pure resolver, which this
    /// dispatches on rather than duplicating. `anyPopupOpen` deliberately
    /// excludes a scanning find field, so that case is OR'd back in here.
    func handleEscape() {
        let action = EscapeResolver().resolve(EscapeContext(
            popupOrSearchActive: model.findFieldActive || model.anyPopupOpen,
            copyInFlight: model.copyInFlight,
            hasSelection: model.selection != nil))
        switch action {
        case .dismissPopups:
            model.dismissPopups()
        case .cancelCopy:
            cancelCopy()
        case .clearSelection:
            model.clearSelection()
            refreshSelectionDisplay()
        case .none:
            break
        }
    }

    /// A selection change alters only overlay geometry, so this deliberately
    /// does NOT call `configure`: reconfiguring re-reads paging state and can
    /// briefly replace already-rendered values with loading placeholders in the
    /// middle of a drag.
    func refreshSelectionDisplay() {
        table.enumerateAvailableRowViews { rowView, row in
            guard let sheetRow = rowView as? SheetRowView else { return }
            sheetRow.selectionMarks = row < self.dataRowCount
                ? self.model.windowSelectionMarks(forRow: row) : []
            sheetRow.needsDisplay = true
        }
        gutter.needsDisplay = true
    }

    // MARK: Column resize + auto-fit
    //
    // Hit-testing and cursor feedback live on the header, which owns that
    // geometry; this is the model hand-off plus the minimal targeted refresh,
    // never a full reload.

    /// The header's own hit-test already resolved `windowIndex`.
    func resizeColumn(windowIndex: Int, toWidth width: CGFloat) {
        model.resizeWindowColumn(windowIndex, toWidth: Double(width))
        refreshAfterWidthChange()
    }

    func autoFitColumn(windowIndex: Int) {
        model.autoFitWindowColumn(windowIndex)
        refreshAfterWidthChange()
        // Auto-fit also resets the column's AUTO baseline, which `apply()`
        // compares against. Syncing it now stops a later, unrelated update cycle
        // from seeing a stale mismatch and paying a full reload for a change
        // already handled here.
        lastColumnWidths = model.columnWidths
    }

    /// Re-syncs exactly what a width change affects, never a full reload: the
    /// window widths and offset, the scrollable column width, and a repaint. The
    /// row views read the fresh widths in their own draw, so no data reload is
    /// needed.
    func refreshAfterWidthChange() {
        refreshLayoutMetrics()
        refreshColumnWindow()
        refreshColumnWidth(site: "resize")
        header.needsDisplay = true
        gutter.needsDisplay = true
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }
}
