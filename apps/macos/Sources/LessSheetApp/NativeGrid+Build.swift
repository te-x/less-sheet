// Container construction + one-time setup for NativeGridController.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {
    // MARK: Build

    func makeContainer() -> NSView {
        NativeGridController.live = self
        container.controller = self
        container.autoresizesSubviews = false
        container.frame = NSRect(x: 0, y: 0, width: 960, height: 620)
        configureScrollView()
        configureDataTable()
        assembleViewTree()
        refreshLayoutMetrics()
        captureInitialModelState()
        layoutContainer()
        table.reloadData()
        lastRowCount = numberOfRows(in: table)
        // Rest at the top-left, honoring the top inset (row 0 at window-y 54).
        scrollToTopLeft()
        observeClipBounds()
        built = true
        installVerificationHooks()
        return container
    }

    /// Scroll view fills the window (top edge = window top => scrollview minY 0);
    /// a top content inset drops the first row below the band.
    private func configureScrollView() {
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: NativeGrid.contentInsetTop, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: -NativeGrid.contentInsetTop, left: 0, bottom: 0, right: 0)
    }

    /// The table: one full-width column; every cell + hairline + highlight is
    /// drawn by the row view (fastest, pixel control), uniform row height =>
    /// O(1) geometry at any row count. NSTableView's OWN row selection/
    /// column-resize machinery stays off (selectionHighlightStyle .none,
    /// allowsColumnResizing false, etc.) — ARCH-select-copy's rectangular
    /// CELL selection + resize are hand-built (SheetTableView / GridHeaderView)
    /// since AppKit has no native equivalent for either; row hit-testing
    /// (`row(at:)`) and first-responder/event routing ARE reused (framework).
    private func configureDataTable() {
        column.width = 400
        column.resizingMask = []
        table.addTableColumn(column)
        table.rowHeight = NativeGrid.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .textBackgroundColor
        table.headerView = nil                       // sticky header is drawn separately
        table.selectionHighlightStyle = .none        // our OWN cell selection overlay, not the table's
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.controller = self
        scroll.documentView = table
    }

    /// Configure the chrome subviews and stack them (scroll, gutter, band,
    /// header) so numbers/data frost under the band and titles stay legible.
    private func assembleViewTree() {
        header.controller = self
        header.clipsToBounds = true
        gutter.controller = self
        gutter.clipsToBounds = true

        band.style = .regular
        band.cornerRadius = 0

        container.addSubview(scroll)
        container.addSubview(gutter)    // in front of scroll, BEHIND the band: numbers frost under it too
        container.addSubview(band)      // in front of scroll + gutter: both frost under it
        container.addSubview(header)    // in front of the band: titles legible
    }

    /// Seed the change-detection caches from the current model so the first
    /// `apply()` only reacts to genuine post-build changes.
    private func captureInitialModelState() {
        lastOpenGeneration = model.openGeneration
        lastVisibleColumns = model.visibleColumns
        lastColumnWidths = model.columnWidths
        lastColumnPresentationRevision = model.columnPresentationRevision
        lastColumnWidthRevision = model.columnWidthRevision
        lastColumnConfigurationRevision = model.columnConfigurationRevision
        lastIsFiltered = model.isFiltered
    }

    /// Watch scroll for paging, gutter/header sync, and layout logging.
    private func observeClipBounds() {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip
        )
    }

    /// Arm the headless verification/dump hooks (all inert unless their
    /// respective LESSSHEET_* environment switches are set).
    private func installVerificationHooks() {
        // Verification: headless proxy for a HELD elastic overscroll bounce
        // (no synthetic input events, no TCC prompt) — see EstimateReloadProbe.
        // Inert unless LESSSHEET_SIMULATE_OVERSCROLL is set.
        EstimateReloadProbe.armIfRequested(on: self)

        // Verification: headless proxy for "the user scrolled the live
        // scrollbar to the current (possibly wildly over-estimated) end and
        // let go" — the estimate-COLLAPSE repro. No scroll-to-position probe
        // exists, so this parks the clip directly, then watches the REAL
        // background indexer and logs whether the viewport re-anchors instead
        // of staying stranded. Inert unless LESSSHEET_SIMULATE_ESTIMATE_COLLAPSE
        // is set; see EstimateCollapseProbe.
        EstimateCollapseProbe.armIfRequested(on: self)

        // Verification-only: force the live grid's scroll position to a
        // specific row BEFORE the capture below, so a not-yet-servable
        // region (rows within the estimate but past the scan frontier — the
        // loading-placeholder case, see `SheetRowView.pending`) can be
        // screenshotted without a live scroll gesture (no scroll-to-position
        // probe exists; mirrors `EstimateCollapseProbe`'s direct
        // `clip.scroll(to:)` technique). Composes with the ordinary
        // LESSSHEET_DUMP_FRAME / LESSSHEET_DUMP_EXIT capture below — no
        // bespoke path or termination of its own. Inert unless
        // LESSSHEET_LIVE_SCROLL_ROW is set.
        if let rowStr = ProcessInfo.processInfo.environment["LESSSHEET_LIVE_SCROLL_ROW"], let row = Int(rowStr) {
            let targetY = CGFloat(row) * NativeGrid.rowHeight - NativeGrid.contentInsetTop
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // Verification: the plain grid-content dump captures the LIVE table
        // (cacheDisplay) once it is built + sized — deterministic, unlike the
        // first-paint .task which races this makeNSView. Probe / overlay / find
        // / settings scenes are handled elsewhere (they skip this path).
        if let path = FrameDump.liveGridInitialDumpPath {
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                _ = FrameDump.captureLiveGrid(to: path)
                FrameDump.terminateIfRequested()
            }
        }

        // ARCH-select-copy: make the data table first responder once it is
        // actually in a window, so Cmd+A / Cmd+C / arrow-key selection work the
        // moment a document opens, with no preceding click required. Deferred
        // (the container isn't attached to a window yet at this point in
        // makeNSView) and one-shot — a later re-open does NOT repeat this, so
        // it never steals focus from a field the user is actively using.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.container.window?.makeFirstResponder(self.table)
        }
    }

}
