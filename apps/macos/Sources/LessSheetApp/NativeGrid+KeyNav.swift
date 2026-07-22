// Keyboard cell-navigation wiring (ARCH-macos-kbdnav): the SheetTableView key
// overrides that route the arrow / page / document / line key set through the
// pure `KeyboardNavigator`, plus the controller hand-off that applies the new
// selection and the minimal-reveal auto-scroll (`RevealScroller`). The geometry
// itself is gate-tested in LessSheetKit; this file is the display-dependent
// residue verified by the H1/H4 human GUI pass.
import AppKit
import Contracts
import LessSheetKit

// MARK: - SheetTableView key routing (interpretKeyEvents -> NavigationMotion)

/// Every physical navigation key AppKit's key-binding table can fire maps here
/// onto exactly one `NavigationMotion`, plain or shift-extending; the ONE pure
/// `KeyboardNavigator` (via `controller.navigate`) owns the geometry, so the
/// selector each key actually resolves to is a routing detail, not a
/// correctness risk (ARCH Decision 4). Home/End and Cmd+↑/↓ share the document
/// start/end target (macOS routes Home/End to the `scrollTo…` selectors and
/// Cmd+arrows to the `moveTo…` selectors — both are bound); Cmd+←/→ map to the
/// line start/end. The exact physical-key routing is an H1 human-GUI-pass item.
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
    /// A keyboard navigation command (ARCH-macos-kbdnav FR1/FR2): assemble the
    /// viewport-derived context the model needs (top visible row, leading
    /// visible column, page size), let the pure `KeyboardNavigator` produce the
    /// new selection on the model, repaint the marks, then auto-scroll the
    /// MINIMUM needed to keep the active cell visible via `RevealScroller`. With
    /// nothing selected the reducer seeds the top-left visible cell with no step.
    func navigate(_ motion: NavigationMotion, extending: Bool) {
        model.navigate(motion, extending: extending,
                       topVisibleRow: UInt64(currentTopDataRow()),
                       firstVisibleColumn: absoluteColumns.first ?? 0,
                       pageRows: pageRows())
        refreshSelectionDisplay()
        revealActiveCell()
    }

    /// Data rows per Page Up/Down step — the SINGLE source for the page knob
    /// (ARCH NFR): the unobscured data height (viewport minus the glass band
    /// inset) over `rowHeight`, at least one row.
    func pageRows() -> UInt64 {
        let clip = scroll.contentView
        let viewportHeight = max(clip.bounds.height, scroll.bounds.height)
        let usable = max(0, viewportHeight - NativeGrid.contentInsetTop)
        return UInt64(max(1, Int(usable / NativeGrid.rowHeight)))
    }

    /// Scroll the MINIMUM needed to bring the active cell fully into view
    /// (ARCH-macos-kbdnav FR2), reusing the existing clip-scroll path — a no-op
    /// when the cell is already visible on both axes. The pure `RevealScroller`
    /// owns the clamp math (gate-tested); this only assembles the per-axis
    /// viewport descriptors from the live grid geometry and applies the result.
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

    /// The horizontal reveal descriptor for `column`: its content-x is the
    /// prefix sum of the visible-column widths (the SAME content space the clip
    /// scrolls in — mirrors `configureColumnFromHeaderForProbe`'s reveal), its
    /// width the column's own. O(visible columns) — sanctioned on a discrete
    /// keypress (ARCH NFR). Falls back to a no-move descriptor if the active
    /// column is not resolvable (never for a visible active column).
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
