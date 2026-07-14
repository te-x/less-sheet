import AppKit
import Contracts
import SwiftUI

// The LIVE chromeless spreadsheet grid, rebuilt on `NSTableView` (native row
// recycling) so EVERY landing — jump / find / wrap, any distance — costs
// O(viewport): a landing is `DocumentModel.landOn` + a clip scroll, never a
// multi-million-row relayout (the SwiftUI `scrollTo` stall this slice replaces).
//
// It ships as an `NSViewRepresentable` inside the existing SwiftUI shell; the
// overlay/pills/Settings/error states and the delegate-owned window are
// untouched. The table's data source reads the SAME `DocumentModel` the old grid
// did (paging/window/highlight state unchanged); `GridView.body` touches the
// model facts that must drive AppKit so `updateNSView` re-syncs on every change.
//
// Layout (window-space, y-down — pinned by LESSSHEET_LOG_LAYOUT):
//   band   y[0,54]   the glass header band (title-bar region + header row),
//                    EXPLICITLY drawn (`NSGlassEffectView`) — never emergent
//                    titlebar/scroll-edge compositing (the memory-logged lesson).
//   header y[32,54]  the sticky column header (22 pt), scrolls horizontally with
//                    its columns, transparent so data frosts through the band.
//   row1   y[54,76]  the first data row (table row 0). Rows recycle below.
//   scrollview minY 0  the scroll view fills the window from its top edge, so
//                    content scrolls up UNDER the band and frosts through it.
// The faded row-number gutter is a fixed left strip (pinned against horizontal
// scroll, synced vertically to the table's rows) that ALSO fills the full
// window height and sits BEHIND the band, exactly like the scroll view: row
// numbers scroll up under the band and frost through it just like the data,
// and row 0's number rests at the same baseline as row 0's data.

// MARK: - Grid geometry (shared derivations over GridMetrics)

private enum NativeGrid {
    static let rowHeight = GridMetrics.rowHeight            // 22
    static let headerHeight = GridMetrics.rowHeight         // 22
    static let bandHeight = GridMetrics.titleBarInset + GridMetrics.rowHeight  // 54
    /// The scroll view's top content inset: content rests below the band, so
    /// row 0 sits at window-y 54, while scrolled rows still travel up under it.
    static let contentInsetTop = GridMetrics.titleBarInset + GridMetrics.rowHeight  // 54
    static let hairline: CGFloat = 1
}

// MARK: - SwiftUI seam

/// The grid as seen by the SwiftUI shell (`ContentView.documentContent`). A thin
/// wrapper over the AppKit engine; the enclosing `ZStack` composites the floating
/// overlay above it exactly as before.
struct GridView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        // Touch the model facts that must drive AppKit: reading them here makes
        // this body (and thus `updateNSView`) re-run whenever they change — the
        // reliable bridge from `@Observable` mutations to the coordinator.
        _ = model.openGeneration
        _ = model.pendingScrollRow
        _ = model.displayRowCount
        _ = model.rowCountInfo.count
        _ = model.window.firstRow
        _ = model.window.rows.count
        _ = model.findSession.display.request != nil
        _ = model.findSession.display.current?.row
        _ = model.findSession.display.current?.column
        _ = model.isFiltered
        _ = model.visibleColumns
        _ = model.columnWidths
        _ = model.columnPresentationRevision
        _ = model.columnWidthRevision
        _ = model.columnConfigurationRevision
        return NativeGridRepresentable(model: model)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

struct NativeGridRepresentable: NSViewRepresentable {
    var model: DocumentModel

    func makeCoordinator() -> NativeGridController { NativeGridController(model: model) }

    func makeNSView(context: Context) -> NSView { context.coordinator.makeContainer() }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.apply() }
}

// MARK: - Container (owns the AppKit view tree + lays it out)

/// Fills the SwiftUI frame (which extends under the transparent title bar via
/// `ignoresSafeArea(.top)`), so the scroll view's top edge is the window's top
/// edge. Forwards resize to the controller for the fixed-strip layout.
final class GridContainerView: NSView {
    weak var controller: NativeGridController?
    override var isFlipped: Bool { false }
    override func layout() {
        super.layout()
        controller?.layoutContainer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An observable landing may have arrived between `makeNSView` and the
        // representable entering a window. Re-apply now that AppKit has usable
        // viewport geometry instead of waiting for an unrelated model change.
        if window != nil { controller?.apply() }
    }
}

// MARK: - Controller (data source + delegate + model bridge)

