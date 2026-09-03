// Data table (event routing), sticky column header, and row-number gutter.
import AppKit
import Contracts
import SwiftUI

// MARK: - Data table

/// `NSTableView` already provides row hit-testing and event routing; this
/// subclass adds only what AppKit has no equivalent for — mapping a click's
/// x-offset to one of the custom-drawn sub-columns — by forwarding raw events to
/// the controller. Arrow keys ride AppKit's own key-binding table, and ⌘A / ⌘C
/// the stock Edit menu's standard actions: no key-code parsing, no custom menu
/// items.
final class SheetTableView: NSTableView {
    weak var controller: NativeGridController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(event, in: self)
    }

    override func keyDown(with event: NSEvent) {
        // AppKit's default bindings turn the raw event into one of the motion
        // calls in NativeGrid+KeyNav; anything unhandled beeps or forwards
        // exactly as a plain responder would.
        interpretKeyEvents([event])
    }

    override func selectAll(_ sender: Any?) { controller?.selectAll() }
    // `copy(_:)` is not a declared-overridable method in this SDK, unlike
    // `selectAll(_:)` — it reaches the responder chain purely by Objective-C
    // selector dispatch, so `@objc` rather than `override` is what makes the
    // stock Edit menu's Copy item find it.
    @objc func copy(_ sender: Any?) { controller?.copySelection() }

    // Esc is bound to `cancelOperation(_:)` by the same default key-binding
    // table, so this needs no key parsing either.
    override func cancelOperation(_ sender: Any?) { controller?.handleEscape() }
}

// MARK: - Sticky header (drawn, scrolls horizontally with its columns)

/// The column-title row: transparent, so the glass band shows through and data
/// frosts under it. Its content offset tracks the table's horizontal scroll; it
/// never scrolls vertically. It also owns the resize hit-testing — a click on a
/// column's trailing hairline resizes it, anywhere else selects the column —
/// with AppKit's cursor-rect mechanism doing the pointer feedback.
final class GridHeaderView: NSView {
    weak var controller: NativeGridController?
    var contentOffsetX: CGFloat = 0
    /// Capture-only: fills a semantic material so the titles stay legible in a
    /// dump, where the live glass renders blank.
    var capturesBackground = false

    /// Half-width of the hit-zone straddling a column's trailing hairline — wide
    /// enough to grab reliably, narrow enough not to steal ordinary header clicks.
    private static let resizeHitHalfWidth: CGFloat = 3
    private var resizingIndex: Int?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The column whose TRAILING hairline sits under a header-local x, walking
    /// the same sequential layout `draw` uses, in this view's own already
    /// descrolled space.
    private func resizeIndex(atLocalX localX: CGFloat) -> Int? {
        guard let controller else { return nil }
        var edge = controller.columnFirstX - contentOffsetX
        for (index, width) in controller.widths.enumerated() {
            edge += width
            if abs(localX - edge) <= Self.resizeHitHalfWidth { return index }
        }
        return nil
    }

