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
    let table = NSTableView()
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
    private var lastIsFiltered = false
    private var built = false

    init(model: DocumentModel) {
        self.model = model
        super.init()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

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
        // drawn by the row view (fastest, pixel control). No selection, no drag-
        // resize, uniform row height => O(1) geometry at any row count.
        column.width = 400
        column.resizingMask = []
        table.addTableColumn(column)
        table.rowHeight = NativeGrid.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .textBackgroundColor
        table.headerView = nil                       // sticky header is drawn separately
        table.selectionHighlightStyle = .none        // pure viewer: no selection
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
        columnFirstX = CGFloat(model.columnWindow.firstX)
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
            } else {
                scrollToTopLeft()
            }
            refreshVisibleRows()
            return
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
        if let target = model.pendingScrollRow {
            model.pendingScrollRow = nil
            landOn(row: Int(min(target, UInt64(Int.max))))
        }
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
            rv.cells = model.windowBodyCells(forRow: row)
            rv.truncated = model.windowBodyTruncated(forRow: row)
            rv.highlights = model.windowCellHighlights(forRow: row)
        } else {
            rv.isFiller = true
            rv.pending = false
            rv.cells = []
            rv.truncated = []
            rv.highlights = []
        }
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
/// find highlights subtle/strong. Header/filler rows never carry highlights.
final class SheetRowView: NSTableRowView {
    weak var controller: NativeGridController?
    var cells: [String] = []
    /// Per-cell display-truncation flags, PARALLEL to `cells` (ARCH req. 13/20;
    /// mirrors `RowWindow.truncated`). Drives `drawTruncationMarker` only — the
    /// core's flag is rendered as-is, never re-derived from measured text.
    var truncated: [Bool] = []
    var highlights: [SheetCellHighlight] = []
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
            let hl = i < highlights.count ? highlights[i] : .none
            switch hl {
            case .subtle: accent.withAlphaComponent(0.20).setFill(); cell.fill()
            case .strong: accent.withAlphaComponent(0.42).setFill(); cell.fill()
            case .none: break
            }
            if i < cells.count, !cells[i].isEmpty {
                SheetRowView.drawText(cells[i], in: cell.insetBy(dx: GridMetrics.cellHPadding, dy: 0),
                                      font: SheetRowView.font, color: .labelColor, alignment: .left)
            } else if pending {
                SheetRowView.drawPendingPlaceholder(in: cell)
            }
            if i < truncated.count, truncated[i] {
                SheetRowView.drawTruncationMarker(in: cell)
            }
            if hl == .strong {
                accent.setStroke()
                let p = NSBezierPath(rect: cell.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1.5
                p.stroke()
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
        // Full-width bottom hairline (data -> filler seam is continuous).
        NSRect(x: 0, y: h - NativeGrid.hairline, width: bounds.width, height: NativeGrid.hairline).fill()
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

// MARK: - Sticky header (drawn, scrolls horizontally with its columns)

/// The column-title row. Transparent (the glass band shows through, data frosts
/// under it), semibold titles, per-column hairlines, a bottom hairline. Its
/// content offset tracks the table's horizontal scroll so it moves with the
/// columns; it never scrolls vertically (pinned in the band).
final class GridHeaderView: NSView {
    weak var controller: NativeGridController?
    var contentOffsetX: CGFloat = 0
    /// Live: transparent so the glass band frosts through behind the titles.
    /// Capture-only: fills a semantic material so the titles stay legible in the
    /// cacheDisplay PNG (the live glass renders blank off-screen). The fill
    /// resolves under this view's appearance, so it is dark in a dark capture.
    var capturesBackground = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

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

