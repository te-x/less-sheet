// Data table (event routing), sticky column header, and row-number gutter.
import AppKit
import Contracts
import SwiftUI

// MARK: - Data table (ARCH-select-copy: mouse/keyboard selection + copy)

/// The data table. `NSTableView` already gives row hit-testing (`row(at:)`)
/// and first-responder/event routing (framework); this subclass adds ONLY
/// what AppKit has no equivalent for — mapping a click's x-offset to one of
/// our custom-drawn SUB-columns (there is exactly one real `NSTableColumn`;
/// `SheetRowView` paints every visible column itself) — by forwarding raw
/// mouse/keyboard events to the controller, which drives the pure
/// `Selecting` model. Arrow-key navigation rides `interpretKeyEvents` (AppKit's
/// OWN key-binding table for `NSStandardKeyBindingResponding` — the same
/// mechanism `NSTextView` uses for arrow-key motion), and Cmd+A / Cmd+C ride
/// the stock Edit menu's standard `selectAll:`/`copy:` responder-chain
/// actions — no custom menu items or key-code parsing either way.
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
        // Translates the raw key event into one of the `moveXxx` / `pageXxx` /
        // `moveToXxx` (+ `…AndModifySelection`) navigation calls (see
        // `NativeGrid+KeyNav.swift`) via AppKit's default key bindings (arrows,
        // Page, Home/End, Cmd+arrows, and their shift variants) — framework-
        // native, no hand-rolled key-code switch. Anything the table doesn't
        // handle beeps/forwards exactly as a plain NSResponder would (the
        // default `doCommand(by:)`).
        interpretKeyEvents([event])
    }

    // The arrow / page / document / line motion overrides live in
    // `NativeGrid+KeyNav.swift` (they route through the pure `KeyboardNavigator`
    // — ARCH-macos-kbdnav FR1); Cmd+A / Cmd+C / Esc stay here on the standard
    // responder-chain actions.

    override func selectAll(_ sender: Any?) { controller?.selectAll() }
    // `copy(_:)` is not a declared-overridable NSResponder/NSTableView method
    // in this SDK (unlike `selectAll(_:)`, which NSTableView already declares
    // for its own row selection) — it reaches the responder chain purely via
    // Objective-C selector dispatch (`NSApplication.sendAction`), so `@objc`
    // (not `override`) is what makes the stock Edit menu's Copy item find it.
    @objc func copy(_ sender: Any?) { controller?.copySelection() }

    // `cancelOperation(_:)` is the OTHER standard `NSStandardKeyBindingResponding`
    // action (alongside `moveUp:`/`selectAll:` above) — the default key-binding
    // table maps Esc to it — so overriding it (ARCH-select-copy round 2, finding
    // 2) needs no key-code parsing or menu wiring either: Esc while the grid (not
    // some other field/popup) is first responder dismisses an open find / jump /
    // dialect popup (the "escape from search" path when focus has left the popup
    // field), else cancels an in-flight copy — see `handleEscape`.
    override func cancelOperation(_ sender: Any?) { controller?.handleEscape() }
}

// MARK: - Sticky header (drawn, scrolls horizontally with its columns)

/// The column-title row. Transparent (the glass band shows through, data frosts
/// under it), semibold titles, per-column hairlines, a bottom hairline. Its
/// content offset tracks the table's horizontal scroll so it moves with the
/// columns; it never scrolls vertically (pinned in the band). ALSO owns the
/// column resize / auto-fit hit-testing (ARCH-select-copy AC5): a header
/// click elsewhere selects the whole column; a click/drag ON (or a
/// double-click of) a column's trailing hairline resizes/auto-fits it
/// instead — AppKit's own cursor-rect mechanism (`resetCursorRects`/
/// `addCursorRect`, the same facility `NSSplitView` uses for its dividers)
/// shows `.resizeLeftRight` over that zone with no manual push/pop bookkeeping.
final class GridHeaderView: NSView {
    weak var controller: NativeGridController?
    var contentOffsetX: CGFloat = 0
    /// Live: transparent so the glass band frosts through behind the titles.
    /// Capture-only: fills a semantic material so the titles stay legible in the
    /// cacheDisplay PNG (the live glass renders blank off-screen). The fill
    /// resolves under this view's appearance, so it is dark in a dark capture.
    var capturesBackground = false

