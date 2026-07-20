// Row-count-estimate sync, elastic-overscroll guard, landing, headless
// capture, and the NSTableView data source / delegate for NativeGridController.
// Split out of NativeGrid.swift purely to satisfy file/type length limits.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {

    // MARK: Row-count estimate <-> elastic-overscroll guard

    /// Re-syncs everything the row-count estimate drives, at rest, with no
    /// scroll required: the column/filler width (always — see the
    /// `refreshColumnWidth` call below) and the scrollbar extent (via
    /// `reloadData`, never `noteNumberOfRowsChanged` — on a 10^8-row table the
    /// latter is O(row-count delta): 250-400 ms when the estimate jumps by
    /// millions between polls, blocking the main thread; `reloadData` is
    /// O(viewport) — explicitly sanctioned by the ARCH, REVIEW-7). The
    /// scrollbar-extent reload is SKIPPED while the clip is mid an elastic
    /// overscroll bounce on EITHER axis (a live drag past the top/left edge,
    /// or its spring bounce-back still returning): `reloadData` plus the
    /// clip-origin restore below it would
    /// otherwise perturb the bounds WHILE AppKit's own rubber-band animation
    /// is mid-flight, visibly resetting/resuming it — the flash reported in
    /// the first few seconds after opening a large file, exactly the window
    /// `DocumentModel.startPolling` spends refining `rowCountInfo` (near
    /// every 100 ms tick; confirmed via `LESSSHEET_LOG_ESTIMATE` +
    /// `LESSSHEET_SIMULATE_OVERSCROLL` — see `EstimateReloadProbe`). Skipping
    /// leaves `lastRowCount` stale, so this simply retries on the next
    /// `apply()` (the next poll tick) or scroll tick — cheap, and
    /// self-flushing the instant the bounce settles back into range: EVERY
    /// tick of the settle, including its very last one, fires
    /// `clipBoundsChanged`, which also calls this — no separate release-
    /// triggered rescan is needed, and nothing is left stale once the user
    /// stops interacting or indexing completes (the next scroll or poll picks
    /// it up). The clip origin is restored across an applied reload so the
    /// visible row never jumps (rows are absolute at row*rowHeight; ARCH
    /// criterion 5/6).
    @discardableResult
    func syncRowCountEstimate() -> Bool {
        let rows = numberOfRows(in: table)
        guard rows != lastRowCount else { return false }

        // The vertical scroller's need — hence the viewport's AVAILABLE width
        // for `column.width` — is driven by this SAME estimate, but inserting
        // or removing it changes the clip's FRAME size, not its bounds ORIGIN:
        // no `boundsDidChangeNotification` fires for that (the notification is
        // specifically bounds-independent-of-frame), so `clipBoundsChanged`
        // alone can never observe it and a stale, too-wide `column.width`
        // lingers — a spurious horizontal scroller AT REST, no scroll required
        // to trigger OR to fix it. Re-run the (lightweight, origin-untouched:
        // no `reloadData`, no `scroll(to:)`) column-width sync here on every
        // estimate change instead, so `column.width` matches the SETTLED clip
        // even at rest. Unconditional (not overscroll-gated): it never touches
        // the clip origin, so it cannot cause the reload collision below.
        refreshColumnWidth(site: "estimate")

        // An estimate COLLAPSE (the discovered true row count lands far below
        // the head-extrapolated one the user was scrolling against — e.g. one
        // final multi-GB row inflating the extrapolation by orders of
        // magnitude) can leave the viewport resting PAST the newly-shrunk
        // valid range. Unlike a live elastic bounce, nothing is animating the
        // clip — its origin is static — so the "self-flushes the instant the
        // bounce settles" healing the overscroll guard below relies on never
        // fires, and the user is left stranded past the true EOF forever (see
        // `reanchorIfStrandedPastNewEnd`). Re-anchor BEFORE the overscroll
        // check, so a stranded landing reads as an ordinary in-range sync
        // below and the reload proceeds right away instead of deferring
        // forever. A no-op when the estimate grew, or the current origin is
        // already within the new range (the overwhelmingly common case).
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

    /// Snaps the clip's Y origin down to the new bottom edge when the
    /// estimate SHRANK enough to leave it resting past it — the stranded-
    /// past-EOF case (see `syncRowCountEstimate`). Mirrors `landOn`'s own end
    /// clamp exactly, so the re-anchored position is indistinguishable from a
    /// genuine jump-to-end landing: the last row settles above the EOF
    /// overscroll filler, never mid-air past it. Never fires on growth (the
    /// new maxY only rises) or when the current origin is already inside the
    /// new range — the ordinary case on every file, pathological or not.
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

    /// Whether the clip is CURRENTLY beyond the natural (non-overscrolled)
    /// range on each axis — a live elastic drag past an edge, or its spring
    /// bounce-back animation still returning there. Mirrors the SAME clamp
    /// math `landOn` already uses for y (the top content inset; content
    /// height vs. viewport height at the bottom) plus the equivalent for x,
    /// with a small tolerance for floating-point settle noise.
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

    // MARK: Landing (O(viewport))

    /// Bring `row` to the top of the data area (below the header) — the same
    /// landing look the old grid gave via `scrollTo(y:)`, but O(viewport): the
    /// clip origin is set and `NSTableView` recycles the newly visible rows.
    /// Near EOF the clamp keeps the last data row above the floating controls
    /// (the filler rows below it are the overscroll strip).
    func landOn(row: Int) {
        let clip = scroll.contentView
        // Clamp with the row-count-derived content height and the SCROLL frame
        // height (stable) rather than table.frame / clip.bounds, which can be
        // stale/zero before the view is sized — otherwise an EOF landing fails to
        // clamp and the last row rides to the very top instead of above the
        // floating controls (the filler rows below it are the overscroll strip).
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

    /// The click-away overlay is above this AppKit subtree while a popup is
    /// open, so it receives wheel events first. Forward the untouched event to
    /// NSScrollView to retain native momentum, direction, and elasticity.
    func forwardScrollWheel(_ event: NSEvent) {
        scroll.scrollWheel(with: event)
    }

    /// The data row currently at the TOP of the unobscured data area (just below
    /// the glass band), recovered exactly from the clip origin: a landing sets
    /// clip.y = row*rowHeight − contentInsetTop, so this inverts it. Used to
    /// re-anchor the viewport across a header toggle (no band-offset drift, unlike
    /// the model's paging `firstVisibleRow`, which counts rows hidden under the
    /// band). Clamped to a valid data row.
    func currentTopDataRow() -> Int {
        let originY = scroll.contentView.bounds.origin.y
        let row = ((originY + NativeGrid.contentInsetTop) / NativeGrid.rowHeight).rounded()
        return min(max(0, Int(row)), max(0, dataRowCount - 1))
    }

    /// Composite the LIVE grid into `rep` for a headless `cacheDisplay` capture
    /// (ARCH bonus). A view-based, layer-backed `NSTableView` renders its rows
    /// into per-row layers that an ancestor's `cacheDisplay` does NOT composite
    /// off-screen — so the container capture yields only the chrome. We draw the
    /// chrome from the container, then paint each visible row by cacheDisplay-ing
    /// the REAL row view (the root of its own capture renders reliably) at its
    /// live position, clipped to the data viewport. Verification-only.
    func compositeCapture(into rep: NSBitmapImageRep) {
        // 1) Chrome: band / header / gutter (direct container subviews capture fine).
        container.cacheDisplay(in: container.bounds, to: rep)

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.current = saved }
        let containerBounds = container.bounds

        // 2) Rows: paint each visible row view individually over the data area.
        // The clip is balanced on ctx (save/restore AFTER current = ctx) so it
        // does NOT leak into the band step below.
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

        // 3) Band + header: the live NSGlassEffectView does not render off-screen
        // (blank in the capture), which would leave the header text on nothing —
        // invisible in dark mode. Paint a SEMANTIC material stand-in for the band
        // and re-draw the header text on top so it stays legible; the real
        // frosted band is a live/on-screen check.
        let bandRect = NSRect(x: 0, y: containerBounds.height - NativeGrid.bandHeight,
                              width: containerBounds.width, height: NativeGrid.bandHeight)
        // Resolve the SEMANTIC band colors under the capture appearance to a
        // concrete value, then fill: a bitmap context otherwise resolves dynamic
        // catalog colors under the ambient (light) appearance, so the band would
        // stay light in the dark capture. (.sRGB resolves; .deviceRGB returns nil
        // here and must not be used.)
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
        // Re-draw the header with a capture background so its titles read on the
        // band (its own cacheDisplay resolves the semantic fill + text under the
        // capture appearance — dark bg + light text in a dark capture).
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

    /// Empty grid rows kept below the last data row: the EOF overscroll strip
    /// (so the last rows clear the floating controls), extended to fill the
    /// viewport when the document is shorter than it. Pure fill — the model's
    /// row-count estimate ignores it.
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

    // No cell views: the row view draws every cell.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    // Pure viewer: rows are never selectable/clickable.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

    // MARK: LESSSHEET_LOG_LAYOUT (AppKit frames, identical log format)

    /// Emit the at-rest window-space (y-down) frames for band / header / row1 /
    /// scrollview in the pinned `lesssheet.layout.<label>` format. The old grid
    /// logged these off the SwiftUI `.global` frame; here they come off the real
    /// AppKit frames. The LAST line per label is the settled frame.
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
        // Additive (not a pinned label): proves the gutter frame extends to the
        // window top (minY 0), matching band/scrollview, instead of stopping at
        // the band's old bottom edge (54) — the headless half of the bug-#1 fix.
        ScrollProbe.noteFrame("gutter", yDown(gutter.bounds, gutter))
        if dataRowCount > 0 {
            ScrollProbe.noteFrame("row1", yDown(table.rect(ofRow: 0), table))
        }
    }
}
