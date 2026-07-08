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
// scroll, synced vertically to the table's rows).

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
    private(set) var widths: [CGFloat] = []
    private(set) var headerLabels: [String] = []
    private(set) var fillerColumns = 0
    private(set) var gutterWidth: CGFloat = 0

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
        container.addSubview(band)      // in front of scroll: rows frost under it
        container.addSubview(gutter)    // in front of scroll (below the band)
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
        // Gutter: the fixed left strip below the band.
        gutter.frame = NSRect(x: 0, y: 0, width: gw, height: max(0, b.height - NativeGrid.bandHeight))
        header.contentOffsetX = scroll.contentView.bounds.origin.x
        refreshColumnWidth()
        header.needsDisplay = true
        gutter.needsDisplay = true
        emitLayoutFramesIfEnabled()
    }

    /// Total table (single-column) width: data columns + the empty filler
    /// columns that carry the spreadsheet fill to the right window edge.
    private func refreshColumnWidth() {
        let dataWidth = widths.reduce(0, +)
        let viewportW = scroll.contentView.bounds.width
        fillerColumns = viewportW > dataWidth
            ? Int(ceil((viewportW - dataWidth) / GridMetrics.fillerColumnWidth)) : 0
        let total = dataWidth + CGFloat(fillerColumns) * GridMetrics.fillerColumnWidth
        let target = max(total, viewportW)
        if abs(column.width - target) > 0.5 { column.width = target }
    }

    // MARK: Model -> AppKit

    /// Pull the current visible-column geometry + row-number gutter width from
    /// the model. Cheap; run on every layout / open / hidden-column change.
    private func refreshLayoutMetrics() {
        widths = model.visibleWidths()
        headerLabels = model.headerLabels()
        gutterWidth = model.rowNumberColumnWidth()
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
        // advances): update the scrollbar via reloadData, NOT noteNumberOfRows-
        // Changed. On a table with 10^8 rows the latter is O(row-count delta) —
        // 250-400 ms when the estimate jumps by millions between polls, blocking
        // the main thread — whereas reloadData is O(viewport). Preserve the clip
        // origin so the viewport row does not visibly jump (rows are absolute at
        // row*rowHeight; ARCH criterion 5/6). reloadData on refinement is
        // explicitly sanctioned by the ARCH.
        let rows = numberOfRows(in: table)
        if rows != lastRowCount {
            lastRowCount = rows
            let origin = scroll.contentView.bounds.origin
            table.reloadData()
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // Data filled in (window paged) or highlights changed: redraw visibles.
        refreshVisibleRows()

        // A pending landing (jump / find / wrap / cancel restore): O(viewport).
        if let target = model.pendingScrollRow {
            model.pendingScrollRow = nil
            landOn(row: Int(min(target, UInt64(Int.max))))
        }
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

        // The row-number gutter may widen when bigger numbers scroll in.
        let gw = model.rowNumberColumnWidth()
        if abs(gw - gutterWidth) > 0.5 {
            gutterWidth = gw
            layoutContainer()
        }

        header.contentOffsetX = clip.bounds.origin.x
        header.needsDisplay = true
        gutter.needsDisplay = true

        ScrollProbe.note(clip.bounds.origin)        // inert unless LESSSHEET_LOG_OFFSET
        emitLayoutFramesIfEnabled()
    }

    // MARK: Row refresh (data / highlights)

    private func refreshVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { gutter.needsDisplay = true; return }
        for row in visible.location..<(visible.location + visible.length) {
            if let rv = table.rowView(atRow: row, makeIfNecessary: false) as? SheetRowView {
                configure(rv, row: row)
                rv.needsDisplay = true
            }
        }
        gutter.needsDisplay = true
    }

    private func configure(_ rv: SheetRowView, row: Int) {
        rv.controller = self
        if row < dataRowCount {
            rv.isFiller = false
            rv.cells = model.visibleBodyCells(forRow: row)
            rv.truncated = model.visibleBodyTruncated(forRow: row)
            rv.highlights = model.cellHighlights(forRow: row)
        } else {
            rv.isFiller = true
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

    override var isFlipped: Bool { true }
    override var isEmphasized: Bool { get { false } set {} }   // never draw selection emphasis
    override func drawSelection(in dirtyRect: NSRect) {}       // pure viewer

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let c = controller else { return }
        let h = bounds.height
        let grid = NSColor.gridColor
        let accent = NSColor.controlAccentColor
        var x: CGFloat = 0

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
        var x = -contentOffsetX

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
/// as chrome, not data; filler rows carry no number.
final class GridGutterView: NSView {
    weak var controller: NativeGridController?

    override var isFlipped: Bool { true }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
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
            }
        }
        // Right hairline separating the gutter from the data.
        grid.setFill()
        NSRect(x: w - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: bounds.height).fill()
    }
}