@MainActor
final class NativeGridController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// The live grid container, exposed for the frame-dump hook's cacheDisplay
    /// capture of the REAL table (ARCH bonus). Weak: owned by the view tree.
    static weak var live: NativeGridController?

    let model: DocumentModel

    let container = GridContainerView()
    let scroll = NSScrollView()
    let table = SheetTableView()
    let header = GridHeaderView()
    let gutter = GridGutterView()
    let band = NSGlassEffectView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cells"))

    // Layout state mirrored from the model (read by the row/header/gutter draw).
    // `widths`/`headerLabels` are the CURRENT HORIZONTAL COLUMN WINDOW only —
    // a few tens to a few hundred columns, never all of them on a wide
    // document (ARCH-column-windowing) — positioned starting at `columnFirstX`
    // (the window's exact prefix-sum x-offset, so an in-window column lands at
    // the SAME x a full, unwindowed draw would give it; ARCH AC4/AC5).
    private(set) var widths: [CGFloat] = []
    private(set) var headerLabels: [String] = []
    private(set) var headerTruncated: [Bool] = []
    private(set) var columnAlignments: [ColumnTextAlignment] = []
    /// Absolute column indices PARALLEL to `widths`/`headerLabels` (ARCH-
    /// select-copy): the click→cell mapping's column half — position `i`
    /// here is the SAME absolute column `widths[i]` is the width of.
    private(set) var absoluteColumns: [Int] = []
    private(set) var columnFirstX: CGFloat = 0
    private(set) var fillerColumns = 0
    private(set) var gutterWidth: CGFloat = 0
    /// Sum of every VISIBLE column's width (`model.totalVisibleWidth`) —
    /// independent of the column window — driving the scrollable table
    /// column's width / filler-column count (`refreshColumnWidth`). O(visible
    /// columns) to derive; refreshed only on a STRUCTURAL change
    /// (`refreshLayoutMetrics`), never per scroll tick.
    private var totalDataWidth: CGFloat = 0

    // Change-detection caches (avoid redundant reloads).
    private var lastOpenGeneration = -1
    private var lastRowCount = -1
    private var lastVisibleColumns: [Int] = []
    private var lastColumnWidths: [CGFloat] = []
    private var lastColumnPresentationRevision = -1
    private var lastColumnWidthRevision = -1
    private var lastColumnConfigurationRevision = -1
    private var lastIsFiltered = false
    private var built = false
    private var landingApplyScheduled = false
    private var pendingCellToggle: GridCell?

    init(model: DocumentModel) {
        self.model = model
        super.init()
        model.viewportLandingHandler = { [weak self] _ in self?.scheduleLandingApply() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Data rows the file exposes (the estimate that the scrollbar reflects,
    /// refined toward exact). Filler rows extend below for the spreadsheet fill.
    var dataRowCount: Int { max(0, model.displayRowCount) }

    // MARK: Build

    func makeContainer() -> NSView {
        NativeGridController.live = self
        container.controller = self
        container.autoresizesSubviews = false
        container.frame = NSRect(x: 0, y: 0, width: 960, height: 620)

        // Scroll view fills the window (top edge = window top => scrollview
        // minY 0); a top content inset drops the first row below the band.
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: NativeGrid.contentInsetTop, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: -NativeGrid.contentInsetTop, left: 0, bottom: 0, right: 0)

        // The table: one full-width column; every cell + hairline + highlight is
        // drawn by the row view (fastest, pixel control), uniform row height =>
        // O(1) geometry at any row count. NSTableView's OWN row selection/
        // column-resize machinery stays off (selectionHighlightStyle .none,
        // allowsColumnResizing false, etc.) — ARCH-select-copy's rectangular
        // CELL selection + resize are hand-built (SheetTableView / GridHeaderView)
        // since AppKit has no native equivalent for either; row hit-testing
        // (`row(at:)`) and first-responder/event routing ARE reused (framework).
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

        refreshLayoutMetrics()
        lastOpenGeneration = model.openGeneration
        lastVisibleColumns = model.visibleColumns
        lastColumnWidths = model.columnWidths
        lastColumnPresentationRevision = model.columnPresentationRevision
        lastColumnWidthRevision = model.columnWidthRevision
        lastColumnConfigurationRevision = model.columnConfigurationRevision
        lastIsFiltered = model.isFiltered
        layoutContainer()
        table.reloadData()
        lastRowCount = numberOfRows(in: table)

        // Rest at the top-left, honoring the top inset (row 0 at window-y 54).
        scrollToTopLeft()

        // Watch scroll for paging, gutter/header sync, and layout logging.
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: clip
        )

        built = true

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
            let y = CGFloat(row) * NativeGrid.rowHeight - NativeGrid.contentInsetTop
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
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
        return container
    }

    // MARK: Fixed-strip layout (gutter | data)

    func layoutContainer() {
        let b = container.bounds
        guard b.width > 0, b.height > 0 else { return }
        let gw = gutterWidth
        // Data scroll view sits to the RIGHT of the fixed gutter strip and fills
        // the full window height (so it extends under the band; the top inset
        // rests row 0 below it).
        scroll.frame = NSRect(x: gw, y: 0, width: max(0, b.width - gw), height: b.height)
        // Band: the full-width top strip (window top -> header bottom).
        band.frame = NSRect(x: 0, y: b.height - NativeGrid.bandHeight, width: b.width, height: NativeGrid.bandHeight)
        // Header: the bottom 22 pt of the band, aligned with the data columns.
        header.frame = NSRect(x: gw, y: b.height - NativeGrid.bandHeight,
                              width: max(0, b.width - gw), height: NativeGrid.headerHeight)
        // Gutter: the fixed left strip, FULL window height (like the scroll
        // view) so its row numbers scroll up under the band and frost through
        // it exactly like the data, instead of stopping dead at the band's
        // bottom edge. z-order (behind the band, above the scroll) does the
        // actual frosting; the frame just gives it the room to draw into.
        gutter.frame = NSRect(x: 0, y: 0, width: gw, height: b.height)
        header.contentOffsetX = scroll.contentView.bounds.origin.x
        // Re-derive the column window for the (possibly just-resized) clip
        // BEFORE sizing the table column, so a width grown by newly-revealed
        // columns is reflected in this SAME layout pass, not one tick later.
        refreshColumnWindow()
        refreshColumnWidth()
        header.needsDisplay = true
        gutter.needsDisplay = true
        emitLayoutFramesIfEnabled()
    }

    /// The single table column's width: exactly the viewport when the data
    /// columns fit inside it, and the data width only when the data genuinely
    /// overflows (the sole case that warrants a horizontal scroller). The empty
    /// filler columns carry the spreadsheet fill to the right edge as a DRAWING
    /// device — the row view paints their hairlines and clips at the column width.
    /// Uses `totalDataWidth` (ALL visible columns, model-cached) rather than
    /// summing `widths` — `widths` is now just the horizontal column WINDOW
    /// (ARCH-column-windowing), far narrower than the true scrollable extent
    /// on a wide document. `site` labels the probe line with the caller
    /// (diagnostic only): "layout" from `layoutContainer`, "scroll" from
    /// `clipBoundsChanged` re-syncing against the clip's OWN width changes
    /// (e.g. a vertical scroller inserting/removing itself) independent of
    /// the gutter/container frame, "estimate" from `syncRowCountEstimate`
    /// re-syncing against the SAME kind of clip-width change when it happens
    /// AT REST (no scroll to catch it).
    private func refreshColumnWidth(site: String = "layout") {
        let dataWidth = totalDataWidth
        let viewportW = scroll.contentView.bounds.width
        fillerColumns = viewportW > dataWidth
            ? Int(ceil((viewportW - dataWidth) / GridMetrics.fillerColumnWidth)) : 0
        // Fill to the viewport, never past it. The old `dataWidth + fillerColumns
        // * fillerWidth` overshot by up to one filler width (ceil rounds the
        // filler count up), leaving a permanent sliver of horizontal overscroll —
        // i.e. a spurious horizontal scroller even for a few short columns. The
        // filler hairlines still fill the width (drawn by the row view, clipped
        // at the column edge); only the column's own width is clamped, so nothing
        // scrolls horizontally unless the real data is wider than the viewport.
        let target = max(dataWidth, viewportW)
        if abs(column.width - target) > 0.5 { column.width = target }
        ColWidthProbe.log(
            site: site, total: dataWidth, viewport: viewportW, scrollFrame: scroll.frame.width,
            documentWidth: table.frame.width, columnWidth: column.width, filler: fillerColumns,
            hScrollerHidden: scroll.horizontalScroller?.isHidden ?? true
        )
    }

    // MARK: Model -> AppKit

    /// Pull the STRUCTURAL geometry from the model: the row-number gutter
    /// width and the total content width (`model.totalVisibleWidth`, O(visible
    /// columns)). Run only on a structural change — build / open / hidden-
    /// column reflow / filter toggle / a width-batch change — NEVER per
    /// scroll tick (ARCH-column-windowing); see `refreshColumnWindow` for the
    /// O(window) counterpart that IS safe on every tick.
    private func refreshLayoutMetrics() {
        gutterWidth = model.rowNumberColumnWidth()
        totalDataWidth = model.totalVisibleWidth
    }

    /// (Re)derives the horizontal column window from the CURRENT scroll clip
    /// (x-offset + viewport width) and pulls the window-bound widths/labels
    /// the row/header views draw — the horizontal analog of `viewportChanged`'s
    /// row window (ARCH-column-windowing). `model.horizontalViewportChanged`
    /// is O(visible columns) of plain arithmetic (never O(columns) of text
    /// layout) and a no-op once the window settles, so this is cheap enough
    /// to call on EVERY layout pass and scroll tick — unlike
    /// `refreshLayoutMetrics`, which stays gated to structural changes.
    private func refreshColumnWindow() {
        let clip = scroll.contentView.bounds
        model.horizontalViewportChanged(viewportX: clip.origin.x, viewportWidth: clip.width)
        widths = model.windowWidths()
        headerLabels = model.windowHeaderLabels()
        headerTruncated = model.windowHeaderTruncated()
        columnAlignments = model.windowColumnAlignments()
        absoluteColumns = model.windowAbsoluteColumns()
        columnFirstX = CGFloat(model.columnWindow.firstX)
        let truncatedColumns = zip(absoluteColumns, headerTruncated).compactMap { column, truncated in
            truncated ? "column \(column + 1) label truncated" : nil
        }
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.group)
        header.setAccessibilityLabel(truncatedColumns.isEmpty
            ? "Column headers"
            : "Column headers, \(truncatedColumns.joined(separator: ", "))")
        // The header's resize hit-zones (ARCH-select-copy AC5) sit at fixed
        // OFFSETS from this same geometry — AppKit does not re-derive cursor
        // rects on a mere content-offset/width change (only on a frame change
        // or an explicit invalidate), so poke it here alongside every place
        // that already marks the header for a repaint.
        container.window?.invalidateCursorRects(for: header)
    }

    /// The single funnel for model-driven grid updates (idempotent). Called from
    /// `updateNSView` whenever `GridView.body` re-runs (any tracked model fact
    /// changed). Detects what changed and does the minimum AppKit work — all
    /// O(viewport)/O(1).
    func apply() {
        guard built, container.window != nil else { return }

        // Re-open / dialect re-open: columns + widths reset; reload from the top.
        if model.openGeneration != lastOpenGeneration {
            // A header on/off toggle keeps its place instead of flashing to row 0:
            // capture the EXACT top data row from the current (pre-reload) scroll
            // BEFORE anything resets it, then re-land on the SAME file record after
            // the ±1 data-row shift (O(viewport) — the anchor row is at/near the
            // already-scanned frontier, so there is no scan and no stall).
            let headerShift = model.consumePendingHeaderShift()
            let preToggleTop = headerShift != nil ? currentTopDataRow() : 0

            lastOpenGeneration = model.openGeneration
            refreshLayoutMetrics()
            lastVisibleColumns = model.visibleColumns
            lastColumnWidths = model.columnWidths
            lastColumnPresentationRevision = model.columnPresentationRevision
            lastColumnWidthRevision = model.columnWidthRevision
            lastColumnConfigurationRevision = model.columnConfigurationRevision
            layoutContainer()
            table.reloadData()
            lastRowCount = numberOfRows(in: table)
            if let shift = headerShift {
                // At the very top, stay at the top of data; otherwise carry the top
                // row across the shift. Clamp to the (possibly ±1) new data range.
                let target = preToggleTop == 0 ? 0 : max(0, preToggleTop + shift)
                let landed = min(target, max(0, dataRowCount - 1))
                scrollToTopLeft()        // reset the horizontal offset + baseline
                landOn(row: landed)      // re-anchor vertically to the same record
                HeaderToggleProbe.toggled(oldTop: preToggleTop, newTop: landed,
                                          newHasHeader: model.dialect.hasHeader, shift: shift)
            } else if model.pendingScrollRow == nil {
                scrollToTopLeft()
            }
            refreshVisibleRows()
            applyPendingLanding()
            flushGridDisplay()
            return
        }

        let configurationChanges = model.columnConfigurationChanges(after: lastColumnConfigurationRevision)
        if configurationChanges.revision != lastColumnConfigurationRevision {
            lastColumnConfigurationRevision = configurationChanges.revision
            let canTarget = configurationChanges.columns != nil
                && model.columnPresentationRevision == lastColumnPresentationRevision
                && model.visibleColumns == lastVisibleColumns
                && model.isFiltered == lastIsFiltered
                && numberOfRows(in: table) == lastRowCount
                && model.pendingScrollRow == nil
            if canTarget, let columns = configurationChanges.columns {
                if model.columnWidthRevision != lastColumnWidthRevision {
                    lastColumnWidthRevision = model.columnWidthRevision
                    refreshConfiguredColumnWidths(columns)
                    lastColumnWidths = model.columnWidths
                } else {
                    refreshConfiguredColumns(columns)
                }
                flushGridDisplay()
                return
            }
            refreshColumnWindow()
            header.needsDisplay = true
        }

        // Type/format/metadata changes can alter displayed text/alignment
        // without changing structural arrays. Re-pull only the bounded
        // horizontal window. A panel width edit additionally refreshes the
        // document extent through the existing targeted width path.
        if model.columnWidthRevision != lastColumnWidthRevision {
            lastColumnWidthRevision = model.columnWidthRevision
            lastColumnPresentationRevision = model.columnPresentationRevision
            refreshAfterWidthChange()
            lastColumnWidths = model.columnWidths
        } else if model.columnPresentationRevision != lastColumnPresentationRevision {
            lastColumnPresentationRevision = model.columnPresentationRevision
            refreshColumnWindow()
            header.needsDisplay = true
        }

        // Hidden-column reflow / width change: recompute strip + reload. Preserve
        // the scroll clip origin across it — layoutContainer resets scroll.frame
        // and reloadData can clamp the clip, which would desync the visual scroll
        // (gutter) from the model window (cells) mid-scroll, e.g. when columns
        // grow to fit content while paging. (Same guard the estimate branch uses.)
        if model.visibleColumns != lastVisibleColumns || model.columnWidths != lastColumnWidths {
            lastVisibleColumns = model.visibleColumns
            lastColumnWidths = model.columnWidths
            let origin = scroll.contentView.bounds.origin
            refreshLayoutMetrics()
            layoutContainer()
            table.reloadData()
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            lastRowCount = numberOfRows(in: table)
        }

        // Filter mode toggled (entered/cleared): the gutter switches between
        // identity and original row numbers and may need to widen/narrow for
        // the captured document row count (ARCH criterion 13) — refresh its
        // metrics right away rather than waiting for the next scroll.
        if model.isFiltered != lastIsFiltered {
            lastIsFiltered = model.isFiltered
            refreshLayoutMetrics()
            layoutContainer()
        }

        // Row-count estimate refined (grows/shrinks toward exact as the index
        // advances): keep the scrollbar in sync — deferred while the clip is
        // mid an elastic overscroll bounce (see `syncRowCountEstimate` below).
        syncRowCountEstimate()

        // Data filled in (window paged) or highlights changed: redraw visibles.
        refreshVisibleRows()

        // A pending landing (jump / find / wrap / cancel restore): O(viewport).
        applyPendingLanding()

        // Flush any config/visibility-driven repaint to screen NOW (see
        // `flushGridDisplay`): an edit made from the separate, key Settings
        // window otherwise only marks this window's rows/header needsDisplay,
        // and AppKit defers that draw until this window next handles an event
        // (the reported "changes only appear on click").
        flushGridDisplay()
    }

    /// Schedule outside the model mutation turn. This is the direct half of
    /// the landing bridge; the observed `pendingScrollRow` remains a safety
    /// net, while this guarantees an AppKit apply even if SwiftUI coalesces the
    /// representable update or the request arrived before window attachment.
    private func scheduleLandingApply() {
        guard !landingApplyScheduled else { return }
        landingApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.landingApplyScheduled = false
            self.apply()
        }
    }

    private func applyPendingLanding() {
        guard let target = model.pendingScrollRow else { return }
        model.pendingScrollRow = nil
        let row = Int(min(target, UInt64(Int.max)))
        landOn(row: row)
        ViewportLandingProbe.note(
            requestedRow: row,
            visibleRows: table.rows(in: table.visibleRect),
            offsetY: scroll.contentView.bounds.origin.y
        )
    }

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
    private func syncRowCountEstimate() -> Bool {
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
        EstimateReloadProbe.noteDecision(
            applied: !(overX || overY), rows: rows, lastRows: lastRowCount,
            origin: origin, overscrollX: overX, overscrollY: overY
        )
        guard !overX, !overY else { return false }
        lastRowCount = rows
        table.reloadData()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    /// Re-entrancy guard for `reanchorIfStrandedPastNewEnd`'s own
    /// `clip.scroll(to:)` call, which can synchronously re-enter this file's
    /// `clipBoundsChanged` -> `syncRowCountEstimate` (AppKit's bounds-changed
    /// notification is not documented to skip a same-value set, so relying on
    /// "the origin no longer needs correcting" to stop a recursion would be
    /// unproven). The flag makes the recursion provably bounded regardless: a
    /// re-entrant call always finds `reanchoring` true and returns before
    /// touching the clip again — any further work the re-entrant call does is
    /// merely redundant (idempotent reload/restore), never unbounded.
    private var reanchoring = false

    /// Snaps the clip's Y origin down to the new bottom edge when the
    /// estimate SHRANK enough to leave it resting past it — the stranded-
    /// past-EOF case (see `syncRowCountEstimate`). Mirrors `landOn`'s own end
    /// clamp exactly, so the re-anchored position is indistinguishable from a
    /// genuine jump-to-end landing: the last row settles above the EOF
    /// overscroll filler, never mid-air past it. Never fires on growth (the
    /// new maxY only rises) or when the current origin is already inside the
    /// new range — the ordinary case on every file, pathological or not.
    private func reanchorIfStrandedPastNewEnd(rows: Int) {
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
    private func overscrollAxes() -> (x: Bool, y: Bool) {
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
    private func landOn(row: Int) {
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
        let y = min(max(desired, -NativeGrid.contentInsetTop), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private func scrollToTopLeft() {
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
    private func currentTopDataRow() -> Int {
        let y = scroll.contentView.bounds.origin.y
        let row = ((y + NativeGrid.contentInsetTop) / NativeGrid.rowHeight).rounded()
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
        let b = container.bounds

        // 2) Rows: paint each visible row view individually over the data area.
        // The clip is balanced on ctx (save/restore AFTER current = ctx) so it
        // does NOT leak into the band step below.
        ctx.saveGraphicsState()
        NSRect(x: gutterWidth, y: 0, width: b.width - gutterWidth, height: b.height - NativeGrid.bandHeight)
            .clip()
        table.tile()
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 0 {
            for row in visible.location..<(visible.location + visible.length) {
                guard let rv = table.rowView(atRow: row, makeIfNecessary: true) as? SheetRowView else { continue }
                configure(rv, row: row)
                guard let sub = rv.bitmapImageRepForCachingDisplay(in: rv.bounds) else { continue }
                rv.cacheDisplay(in: rv.bounds, to: sub)
                sub.draw(in: rv.convert(rv.bounds, to: container))
            }
        }
        ctx.restoreGraphicsState()

        // 3) Band + header: the live NSGlassEffectView does not render off-screen
        // (blank in the capture), which would leave the header text on nothing —
        // invisible in dark mode. Paint a SEMANTIC material stand-in for the band
        // and re-draw the header text on top so it stays legible; the real
        // frosted band is a live/on-screen check.
        let bandRect = NSRect(x: 0, y: b.height - NativeGrid.bandHeight, width: b.width, height: NativeGrid.bandHeight)
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
        NSRect(x: 0, y: b.height - NativeGrid.bandHeight, width: b.width, height: NativeGrid.hairline).fill()
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

    // MARK: Scroll handling (paging + sync + probes)

    @objc private func clipBoundsChanged() {
        let clip = scroll.contentView

        // Page the core window to the visible span (O(1) setWindow off the
        // scroll path; hysteresis lives in the model).
        let visible = table.rows(in: table.visibleRect)
        if visible.length > 0 {
            let first = min(visible.location, max(0, dataRowCount - 1))
            model.viewportChanged(firstVisibleRow: first, visibleRowCount: visible.length)
        }

        // The row-number gutter may widen when bigger numbers scroll in — a
        // full relayout (frames + column/filler width) when it does.
        let gw = model.rowNumberColumnWidth()
        if abs(gw - gutterWidth) > 0.5 {
            gutterWidth = gw
            layoutContainer()
        }
        // The clip's OWN width can also change independent of the gutter — e.g.
        // a vertical scroller inserting/removing itself as the row-count
        // estimate crosses its need threshold (this can settle a tick AFTER
        // `layoutContainer` last read `scroll.contentView.bounds.width`, since
        // that read races the scroller's own internal tile — PROVEN by
        // LESSSHEET_LOG_COLWIDTH: a "layout" reading can show `colwidth` matching
        // a since-shrunk `viewport` one tick later). Re-sync the column/filler
        // width to the FRESH, now-settled clip width on every scroll/bounds tick
        // (cheap: O(visibleColumns)) so a stale, too-wide `column.width` can
        // never linger and force a spurious horizontal scroller (or hide a
        // genuine one) — `layoutContainer` already covers this when the gutter
        // branch above ran; harmless to re-run.
        //
        // Re-derive the horizontal column window for the CURRENT scroll x, so
        // a horizontal drag/fling reveals newly-in-window columns (measured,
        // fetched, drawn) exactly like `viewportChanged` does for a vertical
        // one — O(window), never O(columnCount) (ARCH-column-windowing); a
        // no-op once the window and widths settle. Already re-derived by
        // `layoutContainer` when the gutter branch above ran; harmless (cheap)
        // to re-run against the settled clip.
        refreshColumnWindow()
        refreshColumnWidth(site: "scroll")

        header.contentOffsetX = clip.bounds.origin.x
        header.needsDisplay = true
        gutter.needsDisplay = true

        // Flush a row-count-estimate reload `apply()` deferred while this same
        // clip was mid an elastic overscroll bounce (see `syncRowCountEstimate`):
        // EVERY scroll tick lands here, including the bounce's settling one, so
        // this is how a deferred reload gets applied the instant it is safe
        // again, without waiting for the next poll-driven `apply()`.
        syncRowCountEstimate()

        // Reconfigure the visible rows from the CURRENT window on every scroll,
        // not only when the window identity changes. During a fast fling a row
        // view is configured empty while the window lags; when the fling settles
        // inside a window that already covers those rows, no window-change refresh
        // fires — so without this they stay blank until recycled by another
        // scroll (the reported gaps). configure is O(viewport); cheap per tick.
        refreshVisibleRows()

        ScrollProbe.note(clip.bounds.origin)        // inert unless LESSSHEET_LOG_OFFSET
        emitLayoutFramesIfEnabled()
    }

    // MARK: Row refresh (data / highlights)

    /// Forces the grid's already-marked-dirty viewport (rows, header, gutter)
    /// to draw synchronously, without waiting for the next event in this
    /// window. A column-config or visibility mutation arrives from the SEPARATE
    /// (key) Settings window; SwiftUI observation still re-runs `GridView.body`
    /// -> `apply()` promptly on the main actor, and the branches above mark the
    /// affected cells/columns needsDisplay — but AppKit only flushes that draw
    /// for a non-key window on its next event (the reported "instant in the
    /// header, but the data waits for a click"). `displayIfNeeded` repaints just
    /// what is dirty in the visible viewport (O(viewport), never a full-file
    /// rescan) and is a no-op when nothing is dirty, so the config path is
    /// instant while the scroll path — which never calls this — pays nothing.
    private func flushGridDisplay() {
        table.displayIfNeeded()
        header.displayIfNeeded()
        gutter.displayIfNeeded()
    }

    private func refreshVisibleRows() {
        // Reconfigure EVERY live row view, not just those in the current
        // visibleRect: after a fast fling a row view can be created empty (the
        // viewport outran the window), then sit just off the visible rect when
        // the window catches up — so a visibleRect-only refresh leaves stale
        // gaps that only fill when the row is recycled by another scroll.
        // enumerateAvailableRowViews covers the whole live pool.
        table.enumerateAvailableRowViews { rowView, row in
            if let rv = rowView as? SheetRowView {
                self.configure(rv, row: row)
                rv.needsDisplay = true
            }
        }
        gutter.needsDisplay = true
    }

    /// Recomputes only the configured logical column in each recycled row and
    /// invalidates only that subcolumn's rectangle. There is one physical
    /// NSTableColumn, so NSTableView's column-index reload API would reload the
    /// whole custom row; this is the equivalent targeted path for our packed
    /// logical columns.
    private func refreshConfiguredColumns(_ columns: Set<Int>) {
        let targets = absoluteColumns.enumerated().filter { columns.contains($0.element) }
        guard !targets.isEmpty else { return }
        for (index, column) in targets where columnAlignments.indices.contains(index) {
            columnAlignments[index] = model.columnAlignment(column)
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard row < self.dataRowCount, let rv = rowView as? SheetRowView else { return }
            for (index, column) in targets where rv.cells.indices.contains(index) {
                let presentation = self.model.windowCellPresentation(forRow: row, column: column)
                rv.cells[index] = presentation.text
                if rv.formatUnavailable.indices.contains(index) {
                    rv.formatUnavailable[index] = presentation.formatUnavailable
                }
                if rv.conflicts.indices.contains(index) { rv.conflicts[index] = presentation.conflict }
                self.refreshAccessibilityWarning(rv, row: row, index: index)
                let rect = self.logicalCellRect(index: index, height: rv.bounds.height)
                rv.setNeedsDisplay(rect)
            }
            self.applyAccessibilityLabel(rv, row: row)
        }
    }

    /// A one-column width remeasure can shift following pixels, but it does
    /// not require recomputing their cell presentations. Refresh geometry,
    /// update only the configured column's arrays, and invalidate the shifted
    /// suffix. A rare horizontal-window boundary change falls back globally.
    private func refreshConfiguredColumnWidths(_ columns: Set<Int>) {
        let oldColumns = absoluteColumns
        let oldFirstX = columnFirstX
        let oldWidths = widths
        refreshLayoutMetrics()
        refreshColumnWindow()
        refreshColumnWidth(site: "column-config")
        guard absoluteColumns == oldColumns else {
            table.reloadData()
            refreshVisibleRows()
            header.needsDisplay = true
            return
        }
        refreshConfiguredColumns(columns)

        // An upstream off-window width changes the exact prefix-sum origin
        // while leaving the visible IDs untouched. In that case every visible
        // cell moved, so repaint the shifted viewport (presentations remain
        // reusable). Otherwise invalidate only from the first changed visible
        // width; the common in-window edit therefore stays a suffix repaint.
        if columnFirstX != oldFirstX {
            invalidateVisibleGeometry()
        } else if let firstChangedWidth = widths.indices.first(where: {
            !oldWidths.indices.contains($0) || oldWidths[$0] != widths[$0]
        }) {
            invalidateVisibleGeometry(from: firstChangedWidth)
        }
    }

    private func invalidateVisibleGeometry(from index: Int? = nil) {
        table.enumerateAvailableRowViews { rowView, _ in
            guard let index else {
                rowView.setNeedsDisplay(rowView.bounds)
                return
            }
            let rect = self.logicalCellRect(index: index, height: rowView.bounds.height)
            rowView.setNeedsDisplay(NSRect(x: rect.minX, y: 0,
                                           width: max(0, rowView.bounds.maxX - rect.minX),
                                           height: rowView.bounds.height))
        }
        guard let index else {
            header.setNeedsDisplay(header.bounds)
            return
        }
        let rect = logicalCellRect(index: index, height: header.bounds.height)
        let localX = rect.minX - header.contentOffsetX
        header.setNeedsDisplay(NSRect(x: localX, y: 0,
                                      width: max(0, header.bounds.maxX - localX),
                                      height: header.bounds.height))
    }

    private func logicalCellRect(index: Int, height: CGFloat) -> NSRect {
        var x = columnFirstX
        if index > 0 { x += widths.prefix(index).reduce(0, +) }
        let width = widths.indices.contains(index) ? widths[index] : 0
        return NSRect(x: x, y: 0, width: width, height: height)
    }

    private func configure(_ rv: SheetRowView, row: Int) {
        rv.controller = self
        if row < dataRowCount {
            rv.isFiller = false
            // Not-yet-servable (within the estimated range but past the
            // materialized scan frontier): `windowBodyCells` already empty-
            // pads it exactly like a genuinely empty row, so this flag is
            // what lets the row view tell the two apart and draw a loading
            // placeholder instead of silently blank cells (PROJECT: constant
            // feedback, no silent stalls).
            rv.pending = !model.rowLoaded(forRow: row)
            // Column-WINDOW bound (ARCH-column-windowing) — O(window), never
            // O(columnCount): the live grid only ever needs the columns it is
            // about to draw, unlike the eager dump grid (FrameDump).
            let presentations = model.windowCellPresentations(forRow: row)
            rv.cells = presentations.map(\.text)
            rv.formatUnavailable = presentations.map(\.formatUnavailable)
            rv.conflicts = presentations.map(\.conflict)
            rv.truncated = model.windowBodyTruncated(forRow: row)
            rv.highlights = model.windowCellHighlights(forRow: row)
            rv.selectionMarks = model.windowSelectionMarks(forRow: row)
        } else {
            rv.isFiller = true
            rv.pending = false
            rv.cells = []
            rv.formatUnavailable = []
            rv.conflicts = []
            rv.truncated = []
            rv.highlights = []
            rv.selectionMarks = []
        }
        rv.accessibilityWarnings.removeAll(keepingCapacity: true)
        for index in rv.cells.indices { refreshAccessibilityWarning(rv, row: row, index: index) }
        applyAccessibilityLabel(rv, row: row)
    }

    private func refreshAccessibilityWarning(_ rv: SheetRowView, row: Int, index: Int) {
        var value = [String]()
        if index < rv.truncated.count, rv.truncated[index] { value.append("value truncated") }
        if index < rv.conflicts.count, rv.conflicts[index] { value.append("type conflict") }
        if index < rv.formatUnavailable.count, rv.formatUnavailable[index] { value.append("format unavailable") }
        guard !value.isEmpty else {
            rv.accessibilityWarnings.removeValue(forKey: index)
            return
        }
        let column = index < absoluteColumns.count ? absoluteColumns[index] + 1 : index + 1
        rv.accessibilityWarnings[index] = "column \(column) \(value.joined(separator: ", "))"
    }

    private func applyAccessibilityLabel(_ rv: SheetRowView, row: Int) {
        let states = rv.accessibilityWarnings.keys.sorted().compactMap { rv.accessibilityWarnings[$0] }
        rv.setAccessibilityElement(true)
        rv.setAccessibilityRole(.row)
        rv.setAccessibilityLabel("Row \(row + 1)" + (states.isEmpty ? "" : ", \(states.joined(separator: ", "))"))
    }

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
    private func cellAt(_ point: NSPoint) -> GridCell? {
        guard let index = windowColumnIndex(atX: point.x), index < absoluteColumns.count else { return nil }
        return GridCell(row: UInt64(rowAt(point)), column: absoluteColumns[index])
    }

    /// The data row at a TABLE-local point, clamped to `0 ..< dataRowCount`
    /// (never into the filler/overscroll strip, and never below row 0 for a
    /// point above the table's own top edge).
    private func rowAt(_ point: NSPoint) -> Int {
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
    private func windowColumnIndex(atX x: CGFloat) -> Int? {
        guard !widths.isEmpty else { return nil }
        var cursor = columnFirstX
        for (i, w) in widths.enumerated() {
            if x < cursor + w { return i }
            cursor += w
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
    func gutterMouseDown(atY y: CGFloat, shift: Bool) {
        container.window?.makeFirstResponder(table)
        let row = UInt64(rowAt(NSPoint(x: 0, y: y)))
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
    func headerMouseDown(atX x: CGFloat, shift: Bool) {
        guard let index = windowColumnIndex(atX: x), index < absoluteColumns.count else { return }
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
    func configureColumnFromHeader(atX x: CGFloat) {
        guard let index = windowColumnIndex(atX: x), index < absoluteColumns.count else { return }
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

    /// Selection changes alter only overlay geometry. Recompute marks and
    /// repaint the recycled rows without calling `configure`: reconfiguration
    /// re-reads paging state and could transiently replace already-rendered
    /// values with loading placeholders while a drag is in progress.
    private func refreshSelectionDisplay() {
        table.enumerateAvailableRowViews { rowView, row in
            guard let rv = rowView as? SheetRowView else { return }
            rv.selectionMarks = row < self.dataRowCount
                ? self.model.windowSelectionMarks(forRow: row) : []
            rv.needsDisplay = true
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
    private func refreshAfterWidthChange() {
        refreshLayoutMetrics()
        refreshColumnWindow()
        refreshColumnWidth(site: "resize")
        header.needsDisplay = true
        gutter.needsDisplay = true
        table.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        dataRowCount + fillerRowCount()
    }

    /// Empty grid rows kept below the last data row: the EOF overscroll strip
    /// (so the last rows clear the floating controls), extended to fill the
    /// viewport when the document is shorter than it. Pure fill — the model's
    /// row-count estimate ignores it.
    private func fillerRowCount() -> Int {
        let viewportRows = Int(ceil(scroll.contentView.bounds.height / NativeGrid.rowHeight))
        return max(GridMetrics.overscrollRows, viewportRows - dataRowCount + GridMetrics.overscrollRows)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("sheetRow")
        let rv = (tableView.makeView(withIdentifier: id, owner: self) as? SheetRowView) ?? {
            let v = SheetRowView(); v.identifier = id; return v
        }()
        configure(rv, row: row)
        return rv
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
    private func emitLayoutFramesIfEnabled() {
        guard ScrollProbe.layoutEnabled, let content = container.window?.contentView else { return }
        let h = content.bounds.height
        func yDown(_ rect: NSRect, _ view: NSView) -> CGRect {
            let w = view.convert(rect, to: nil)
            return CGRect(x: w.minX, y: h - w.maxY, width: w.width, height: w.height)
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

// MARK: - Row view (custom-drawn cells + hairlines + highlights)

/// One data (or filler) row. Draws every visible-column cell, its per-column
/// right hairline, the filler-column hairlines out to the right edge, and a
/// full-width bottom hairline — the spreadsheet fill, one view per row (recycled
/// by NSTableView). Tabular numerals; semantic colors (dark mode automatic);
/// find highlights subtle/strong; the ARCH-select-copy selection overlay reuses
/// the SAME accent-fill/border language (`selectionMarks`, below). Header/filler
/// rows never carry highlights or selection marks.
final class SheetRowView: NSTableRowView {
    weak var controller: NativeGridController?
    var cells: [String] = []
    /// Display-only warning states parallel to `cells`. They never alter raw
    /// copy/find/filter values; the row paints and exposes them accessibly.
    var formatUnavailable: [Bool] = []
    var conflicts: [Bool] = []
    var accessibilityWarnings: [Int: String] = [:]
    /// Per-cell display-truncation flags, PARALLEL to `cells` (ARCH req. 13/20;
    /// mirrors `RowWindow.truncated`). Drives `drawTruncationMarker` only — the
    /// core's flag is rendered as-is, never re-derived from measured text.
    var truncated: [Bool] = []
    var highlights: [SheetCellHighlight] = []
    /// Selection-overlay state per visible column (ARCH-select-copy AC1),
    /// PARALLEL to `cells`/`highlights` — precomputed by the model
    /// (`DocumentModel.windowSelectionMarks`), never derived here: `draw`
    /// stays a flat, O(visible columns) per-frame read, exactly like the
    /// find-highlight fill it reuses.
    var selectionMarks: [SelectionMark] = []
    var isFiller = false
    /// A data row within the estimated range but NOT YET SERVABLE — past the
    /// materialized scan frontier (`DocumentModel.cells(forRow:)` returned
    /// `nil`) — as opposed to a genuinely empty row. `cells` is already
    /// empty-padded identically for both, so this is the ONLY signal that
    /// distinguishes "still loading" from "loaded and blank": it drives a
    /// subtle placeholder bar per empty cell instead of rendering nothing.
    /// Always false for filler rows (past EOF is not a loading state).
    var pending = false

    override var isFlipped: Bool { true }
    override var isEmphasized: Bool { get { false } set {} }   // never draw selection emphasis
    override func drawSelection(in dirtyRect: NSRect) {}       // pure viewer

    // Data cells: SF Mono (fully monospaced) so the file's content reads like the
    // raw file and columns line up. MUST match the width-measurement font in
    // DocumentModel (measureColumnWidths / growColumnWidthsToFitWindow) or the
    // columns would be sized for the wrong glyphs.
    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let c = controller else { return }
        let h = bounds.height
        let grid = NSColor.gridColor
        let accent = NSColor.controlAccentColor
        // `c.widths` is only the current horizontal column WINDOW
        // (ARCH-column-windowing); start at its exact prefix-sum offset so an
        // in-window column lands at the SAME x a full, unwindowed draw would
        // give it (0 for a viewport-fitting file — ARCH AC4 — and the real
        // scrolled-to offset otherwise).
        var x: CGFloat = c.columnFirstX

        for (i, w) in c.widths.enumerated() {
            let cell = NSRect(x: x, y: 0, width: w, height: h)
            guard cell.intersects(dirtyRect) else {
                x += w
                continue
            }
            let hl = i < highlights.count ? highlights[i] : .none
            switch hl {
            case .subtle: accent.withAlphaComponent(0.20).setFill(); cell.fill()
            case .strong: accent.withAlphaComponent(0.42).setFill(); cell.fill()
            case .none: break
            }
            // ARCH-select-copy AC1: the selection overlay reuses this SAME
            // accent-fill language, layered on top of (never instead of) a
            // find highlight — a cell can be both matched AND selected.
            let mark = i < selectionMarks.count ? selectionMarks[i] : .none
            if mark.isSelected {
                accent.withAlphaComponent(0.15).setFill()
                cell.fill()
            }
            if i < cells.count, !cells[i].isEmpty {
                let alignment: NSTextAlignment
                switch i < c.columnAlignments.count ? c.columnAlignments[i] : .leading {
                case .leading: alignment = .left
                case .center: alignment = .center
                case .trailing: alignment = .right
                }
                SheetRowView.drawText(cells[i], in: cell.insetBy(dx: GridMetrics.cellHPadding, dy: 0),
                                      font: SheetRowView.font, color: .labelColor, alignment: alignment)
            } else if pending {
                SheetRowView.drawPendingPlaceholder(in: cell)
            }
            if i < truncated.count, truncated[i] {
                SheetRowView.drawTruncationMarker(in: cell)
            }
            if i < formatUnavailable.count, formatUnavailable[i] {
                SheetRowView.drawStatusMarker(symbol: "number.circle", description: "Format unavailable",
                                              in: cell, trailingSlot: 0)
            }
            if i < conflicts.count, conflicts[i] {
                SheetRowView.drawStatusMarker(symbol: "exclamationmark.triangle", description: "Type conflict",
                                              in: cell, trailingSlot: formatUnavailable.indices.contains(i)
                                                && formatUnavailable[i] ? 1 : 0)
            }
            if hl == .strong {
                accent.setStroke()
                let p = NSBezierPath(rect: cell.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1.5
                p.stroke()
            }
            if mark.isSelected {
                SheetRowView.drawSelectionBorder(mark, in: cell, accent: accent)
            }
            grid.setFill()
            NSRect(x: x + w - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: h).fill()
            x += w
        }
        grid.setFill()
        for _ in 0..<c.fillerColumns {
            x += GridMetrics.fillerColumnWidth
            let line = NSRect(x: x - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: h)
            if line.intersects(dirtyRect) { line.fill() }
        }
        // Full-width bottom hairline (data -> filler seam is continuous).
        NSRect(x: dirtyRect.minX, y: h - NativeGrid.hairline,
               width: dirtyRect.width, height: NativeGrid.hairline).fill()
    }

    /// A truncated cell's indicator (ARCH req. 13/20): a subtle dot inset from
    /// the column's trailing hairline. AppKit's own `.byTruncatingTail` already
    /// ends an overflowing cell in "…" when it is wider than the column — this
    /// marker is the ADDITIONAL cue that the CORE cut the underlying data at the
    /// 4 KiB display cap (`RowWindow.truncated`), distinct from ordinary
    /// column-width overflow (which can happen to any cell, truncated or not).
    /// Purely presentational: driven by the flag as given, never a re-measure.
    static func drawTruncationMarker(in cell: NSRect) {
        let diameter: CGFloat = 5
        let margin: CGFloat = 3   // clearance from the column's trailing hairline
        let dot = NSRect(x: cell.maxX - margin - diameter, y: (cell.height - diameter) / 2,
                         width: diameter, height: diameter)
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// Non-colour-only warning glyph used for formatting fallback/conflicts.
    static func drawStatusMarker(symbol: String, description: String, in cell: NSRect, trailingSlot: Int) {
        guard cell.width >= 22,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return }
        image.isTemplate = true
        let size: CGFloat = 12
        let x = cell.maxX - 10 - size - CGFloat(trailingSlot) * (size + 3)
        image.draw(in: NSRect(x: x, y: cell.midY - size / 2, width: size, height: size),
                   from: .zero, operation: .sourceOver, fraction: 0.75,
                   respectFlipped: true, hints: nil)
    }

    /// The selection RANGE border (ARCH-select-copy AC1): strokes only the
    /// side(s) of `cell` that sit on the selection rect's OUTER edge (an
    /// interior selected cell gets the accent fill only, drawn above — no
    /// stroke), so a multi-cell selection reads as one continuous outlined
    /// range rather than a grid of individually-boxed cells. Mirrors the
    /// find "current match" border's weight/inset for a consistent look.
    static func drawSelectionBorder(_ mark: SelectionMark, in cell: NSRect, accent: NSColor) {
        accent.setStroke()
        let r = cell.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        if mark.borderTop { path.move(to: NSPoint(x: r.minX, y: r.minY)); path.line(to: NSPoint(x: r.maxX, y: r.minY)) }
        if mark.borderBottom { path.move(to: NSPoint(x: r.minX, y: r.maxY)); path.line(to: NSPoint(x: r.maxX, y: r.maxY)) }
        if mark.borderLeft { path.move(to: NSPoint(x: r.minX, y: r.minY)); path.line(to: NSPoint(x: r.minX, y: r.maxY)) }
        if mark.borderRight { path.move(to: NSPoint(x: r.maxX, y: r.minY)); path.line(to: NSPoint(x: r.maxX, y: r.maxY)) }
        path.stroke()
    }

    /// The "still loading" placeholder for a not-yet-servable cell (`pending`
    /// — new request: a subtle, native-consistent affordance so scrolling
    /// ahead of the scan frontier reads as "loading", never as silently-empty
    /// data). One flat, low-alpha rounded bar approximating a redacted line
    /// of text — the same idea as SwiftUI's `.redacted(reason: .placeholder)`,
    /// hand-drawn here since this view paints its own cells. Deliberately
    /// STATIC — no shimmer/animation — so it costs exactly one extra fill per
    /// empty cell on the scroll path (same order of cost as the highlight
    /// fills above) and never schedules a redraw loop of its own.
    static func drawPendingPlaceholder(in cell: NSRect) {
        let inset = cell.insetBy(dx: GridMetrics.cellHPadding, dy: 0)
        guard inset.width > 4, inset.height > 4 else { return }
        let barHeight = min(9, inset.height * 0.4)
        let bar = NSRect(x: inset.minX, y: inset.minY + (inset.height - barHeight) / 2,
                         width: inset.width * 0.55, height: barHeight)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    /// Single-line, tail-truncated text drawn vertically centered in `rect`.
    static func drawText(_ string: String, in rect: NSRect, font: NSFont, color: NSColor,
                         alignment: NSTextAlignment, weight: NSFont.Weight? = nil) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = alignment
        let f = weight.map { NSFont.systemFont(ofSize: font.pointSize, weight: $0) } ?? font
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: para]
        let size = (string as NSString).size(withAttributes: attrs)
        let y = (rect.height - size.height) / 2
        (string as NSString).draw(in: NSRect(x: rect.minX, y: rect.minY + y, width: rect.width, height: size.height),
                                  withAttributes: attrs)
    }
}

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
        // Translates the raw key event into one of the `moveXxx`/
        // `moveXxxAndModifySelection` calls below via AppKit's default key
        // bindings (arrows / shift-arrows) — framework-native, no hand-rolled
        // key-code switch. Anything the table doesn't handle beeps/forwards
        // exactly as a plain NSResponder would (the default `doCommand(by:)`).
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) { controller?.moveSelection(.up, extending: false) }
    override func moveDown(_ sender: Any?) { controller?.moveSelection(.down, extending: false) }
    override func moveLeft(_ sender: Any?) { controller?.moveSelection(.left, extending: false) }
    override func moveRight(_ sender: Any?) { controller?.moveSelection(.right, extending: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { controller?.moveSelection(.up, extending: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { controller?.moveSelection(.down, extending: true) }
    override func moveLeftAndModifySelection(_ sender: Any?) { controller?.moveSelection(.left, extending: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { controller?.moveSelection(.right, extending: true) }

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
    // some other field/popup) is first responder now cancels an in-flight copy,
    // same as the notice's own Cancel button.
    override func cancelOperation(_ sender: Any?) { controller?.cancelCopy() }
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
    private func resizeIndex(atLocalX x: CGFloat) -> Int? {
        guard let c = controller else { return nil }
        var edge = c.columnFirstX - contentOffsetX
        for (i, w) in c.widths.enumerated() {
            edge += w
            if abs(x - edge) <= Self.resizeHitHalfWidth { return i }
        }
        return nil
    }

    override func resetCursorRects() {
        guard let c = controller else { return }
        var edge = c.columnFirstX - contentOffsetX
        for w in c.widths {
            edge += w
            addCursorRect(
                NSRect(x: edge - Self.resizeHitHalfWidth, y: 0, width: Self.resizeHitHalfWidth * 2, height: bounds.height),
                cursor: .resizeLeftRight
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        handleClick(atLocalX: point.x, doubleClick: event.clickCount >= 2, shift: event.modifierFlags.contains(.shift))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let c = controller else { return nil }
        let menu = NSMenu(title: "Column")
        let item = NSMenuItem(title: "Configure Column…", action: #selector(configureColumn(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = point.x + contentOffsetX
        menu.addItem(item)
        c.container.window?.makeFirstResponder(self)
        return menu
    }

    @objc private func configureColumn(_ sender: NSMenuItem) {
        guard let x = sender.representedObject as? CGFloat else { return }
        controller?.configureColumnFromHeader(atX: x)
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
    func handleClick(atLocalX x: CGFloat, doubleClick: Bool, shift: Bool) {
        guard let c = controller else { return }
        if let index = resizeIndex(atLocalX: x) {
            if doubleClick {
                c.autoFitColumn(windowIndex: index)
            } else {
                resizingIndex = index
                resizeStartX = x
                resizeStartWidth = index < c.widths.count ? c.widths[index] : GridMetrics.minColumnWidth
            }
            return
        }
        c.headerMouseDown(atX: x + contentOffsetX, shift: shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = resizingIndex, let c = controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        c.resizeColumn(windowIndex: index, toWidth: resizeStartWidth + (point.x - resizeStartX))
    }

    override func mouseUp(with event: NSEvent) {
        resizingIndex = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller else { return }
        let h = bounds.height
        if capturesBackground {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        let grid = NSColor.gridColor
        // `c.widths` is only the current horizontal column WINDOW
        // (ARCH-column-windowing); position its first column at its exact
        // prefix-sum offset (`columnFirstX`), translated into this fixed
        // view's local space by the same horizontal-scroll offset the data
        // columns are drawn under.
        var x = c.columnFirstX - contentOffsetX

        for (i, w) in c.widths.enumerated() {
            let cell = NSRect(x: x, y: 0, width: w, height: h)
            if i < c.headerLabels.count {
                SheetRowView.drawText(c.headerLabels[i], in: cell.insetBy(dx: GridMetrics.cellHPadding, dy: 0),
                                      font: .systemFont(ofSize: NSFont.systemFontSize), color: .labelColor,
                                      alignment: .left, weight: .semibold)
            }
            if i < c.headerTruncated.count, c.headerTruncated[i] {
                SheetRowView.drawTruncationMarker(in: cell)
            }
            grid.setFill()
            NSRect(x: x + w - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: h).fill()
            x += w
        }
        grid.setFill()
        for _ in 0..<c.fillerColumns {
            x += GridMetrics.fillerColumnWidth
            NSRect(x: x - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: h).fill()
        }
        NSRect(x: 0, y: h - NativeGrid.hairline, width: bounds.width, height: NativeGrid.hairline).fill()
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
        guard let c = controller else { return }
        let tablePoint = c.table.convert(event.locationInWindow, from: nil)
        c.gutterMouseDown(atY: tablePoint.y, shift: event.modifierFlags.contains(.shift))
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
        guard let c = controller else { return }
        let table = c.table
        let visible = table.rows(in: table.visibleRect)
        let w = bounds.width
        let grid = NSColor.gridColor

        if visible.length > 0 {
            for row in visible.location..<(visible.location + visible.length) where row < c.dataRowCount {
                // The gutter's ORIGINAL (unfiltered) row number while a filter
                // is active (ARCH criterion 13/17), forwarded verbatim from
                // the core's `sourceRow` — never recomputed; the identity
                // `row` otherwise. A row not yet servable under a filter
                // (outside the materialized window) is left blank, same as
                // its cells.
                guard let source = c.model.gutterRow(forRow: row) else { continue }
                let inWindow = table.convert(table.rect(ofRow: row), to: nil)
                let local = convert(inWindow, from: nil)
                let cell = NSRect(x: 0, y: local.minY, width: w - GridMetrics.rowNumberHPadding, height: local.height)
                SheetRowView.drawText(String(source + 1), in: cell, font: GridGutterView.font,
                                      color: .secondaryLabelColor, alignment: .right)
                if c.model.rowOversized(forRow: row), let marker = GridGutterView.markerImage {
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
        NSRect(x: w - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: bounds.height).fill()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        GridGutterView.oversizedTooltip
    }
}