    override func resetCursorRects() {
        guard let controller else { return }
        var edge = controller.columnFirstX - contentOffsetX
        for width in controller.widths {
            edge += width
            let hitZone = NSRect(x: edge - Self.resizeHitHalfWidth, y: 0,
                                 width: Self.resizeHitHalfWidth * 2, height: bounds.height)
            addCursorRect(hitZone, cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handleClick(atLocalX: point.x, doubleClick: event.clickCount >= 2, shift: event.modifierFlags.contains(.shift))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let controller else { return nil }
        let menu = NSMenu(title: "Column")
        let item = NSMenuItem(title: "Configure Column…", action: #selector(configureColumn(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = point.x + contentOffsetX
        menu.addItem(item)
        controller.container.window?.makeFirstResponder(self)
        return menu
    }

    @objc private func configureColumn(_ sender: NSMenuItem) {
        guard let offsetX = sender.representedObject as? CGFloat else { return }
        controller?.configureColumnFromHeader(atX: offsetX)
    }

    /// The resize-vs-select dispatch, factored out so a probe can drive it with a
    /// known header-local x rather than a synthetic event.
    ///
    /// `localX` is in THIS view's descrolled space, which is what the resize
    /// hit-test wants. The select branch, though, hands off to the controller's
    /// ABSOLUTE space — the same one the data-cell and gutter paths use — so it
    /// must be re-based first. A descrolled x is always <= its absolute
    /// counterpart, so passing it raw silently lands on an earlier column as soon
    /// as the grid is scrolled horizontally.
    func handleClick(atLocalX localX: CGFloat, doubleClick: Bool, shift: Bool) {
        guard let controller else { return }
        if let index = resizeIndex(atLocalX: localX) {
            if doubleClick {
                controller.autoFitColumn(windowIndex: index)
            } else {
                resizingIndex = index
                resizeStartX = localX
                resizeStartWidth = index < controller.widths.count
                    ? controller.widths[index] : GridMetrics.minColumnWidth
            }
            return
        }
        controller.headerMouseDown(atX: localX + contentOffsetX, shift: shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = resizingIndex, let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        controller.resizeColumn(windowIndex: index, toWidth: resizeStartWidth + (point.x - resizeStartX))
    }

    override func mouseUp(with event: NSEvent) {
        resizingIndex = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let height = bounds.height
        if capturesBackground {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        let grid = NSColor.gridColor
        // `widths` is only the current column WINDOW: position it at its exact
        // prefix-sum offset, translated into this fixed view's local space by the
        // same scroll offset the data columns are drawn under.
        var cursorX = controller.columnFirstX - contentOffsetX

        for (columnIndex, width) in controller.widths.enumerated() {
            let cell = NSRect(x: cursorX, y: 0, width: width, height: height)
            if columnIndex < controller.headerLabels.count {
                SheetRowView.drawText(controller.headerLabels[columnIndex],
                                      in: cell.insetBy(dx: GridMetrics.cellHPadding, dy: 0),
                                      font: .systemFont(ofSize: NSFont.systemFontSize), color: .labelColor,
                                      alignment: .left, weight: .semibold)
            }
            if columnIndex < controller.headerTruncated.count, controller.headerTruncated[columnIndex] {
                SheetRowView.drawTruncationMarker(in: cell)
            }
            grid.setFill()
            NSRect(x: cursorX + width - NativeGrid.hairline, y: 0,
                   width: NativeGrid.hairline, height: height).fill()
            cursorX += width
        }
        grid.setFill()
        for _ in 0..<controller.fillerColumns {
            cursorX += GridMetrics.fillerColumnWidth
            NSRect(x: cursorX - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: height).fill()
        }
        NSRect(x: 0, y: height - NativeGrid.hairline, width: bounds.width, height: NativeGrid.hairline).fill()
    }
}

// MARK: - Row-number gutter (fixed left strip, synced to the rows)

/// The 1-based row-number gutter: a fixed left strip that never scrolls
/// horizontally, drawing each visible row's number at that row's live
/// y-position, queried from the table so it stays aligned through scroll and
/// landing. Secondary colour and tabular numerals, so it reads as chrome rather
/// than data. Its frame spans the full window height and sits BEHIND the band,
/// like the scroll view, so a scrolled-up number frosts under it exactly like
/// the data. An oversized row also draws a tinted marker before its number.
final class GridGutterView: NSView, NSViewToolTipOwner {
    weak var controller: NativeGridController?

    override var isFlipped: Bool { true }

    /// Whole-row select, shift-click extends. Converts straight to the TABLE's
    /// local space — same row positions, just x-aligned — since the controller's
    /// row math expects table-local points.
    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let tablePoint = controller.table.convert(event.locationInWindow, from: nil)
        controller.gutterMouseDown(atY: tablePoint.y, shift: event.modifierFlags.contains(.shift))
    }

    // Row numbers are chrome, not file data, so they use the tabular-digit font
    // rather than the data cells' one, a size smaller. MUST match the
    // gutter-width measurement.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    /// Deliberately names no byte figure. The row's SOURCE extent is bounded by
    /// the core's scan budget, but what reaches the screen is the much smaller
    /// per-cell display cap, clipped again to the column width — so any single
    /// number here would describe neither and mislead about what is on screen.
    static let oversizedTooltip =
        "This row is too large to display in full — showing a preview only; the rest of its content isn't loaded."

    /// Distinct from the per-cell truncation dot: that one means "column too
    /// narrow", this one "more source exists past this row's served prefix".
    private static let markerImage: NSImage? = {
        guard let base = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: oversizedTooltip)
        else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(.init(paletteColors: [.systemOrange]))
        return base.withSymbolConfiguration(config)
    }()
    private static let markerSide: CGFloat = 12

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        removeAllToolTips() // re-registered below for whatever is visible now
        guard let controller else { return }
        let table = controller.table
        let visible = table.rows(in: table.visibleRect)
        let width = bounds.width
        let grid = NSColor.gridColor

        if visible.length > 0 {
            for row in visible.location..<(visible.location + visible.length) where row < controller.dataRowCount {
                // The ORIGINAL row number while filtered, forwarded verbatim from
                // the core. A row not yet servable is left blank, like its cells.
                guard let source = controller.model.gutterRow(forRow: row) else { continue }
                let inWindow = table.convert(table.rect(ofRow: row), to: nil)
                let local = convert(inWindow, from: nil)
                let cell = NSRect(x: 0, y: local.minY,
                                  width: width - GridMetrics.rowNumberHPadding, height: local.height)
                SheetRowView.drawText(String(source + 1), in: cell, font: GridGutterView.font,
                                      color: .secondaryLabelColor, alignment: .right)
                if controller.model.rowOversized(forRow: row), let marker = GridGutterView.markerImage {
                    let markerRect = NSRect(
                        x: 2, y: local.minY + (local.height - GridGutterView.markerSide) / 2,
                        width: GridGutterView.markerSide, height: GridGutterView.markerSide
                    )
                    marker.draw(in: markerRect)
                    addToolTip(markerRect, owner: self, userData: nil)
                }
            }
        }
        // Right hairline separating the gutter from the data.
        grid.setFill()
        NSRect(x: width - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: bounds.height).fill()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        GridGutterView.oversizedTooltip
    }
}