    /// Half-width of the draggable hit-zone straddling a column's trailing
    /// hairline — wide enough to grab reliably, narrow enough not to steal
    /// ordinary header clicks (whole-column select) from nearby content.
    private static let resizeHitHalfWidth: CGFloat = 3
    private var resizingIndex: Int?
    private var resizeStartX: CGFloat = 0
    private var resizeStartWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The window-local column index (`controller.widths`' index space)
    /// whose TRAILING hairline sits under HEADER-LOCAL `x`, or nil — there is
    /// no native per-subcolumn hit test (one real `NSTableColumn` carries
    /// every custom-drawn visible column), so this walks the SAME sequential
    /// layout `draw` uses, in this view's own (already-descrolled) space.
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

    /// The resize-vs-select dispatch `mouseDown(with:)` performs, factored out
    /// so it is directly callable with a known HEADER-LOCAL x — no synthetic
    /// `NSEvent` (mirrors how `NativeGridController.headerMouseDown`/
    /// `gutterMouseDown` are themselves directly callable; `SelectCopyProbe`
    /// drives this to regression-test the fix below). `x` is in THIS view's
    /// own (already-descrolled) local space — exactly the space
    /// `resetCursorRects`/`resizeIndex` already use, and exactly what
    /// `mouseDown(with:)` converts an event into.
    ///
    /// BUG FIX (ARCH-select-copy round 2, finding 1): the non-resize
    /// (whole-column-select) branch hands off to `NativeGridController.
    /// headerMouseDown(atX:)` -> `windowColumnIndex(atX:)`, whose cursor
    /// starts at the ABSOLUTE `columnFirstX` — the same absolute space the
    /// data-cell path (`cellAt`) and the gutter path (via `table.convert`)
    /// already hand it. This view's own local `x` is DESCROLLED (`draw`
    /// paints at `columnFirstX - contentOffsetX`), so it must be re-based to
    /// absolute (`+ contentOffsetX`) before crossing that hand-off — passing
    /// the raw local `x` (the previous bug) silently mismapped every click
    /// once scrolled horizontally: a descrolled x is always <= the absolute x
    /// it corresponds to, so it landed on an EARLIER (often the very first)
    /// window column instead of the one actually under the cursor.
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
        // `controller.widths` is only the current horizontal column WINDOW
        // (ARCH-column-windowing); position its first column at its exact
        // prefix-sum offset (`columnFirstX`), translated into this fixed
        // view's local space by the same horizontal-scroll offset the data
        // columns are drawn under.
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

/// The faded 1-based row-number gutter: a fixed left strip (never scrolls
/// horizontally), drawing the number for each currently-visible data row at that
/// row's live y-position (queried from the table, so it stays exactly aligned
/// through scroll and landing). Secondary color + tabular numerals so it reads
/// as chrome, not data; filler rows carry no number. Its frame spans the FULL
/// window height and sits BEHIND the band (added before it in z-order) — just
/// like the data scroll view — so a scrolled-up row number travels under the
/// band and frosts through the glass exactly like the data, rather than
/// stopping dead at the band's edge; at rest row 0's number lands at the same
/// baseline as row 0's data. Rows flagged OVERSIZED (ARCH-huge-row-budget
/// req. 7 — `RowWindow.oversized` / `ls_row_oversized`) additionally draw a
/// small tinted SF Symbol before the number, with a hover tooltip explaining
/// the budget.
final class GridGutterView: NSView, NSViewToolTipOwner {
    weak var controller: NativeGridController?

    override var isFlipped: Bool { true }

    /// Gutter click (ARCH-select-copy AC1): whole-row select; shift-click
    /// extends a whole-row selection. Converts straight to the TABLE's local
    /// space (same row-height/positions as this view, just x=0-aligned)
    /// rather than routing through this view's own coordinates — the
    /// controller's row math already expects table-local points.
    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let tablePoint = controller.table.convert(event.locationInWindow, from: nil)
        controller.gutterMouseDown(atY: tablePoint.y, shift: event.modifierFlags.contains(.shift))
    }

    // Row numbers are chrome (generated line numbers, not file data): keep the
    // tabular-digit font — NOT the data cells' SF Mono — so digits stay aligned,
    // but one size smaller than the data. MUST match the gutter-width measurement
    // (DocumentModel.rowNumberWidth).
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    /// Honest oversized-row tooltip (no "load completely" affordance exists —
    /// ARCH non-goal, purely informational). Deliberately names NO byte
    /// figure: the row's SOURCE extent is bounded by the core's SCAN budget
    /// (`LS_WINDOW_ROW_SCAN_MAX_BYTES`, ~1 MiB — how far it reads to find the
    /// row's shape), but what actually reaches the screen is the much
    /// smaller per-cell DISPLAY cap (`LS_CELL_MAX_BYTES`, 4 KiB) further
    /// clipped to the column's on-screen width — typically well under 100
    /// characters. Naming "~1 MB" (the earlier copy) described neither figure
    /// and misled the user about how much they were actually seeing; better
    /// to promise nothing quantitative.
    static let oversizedTooltip =
        "This row is too large to display in full — showing a preview only; the rest of its content isn't loaded."

    /// The oversized-row marker: a small `exclamationmark.circle` (distinct
    /// from the per-cell "…" truncation dot, which means "column too narrow" —
    /// this means "more source exists past this row's served prefix"), tinted
    /// so it reads as an alert, not chrome.
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
                // The gutter's ORIGINAL (unfiltered) row number while a filter
                // is active (ARCH criterion 13/17), forwarded verbatim from
                // the core's `sourceRow` — never recomputed; the identity
                // `row` otherwise. A row not yet servable under a filter
                // (outside the materialized window) is left blank, same as
                // its cells.
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
