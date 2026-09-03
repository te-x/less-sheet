// Keyboard cell navigation: the key overrides that route the arrow, page,
// document and line commands through the pure navigator, and the hand-off that
// applies the result and scrolls the minimum needed. The geometry itself is
// gate-tested in LessSheetKit; this file is the display-dependent residue.
import AppKit
import Contracts
import LessSheetKit

// MARK: - SheetTableView key routing (interpretKeyEvents -> NavigationMotion)

/// Every navigation key AppKit's binding table can fire maps onto exactly one
/// motion. The pure navigator owns the geometry, so which selector a given
/// physical key resolves to is a routing detail rather than a correctness risk —
/// which is why both the `scrollTo…` and `moveTo…` families are bound for the
/// document and line targets.
extension SheetTableView {
    override func moveUp(_ sender: Any?) { controller?.navigate(.upward, extending: false) }
    override func moveDown(_ sender: Any?) { controller?.navigate(.down, extending: false) }
    override func moveLeft(_ sender: Any?) { controller?.navigate(.left, extending: false) }
    override func moveRight(_ sender: Any?) { controller?.navigate(.right, extending: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { controller?.navigate(.upward, extending: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { controller?.navigate(.down, extending: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { controller?.navigate(.left, extending: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { controller?.navigate(.right, extending: true) }

    override func pageUp(_ sender: Any?) { controller?.navigate(.pageUp, extending: false) }
    override func pageDown(_ sender: Any?) { controller?.navigate(.pageDown, extending: false) }
    override func scrollPageUp(_ sender: Any?) { controller?.navigate(.pageUp, extending: false) }
    override func scrollPageDown(_ sender: Any?) { controller?.navigate(.pageDown, extending: false) }
    override func pageUpAndModifySelection(_ sender: Any?) { controller?.navigate(.pageUp, extending: true) }
    override func pageDownAndModifySelection(_ sender: Any?) { controller?.navigate(.pageDown, extending: true) }

    override func moveToBeginningOfDocument(_ sender: Any?) { controller?.navigate(.documentStart, extending: false) }
    override func moveToEndOfDocument(_ sender: Any?) { controller?.navigate(.documentEnd, extending: false) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { controller?.navigate(.documentStart, extending: false) }
    override func scrollToEndOfDocument(_ sender: Any?) { controller?.navigate(.documentEnd, extending: false) }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        controller?.navigate(.documentStart, extending: true)
    }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        controller?.navigate(.documentEnd, extending: true)
    }

    override func moveToLeftEndOfLine(_ sender: Any?) { controller?.navigate(.lineStart, extending: false) }
    override func moveToRightEndOfLine(_ sender: Any?) { controller?.navigate(.lineEnd, extending: false) }
    override func moveToBeginningOfLine(_ sender: Any?) { controller?.navigate(.lineStart, extending: false) }
    override func moveToEndOfLine(_ sender: Any?) { controller?.navigate(.lineEnd, extending: false) }
    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        controller?.navigate(.lineStart, extending: true)
    }
    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        controller?.navigate(.lineEnd, extending: true)
    }
}

// MARK: - Controller hand-off (pure reducer -> selection + minimal reveal)

extension NativeGridController {
    /// Assembles the viewport-derived context, lets the pure navigator produce
    /// the new selection, repaints, then scrolls the MINIMUM needed to keep the
    /// active cell visible.
    func navigate(_ motion: NavigationMotion, extending: Bool) {
        model.navigate(motion, extending: extending,
                       topVisibleRow: UInt64(currentTopDataRow()),
                       firstVisibleColumn: absoluteColumns.first ?? 0,
                       pageRows: pageRows())
        refreshSelectionDisplay()
        revealActiveCell()
    }

    /// The single source for the page step: the UNOBSCURED data height, i.e. the
    /// viewport minus the band inset, over the row height.
    func pageRows() -> UInt64 {
        let clip = scroll.contentView
        let viewportHeight = max(clip.bounds.height, scroll.bounds.height)
        let usable = max(0, viewportHeight - NativeGrid.contentInsetTop)
        return UInt64(max(1, Int(usable / NativeGrid.rowHeight)))
    }

    /// A no-op when the active cell is already visible on both axes. The pure
    /// reveal scroller owns the clamp math; this only assembles the per-axis
    /// descriptors from the live geometry and applies the result.
    func revealActiveCell() {
        guard let active = model.selection?.active else { return }
        let clip = scroll.contentView
        let viewportHeight = max(clip.bounds.height, scroll.bounds.height)
        let contentHeight = CGFloat(numberOfRows(in: table)) * NativeGrid.rowHeight
        let maxY = max(-NativeGrid.contentInsetTop, contentHeight - viewportHeight)
        let vertical = VerticalReveal(
            activeRow: active.row, rowHeight: Double(NativeGrid.rowHeight),
            contentInsetTop: Double(NativeGrid.contentInsetTop),
            originY: Double(clip.bounds.origin.y), viewportHeight: Double(viewportHeight), maxY: Double(maxY))

        let result = RevealScroller().reveal(vertical: vertical,
                                             horizontal: horizontalReveal(forColumn: active.column, clip: clip))
        guard result.moved else { return }
        clip.scroll(to: NSPoint(x: CGFloat(result.originX), y: CGFloat(result.originY)))
        scroll.reflectScrolledClipView(clip)
    }

    /// The column's content-x is the prefix sum of the visible-column widths —
    /// the same content space the clip scrolls in. O(visible columns), which is
    /// fine on a discrete keypress. Falls back to a no-move descriptor for a
    /// column that cannot be resolved, which a visible active column always can.
    private func horizontalReveal(forColumn column: Int, clip: NSClipView) -> HorizontalReveal {
        let originX = Double(clip.bounds.origin.x)
        let viewportWidth = Double(clip.bounds.width)
        let maxX = Double(max(0, table.frame.width - clip.bounds.width))
        let visible = model.visibleColumns
        let widths = model.visibleWidths()
        guard let position = visible.firstIndex(of: column), widths.indices.contains(position) else {
            return HorizontalReveal(leftX: originX, width: 0, originX: originX,
                                    viewportWidth: viewportWidth, maxX: maxX)
        }
        let leftX = widths.prefix(position).reduce(CGFloat(0), +)
        return HorizontalReveal(leftX: Double(leftX), width: Double(widths[position]),
                                originX: originX, viewportWidth: viewportWidth, maxX: maxX)
    }
}
