// Cell/row/column selection, copy, and column resize for NativeGridController.
// Split out of NativeGrid.swift purely to satisfy file/type length limits.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {

    // MARK: Selection + copy + resize (ARCH-select-copy) — NSResponder mouse/
    // keyboard events (SheetTableView/GridHeaderView/GridGutterView) + the
    // responder chain's standard selectAll:/copy: actions drive the pure
    // `Selecting`/`CopyBuilding`/`ColumnSizing` models on `DocumentModel`;
    // this section only maps AppKit geometry <-> the pure (row, column) /
    // window-index space those models speak. Column resize hit-testing lives
    // on `GridHeaderView` itself (it owns the header's own geometry/cursor
    // rects); this section is the shared row/column arithmetic + the model
    // hand-off both the header and the data table route through.

    /// Maps a point in the TABLE's local coordinate space to the (row,
    /// column) cell under it — the read-side of `SheetRowView.draw`'s layout
    /// (there is no native per-subcolumn hit test: one real `NSTableColumn`
    /// carries every custom-drawn visible column). Clamps to the nearest
    /// data row / in-window column when the point falls outside them
    /// (dragging past an edge extends to that edge — ordinary spreadsheet
    /// drag behavior); nil only when the column window is empty.
    func cellAt(_ point: NSPoint) -> GridCell? {
        guard let index = windowColumnIndex(atX: point.x), index < absoluteColumns.count else { return nil }
        return GridCell(row: UInt64(rowAt(point)), column: absoluteColumns[index])
    }

    /// The data row at a TABLE-local point, clamped to `0 ..< dataRowCount`
    /// (never into the filler/overscroll strip, and never below row 0 for a
    /// point above the table's own top edge).
    func rowAt(_ point: NSPoint) -> Int {
        guard dataRowCount > 0 else { return 0 }
        if point.y < 0 { return 0 }
        let row = table.row(at: point)
        return row < 0 ? dataRowCount - 1 : min(row, dataRowCount - 1)
    }

    /// The window-local index (into `widths`/`absoluteColumns`) at a LOCAL
    /// x-offset in the TABLE's (== `columnFirstX`'s) coordinate space, via
    /// the SAME sequential accumulation `SheetRowView.draw` uses to POSITION
    /// each column. Clamps to the nearest edge column past the window's
    /// start/end (a scrolled dead zone or the filler strip); nil only when
    /// the window holds no columns.
    func windowColumnIndex(atX offsetX: CGFloat) -> Int? {
        guard !widths.isEmpty else { return nil }
        var cursor = columnFirstX
        for (index, width) in widths.enumerated() {
            if offsetX < cursor + width { return index }
            cursor += width
        }
        return widths.count - 1
    }

    /// Mouse down on a data cell (`SheetTableView`): plain click selects it;
    /// shift-click extends the live selection. Makes the table first
    /// responder so keyboard navigation / Cmd+A / Cmd+C follow immediately.
    func mouseDown(_ event: NSEvent, in view: NSView) {
        container.window?.makeFirstResponder(table)
        guard let cell = cellAt(view.convert(event.locationInWindow, from: nil)) else { return }
        cellMouseDown(cell, shift: event.modifierFlags.contains(.shift))
    }

    /// Event-free semantic seam used by the headless native-grid probe. The
    /// shipping mouse path maps AppKit coordinates once, then runs this exact
    /// transition.
    func cellMouseDown(_ cell: GridCell, shift: Bool) {
        if shift {
            pendingCellToggle = nil
            model.extendSelection(toRow: cell.row, column: cell.column)
        } else {
            // Keep the cell selected during mouse-down so a drag still begins
            // at the original anchor. Only mouse-up without a drag performs
            // the click-again deselection.
            pendingCellToggle = model.isOnlySelectedCell(cell) ? cell : nil
            model.selectCell(row: cell.row, column: cell.column)
        }
        refreshSelectionDisplay()
    }

    /// Drag over the data cells: extends the selection live to whatever cell
    /// is under the (possibly out-of-bounds) drag point — `cellAt` clamps.
    func mouseDragged(_ event: NSEvent, in view: NSView) {
        guard let cell = cellAt(view.convert(event.locationInWindow, from: nil)) else { return }
        cellMouseDragged(to: cell)
    }

    func cellMouseDragged(to cell: GridCell) {
        pendingCellToggle = nil
        model.extendSelection(toRow: cell.row, column: cell.column)
        refreshSelectionDisplay()
    }

    /// Mouse up completes click-again toggling. A drag clears the pending
    /// candidate above, preserving ordinary rectangle selection semantics.
    func mouseUp(_ event: NSEvent, in view: NSView) {
        cellMouseUp(at: cellAt(view.convert(event.locationInWindow, from: nil)))
    }

    func cellMouseUp(at cell: GridCell?) {
        defer { pendingCellToggle = nil }
        guard let candidate = pendingCellToggle, cell == candidate else { return }
        model.clearSelection()
        refreshSelectionDisplay()
    }

    /// Gutter click: whole-row select; shift-click extends a whole-row
    /// selection to this row (ARCH: composed from `extend(_:to:in:)`).
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

    /// Header click OUTSIDE a resize hit-zone: whole-column select;
    /// shift-click extends a whole-column selection to this column. `x` is
    /// ABSOLUTE — the SAME `columnFirstX`-rooted space `windowColumnIndex`/
    /// `cellAt` already use, NOT `GridHeaderView`'s own descrolled local
    /// space; `GridHeaderView.handleClick` re-bases its local click x to this
    /// space (`+ contentOffsetX`) before calling here (ARCH-select-copy round
    /// 2, finding 1 — a prior version of that call passed the raw local x,
    /// which only ever matched this absolute space at zero horizontal
    /// scroll).
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

    /// Header context-menu entry into the sole Settings surface, deep-linked
    /// to the clicked absolute column.
    func configureColumnFromHeader(atX offsetX: CGFloat) {
        guard let index = windowColumnIndex(atX: offsetX), index < absoluteColumns.count else { return }
        AppDelegate.shared?.presentSettings(selecting: absoluteColumns[index])
    }

    /// Opt-in probe adapter: horizontally reveals the requested real header,
    /// then invokes the same coordinate hit route as its context-menu action.
    /// Returns false if no rendered header can represent the requested column.
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

    /// Arrow / shift-arrow (via `SheetTableView`'s `NSStandardKeyBindingResponding`
    /// overrides — `interpretKeyEvents` does the key -> action translation,
    /// framework-native).
    func moveSelection(_ direction: SelectionDirection, extending: Bool) {
        model.moveSelection(direction, extending: extending)
        refreshSelectionDisplay()
    }

    /// Cmd+A (via `SheetTableView.selectAll(_:)`, the standard responder-chain
    /// action the stock Edit menu already sends — no custom menu wiring).
    func selectAll() {
        model.selectAll()
        refreshSelectionDisplay()
    }

    /// Cmd+C (via `SheetTableView.copy(_:)`, same standard-action path as
    /// `selectAll`): kicks off the off-main copy build; see
    /// `DocumentModel.copySelection`. Nothing to refresh here — copying
    /// never changes the selection or the viewport.
    func copySelection() {
        model.copySelection()
    }

    /// Esc (via `SheetTableView.cancelOperation(_:)` — ARCH-select-copy
    /// round 2, finding 2): cancels an in-flight copy exactly like the
    /// notice's own Cancel button; see `DocumentModel.cancelCopy`. A no-op
    /// when nothing is copying, so Esc otherwise behaves exactly as before.
    func cancelCopy() {
        model.cancelCopy()
    }

    /// Esc while the GRID itself is first responder (focus has left the find /
    /// jump popup field — the common case once the user clicks a cell after
    /// searching, or during a scan when the field never held focus). The primary
    /// "escape from search": dismiss an open find / jump / dialect popup —
    /// clearing an active search and its highlights, exactly like clicking the
    /// dismiss scrim (`PopupDismissScrimView.mouseDown` → `dismissPopups`). With
    /// no popup open it falls back to cancelling an in-flight copy (the prior
    /// sole behavior of `SheetTableView.cancelOperation`). `anyPopupOpen`
    /// excludes a scanning find field by design (scrim stays off mid-scan), so
    /// `findFieldActive` is OR'd in to cover that case too.
    func handleEscape() {
        if model.findFieldActive || model.anyPopupOpen {
            model.dismissPopups()
        } else {
            cancelCopy()
        }
    }

    /// Selection changes alter only overlay geometry. Recompute marks and
    /// repaint the recycled rows without calling `configure`: reconfiguration
    /// re-reads paging state and could transiently replace already-rendered
    /// values with loading placeholders while a drag is in progress.
    func refreshSelectionDisplay() {
        table.enumerateAvailableRowViews { rowView, row in
            guard let sheetRow = rowView as? SheetRowView else { return }
            sheetRow.selectionMarks = row < self.dataRowCount
                ? self.model.windowSelectionMarks(forRow: row) : []
            sheetRow.needsDisplay = true
        }
        gutter.needsDisplay = true
    }

    // MARK: Column resize + auto-fit (ARCH-select-copy AC5) — hit-testing and
    // cursor feedback live on `GridHeaderView` (it owns the header's
    // geometry); this is the O(1) model hand-off + the minimal targeted
    // AppKit refresh, never a `reloadData()`/full relayout.

    /// Drag-resize: `windowIndex` is a position in `widths` (the header's own
    /// hit-test already resolved which one); forwards to the model (O(1))
    /// then does the minimal AppKit refresh a width change needs.
    func resizeColumn(windowIndex: Int, toWidth width: CGFloat) {
        model.resizeWindowColumn(windowIndex, toWidth: Double(width))
        refreshAfterWidthChange()
    }

    /// Double-click auto-fit: forwards to the model (O(visible rows) to
    /// measure, per the contract) then the same minimal refresh as a resize.
    func autoFitColumn(windowIndex: Int) {
        model.autoFitWindowColumn(windowIndex)
        refreshAfterWidthChange()
        // The auto-fit ALSO resets the column's auto baseline
        // (`columnWidths`), which `apply()`'s change-detection compares
        // against `lastColumnWidths` — sync it now so a LATER, unrelated
        // SwiftUI update cycle never sees a stale mismatch and pays a
        // surprise full `reloadData()` for a change already handled here.
        lastColumnWidths = model.columnWidths
    }

    /// O(1)/O(window) re-sync of exactly what a width change affects — never
    /// a `table.reloadData()` (ARCH AC5: "O(1) per resize... no all-column
    /// relayout"): re-pull this tick's window widths/offset + gutter/total
    /// width, resize the scrollable column/filler count to the fresh total,
    /// and repaint the header + visible rows (their OWN `draw` reads the
    /// fresh `widths`/`c.widths` arrays, so no data reload is needed).
    func refreshAfterWidthChange() {
        refreshLayoutMetrics()
        refreshColumnWindow()
        refreshColumnWidth(site: "resize")
        header.needsDisplay = true
        gutter.needsDisplay = true
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }
}
