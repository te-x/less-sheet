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

    /// One full-width column, every cell and hairline drawn by the row view, and
    /// a uniform row height so geometry stays O(1) at any row count.
    /// NSTableView's own row-selection and column-resize machinery is off:
    /// rectangular CELL selection and resize are hand-built, since AppKit has no
    /// equivalent for either. Row hit-testing and event routing are reused.
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

    /// Stacks the chrome so numbers and data frost under the band while the
    /// header titles stay legible above it.
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

    /// Seeds the change-detection caches, so the first `apply()` reacts only to
    /// genuine post-build changes.
    private func captureInitialModelState() {
        lastOpenGeneration = model.openGeneration
        lastVisibleColumns = model.visibleColumns
        lastColumnWidths = model.columnWidths
        lastColumnPresentationRevision = model.columnPresentationRevision
        lastColumnWidthRevision = model.columnWidthRevision
        lastColumnConfigurationRevision = model.columnConfigurationRevision
        lastIsFiltered = model.isFiltered
    }

    /// Watch the scroll clip for paging, gutter/header sync and layout logging.
    private func observeClipBounds() {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip
        )
    }

    /// Arms the headless verification hooks. All inert unless their respective
    /// `LESSSHEET_*` variables are set. They exist because none of these states —
    /// a held elastic bounce, a row-count estimate collapsing under a parked
    /// viewport, a viewport sitting past the scan frontier — can be reached
    /// without a real gesture, and a synthetic input event would need a macOS
    /// permission prompt.
    private func installVerificationHooks() {
        EstimateReloadProbe.armIfRequested(on: self)
        EstimateCollapseProbe.armIfRequested(on: self)

        if let rowStr = ProcessInfo.processInfo.environment["LESSSHEET_LIVE_SCROLL_ROW"], let row = Int(rowStr) {
            let targetY = CGFloat(row) * NativeGrid.rowHeight - NativeGrid.contentInsetTop
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // The plain grid dump captures the LIVE table once it is built and
        // sized — deterministic, unlike the first-paint `.task`, which races
        // `makeNSView`. Overlay, find and settings scenes skip this path.
        if let path = FrameDump.liveGridInitialDumpPath {
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                _ = FrameDump.captureLiveGrid(to: path)
                FrameDump.terminateIfRequested()
            }
        }

        // Make the table first responder once it is actually in a window, so
        // Cmd+A, Cmd+C and arrow-key selection work the moment a document opens.
        // Deferred (nothing is attached yet here) and one-shot, so a later
        // re-open never steals focus from a field the user is typing in.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.container.window?.makeFirstResponder(self.table)
        }
    }

}
