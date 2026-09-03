// Row-count-estimate sync, the elastic-overscroll guard, landing, the headless
// capture, and the table's data source and delegate.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {

    // MARK: Row-count estimate <-> elastic-overscroll guard

    /// Re-syncs everything the row-count estimate drives, at rest, with no
    /// scroll required.
    ///
    /// The scrollbar extent goes through `reloadData`, never
    /// `noteNumberOfRowsChanged`: on a table of 10^8 rows the latter is O(the
    /// row-count delta) and blocks the main thread for hundreds of milliseconds
    /// when the estimate jumps by millions between polls, while `reloadData` is
    /// O(viewport). The clip origin is restored across it, so the visible row
    /// never jumps.
    ///
    /// That reload is SKIPPED while the clip is mid an elastic overscroll bounce
    /// on either axis: perturbing the bounds while AppKit's rubber-band animation
    /// is in flight visibly resets it, which is a flash on every poll tick for
    /// the first seconds of a large file. Skipping leaves `lastRowCount` stale
    /// and simply retries — every tick of the settle, its last one included,
    /// comes back through here.
    @discardableResult
    func syncRowCountEstimate() -> Bool {
        let rows = numberOfRows(in: table)
        guard rows != lastRowCount else { return false }

        // The vertical scroller's need — hence the width available to the data
        // column — is driven by this same estimate, but inserting or removing it
        // changes the clip's FRAME, not its bounds origin, and no bounds-changed
        // notification fires for that. So the scroll path can never observe it,
        // and a stale too-wide column width would linger as a spurious
        // horizontal scroller at rest. This sync touches no origin, so it is
        // safe to run unconditionally, ahead of the overscroll gate below.
        refreshColumnWidth(site: "estimate")

        // An estimate COLLAPSE — the true count landing far below a
        // head-extrapolated one, say when a single final multi-GB row inflated
        // it by orders of magnitude — can leave the viewport past the newly
        // shrunk range. Nothing is animating the clip there, so the "it
        // self-heals when the bounce settles" reasoning below never applies and
        // the user would be stranded past EOF indefinitely. Re-anchoring BEFORE
        // the overscroll check makes it read as an ordinary in-range sync.
        reanchorIfStrandedPastNewEnd(rows: rows)

        let (overX, overY) = overscrollAxes()
        let origin = scroll.contentView.bounds.origin
        EstimateReloadProbe.noteDecision(.init(
            applied: !(overX || overY), rows: rows, lastRows: lastRowCount,
            origin: origin, overscrollX: overX, overscrollY: overY
        ))
        guard !overX, !overY else { return false }
        lastRowCount = rows
        table.reloadData()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    /// Snaps the clip down to the new bottom edge when the estimate shrank
    /// enough to leave it resting past one. Mirrors `landOn`'s end clamp exactly,
    /// so the result is indistinguishable from a genuine jump-to-end landing.
    func reanchorIfStrandedPastNewEnd(rows: Int) {
        guard rows < lastRowCount, !reanchoring else { return }
        let clip = scroll.contentView
        let contentHeight = CGFloat(rows) * NativeGrid.rowHeight
        let viewportHeight = max(clip.bounds.height, scroll.bounds.height)
        let maxY = max(-NativeGrid.contentInsetTop, contentHeight - viewportHeight)
        let before = clip.bounds.origin.y
        guard before > maxY else { return }
        reanchoring = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: maxY))
        reanchoring = false
        EstimateReloadProbe.noteReanchor(fromY: before, toY: maxY, rows: rows, lastRows: lastRowCount)
    }

    /// Whether the clip is currently beyond its natural range on each axis — a
    /// live elastic drag past an edge, or its spring still returning. Same clamp
    /// math as `landOn`, with a small tolerance for settle noise.
    func overscrollAxes() -> (x: Bool, y: Bool) {
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let tolerance: CGFloat = 0.5

        let contentHeight = CGFloat(numberOfRows(in: table)) * NativeGrid.rowHeight
        let viewportHeight = max(clip.bounds.height, scroll.bounds.height)
        let minY = -NativeGrid.contentInsetTop
        let maxY = max(minY, contentHeight - viewportHeight)
        let overY = origin.y < minY - tolerance || origin.y > maxY + tolerance

        let maxX = max(0, table.frame.width - clip.bounds.width)
        let overX = origin.x < -tolerance || origin.x > maxX + tolerance

        return (x: overX, y: overY)
    }

    // MARK: Landing

    /// Brings `row` to the top of the data area: the clip origin is set and the
    /// table recycles the newly visible rows, so this is O(viewport) at any
    /// distance. Near EOF the clamp keeps the last data row above the floating
    /// controls, with the filler rows below it as the overscroll strip.
    func landOn(row: Int) {
        let clip = scroll.contentView
        // Clamp against the SCROLL frame height rather than the table frame or
        // clip bounds, which can be stale or zero before the view is sized —
        // otherwise an EOF landing fails to clamp and the last row rides to the
        // very top.
        let contentHeight = CGFloat(numberOfRows(in: table)) * NativeGrid.rowHeight
        let viewportHeight = max(clip.bounds.height, scroll.bounds.height)
        let desired = CGFloat(row) * NativeGrid.rowHeight - NativeGrid.contentInsetTop
        let maxY = max(-NativeGrid.contentInsetTop, contentHeight - viewportHeight)
        let clampedY = min(max(desired, -NativeGrid.contentInsetTop), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clampedY))
        scroll.reflectScrolledClipView(clip)
    }

    func scrollToTopLeft() {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: -NativeGrid.contentInsetTop))
        scroll.reflectScrolledClipView(clip)
    }

    /// The click-away scrim sits above this subtree while a popup is open and
    /// receives wheel events first; forwarding the untouched event keeps native
    /// momentum, direction and elasticity.
    func forwardScrollWheel(_ event: NSEvent) {
        scroll.scrollWheel(with: event)
    }

    /// The data row at the top of the UNOBSCURED data area, just below the band,
    /// recovered by inverting what `landOn` sets. Unlike the model's paging
    /// `firstVisibleRow`, which counts rows hidden under the band, this has no
    /// band-offset drift — which is what a header-toggle re-anchor needs.
    func currentTopDataRow() -> Int {
        let originY = scroll.contentView.bounds.origin.y
        let row = ((originY + NativeGrid.contentInsetTop) / NativeGrid.rowHeight).rounded()
        return min(max(0, Int(row)), max(0, dataRowCount - 1))
    }

    /// Composites the LIVE grid for a headless capture. A layer-backed
    /// `NSTableView` renders its rows into per-row layers that an ancestor's
    /// `cacheDisplay` does not composite off-screen, so capturing the container
    /// alone yields only the chrome. Each visible row is therefore captured
    /// separately, as the root of its own capture, and drawn at its live
    /// position.
    func compositeCapture(into rep: NSBitmapImageRep) {
        container.cacheDisplay(in: container.bounds, to: rep)

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.current = saved }
        let containerBounds = container.bounds

        // The clip is balanced on `ctx` so it cannot leak into the band below.
        ctx.saveGraphicsState()
        NSRect(x: gutterWidth, y: 0, width: containerBounds.width - gutterWidth,
               height: containerBounds.height - NativeGrid.bandHeight).clip()
        table.tile()
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 0 {
            for row in visible.location..<(visible.location + visible.length) {
                guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) as? SheetRowView else { continue }
                configure(rowView, row: row)
                guard let sub = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { continue }
                rowView.cacheDisplay(in: rowView.bounds, to: sub)
                sub.draw(in: rowView.convert(rowView.bounds, to: container))
            }
        }
        ctx.restoreGraphicsState()

        // The live glass view renders blank off-screen, which would leave the
        // header text on nothing and invisible in dark mode. Paint a semantic
        // stand-in and re-draw the header over it; the real frosted band can only
        // be checked on screen.
        let bandRect = NSRect(x: 0, y: containerBounds.height - NativeGrid.bandHeight,
                              width: containerBounds.width, height: NativeGrid.bandHeight)
        // Resolve the semantic colors under the CAPTURE appearance first: a
        // bitmap context otherwise resolves dynamic catalog colors under the
        // ambient (light) one, leaving the band light in a dark capture.
        // `.sRGB` resolves here; `.deviceRGB` returns nil.
        var bandFill = NSColor.windowBackgroundColor
        var lineFill = NSColor.gridColor
        container.effectiveAppearance.performAsCurrentDrawingAppearance {
            bandFill = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? bandFill
            lineFill = NSColor.gridColor.usingColorSpace(.sRGB) ?? lineFill
        }
        bandFill.setFill()
        bandRect.fill()
        lineFill.setFill()
        NSRect(x: 0, y: containerBounds.height - NativeGrid.bandHeight,
               width: containerBounds.width, height: NativeGrid.hairline).fill()
        header.capturesBackground = true
        header.needsDisplay = true
        if let sub = header.bitmapImageRepForCachingDisplay(in: header.bounds) {
            header.cacheDisplay(in: header.bounds, to: sub)
            sub.draw(in: header.convert(header.bounds, to: container))
        }
        header.capturesBackground = false
        header.needsDisplay = true
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        dataRowCount + fillerRowCount()
    }

    /// The EOF overscroll strip, so the last rows clear the floating controls,
    /// extended to fill the viewport when the document is shorter than it. Pure
    /// fill: the row-count estimate ignores it.
    func fillerRowCount() -> Int {
        let viewportRows = Int(ceil(scroll.contentView.bounds.height / NativeGrid.rowHeight))
        return max(GridMetrics.overscrollRows, viewportRows - dataRowCount + GridMetrics.overscrollRows)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("sheetRow")
        let rowView = (tableView.makeView(withIdentifier: id, owner: self) as? SheetRowView) ?? {
            let view = SheetRowView(); view.identifier = id; return view
        }()
        configure(rowView, row: row)
        return rowView
    }

    // No cell views: the row view draws every cell itself.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    // AppKit's own row selection stays off; ours is rectangular and per-cell.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

    // MARK: LESSSHEET_LOG_LAYOUT

    /// Emits the at-rest window-space (y-down) frames for the band, header, first
    /// row and scroll view. The LAST line per label is the settled frame.
    func emitLayoutFramesIfEnabled() {
        guard ScrollProbe.layoutEnabled, let content = container.window?.contentView else { return }
        let contentHeight = content.bounds.height
        func yDown(_ rect: NSRect, _ view: NSView) -> CGRect {
            let windowRect = view.convert(rect, to: nil)
            return CGRect(x: windowRect.minX, y: contentHeight - windowRect.maxY,
                          width: windowRect.width, height: windowRect.height)
        }
        ScrollProbe.noteFrame("band", yDown(band.bounds, band))
        ScrollProbe.noteFrame("header", yDown(header.bounds, header))
        ScrollProbe.noteFrame("scrollview", yDown(scroll.bounds, scroll))
        // Proves the gutter reaches the window top like the band and scroll view,
        // rather than stopping at the band's bottom edge.
        ScrollProbe.noteFrame("gutter", yDown(gutter.bounds, gutter))
        if dataRowCount > 0 {
            ScrollProbe.noteFrame("row1", yDown(table.rect(ofRow: 0), table))
        }
    }
}
