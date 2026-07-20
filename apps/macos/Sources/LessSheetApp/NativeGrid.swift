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

enum NativeGrid {
    static let rowHeight = GridMetrics.rowHeight            // 22
    static let headerHeight = GridMetrics.rowHeight         // 22
    static let bandHeight = GridMetrics.titleBarInset + GridMetrics.rowHeight  // 54
    /// The scroll view's top content inset: content rests below the band, so
    /// row 0 sits at window-y 54, while scrolled rows still travel up under it.
    static let contentInsetTop = GridMetrics.titleBarInset + GridMetrics.rowHeight  // 54
    static let hairline: CGFloat = 1
}

/// The visible-window identity the last scroll-driven column fit acted on:
/// the clamped top data row, the visible row count, and the horizontal clip
/// (x offset + width). Bundles the four members into a named type so the
/// stored property stays within the large_tuple bound.
struct GridFitViewport {
    let top: Int
    let length: Int
    let offsetX: CGFloat
    let width: CGFloat
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
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cells"))

    // Layout state mirrored from the model (read by the row/header/gutter draw).
    // `widths`/`headerLabels` are the CURRENT HORIZONTAL COLUMN WINDOW only —
    // a few tens to a few hundred columns, never all of them on a wide
    // document (ARCH-column-windowing) — positioned starting at `columnFirstX`
    // (the window's exact prefix-sum x-offset, so an in-window column lands at
    // the SAME x a full, unwindowed draw would give it; ARCH AC4/AC5).
    var widths: [CGFloat] = []
    var headerLabels: [String] = []
    var headerTruncated: [Bool] = []
    var columnAlignments: [ColumnTextAlignment] = []
    /// Absolute column indices PARALLEL to `widths`/`headerLabels` (ARCH-
    /// select-copy): the click→cell mapping's column half — position `i`
    /// here is the SAME absolute column `widths[i]` is the width of.
    var absoluteColumns: [Int] = []
    var columnFirstX: CGFloat = 0
    var fillerColumns = 0
    var gutterWidth: CGFloat = 0
    /// Sum of every VISIBLE column's width (`model.totalVisibleWidth`) —
    /// independent of the column window — driving the scrollable table
    /// column's width / filler-column count (`refreshColumnWidth`). O(visible
    /// columns) to derive; refreshed only on a STRUCTURAL change
    /// (`refreshLayoutMetrics`), never per scroll tick.
    var totalDataWidth: CGFloat = 0

    // Change-detection caches (avoid redundant reloads).
    var lastOpenGeneration = -1
    var lastRowCount = -1
    var lastVisibleColumns: [Int] = []
    var lastColumnWidths: [CGFloat] = []
    var lastColumnPresentationRevision = -1
    var lastColumnWidthRevision = -1
    var lastColumnConfigurationRevision = -1
    /// Verification-only, read-only accessor (config-repaint probe): the column-
    /// configuration revision the controller has actually APPLIED. Lets a headless
    /// probe compare the applied revision against the model's current one WITHOUT
    /// calling apply() itself.
    var appliedColumnConfigurationRevision: Int { lastColumnConfigurationRevision }
    /// The filtered/identity view state the controller has actually APPLIED (its
    /// last-seen `model.isFiltered`). Lets a headless probe confirm a filter
    /// toggle repainted the grid WITHOUT the probe calling apply() itself — the
    /// FilterRepaintProbe regression seam, mirroring
    /// `appliedColumnConfigurationRevision`.
    var appliedFilterState: Bool { lastIsFiltered }
    /// Increments each time `apply()` actually runs its repaint body (past the
    /// built/window guard). A probe reads the DELTA across a single synchronous
    /// model mutation to prove that mutation drove a repaint itself (a poke)
    /// rather than deferring to the next event — the audit seam for the
    /// repaint-family bugs.
    var applyTick = 0
    var lastIsFiltered = false
    var built = false
    var landingApplyScheduled = false
    var pendingCellToggle: GridCell?
    /// The visible-window identity the last scroll-driven column fit acted on:
    /// the clamped top data row, the visible row count, and the horizontal clip
    /// (x offset + width). The row-window paging, the horizontal column window,
    /// and the table/filler width are a pure function of exactly these — so a
    /// clip-bounds tick that leaves all four unchanged (a top/bottom elastic
    /// bounce that cannot move the viewport, say) must NOT re-derive them:
    /// re-deriving is the only thing that could churn an established column
    /// width (the "columns resize on first interaction" bug). `nil` until the
    /// first tick, and reset on a re-open so the new document always re-fits.
    var lastFitViewport: GridFitViewport?
    /// Re-entrancy guard for `reanchorIfStrandedPastNewEnd`'s own
    /// `clip.scroll(to:)` call, which can synchronously re-enter
    /// `clipBoundsChanged` -> `syncRowCountEstimate` (AppKit's bounds-changed
    /// notification is not documented to skip a same-value set, so relying on
    /// "the origin no longer needs correcting" to stop a recursion would be
    /// unproven). The flag makes the recursion provably bounded regardless: a
    /// re-entrant call always finds `reanchoring` true and returns before
    /// touching the clip again — any further work the re-entrant call does is
    /// merely redundant (idempotent reload/restore), never unbounded.
    var reanchoring = false

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
}

extension NativeGridController {
    // MARK: Fixed-strip layout (gutter | data)

    func layoutContainer() {
        let containerBounds = container.bounds
        guard containerBounds.width > 0, containerBounds.height > 0 else { return }
        let gutterStripWidth = gutterWidth
        // Data scroll view sits to the RIGHT of the fixed gutter strip and fills
        // the full window height (so it extends under the band; the top inset
        // rests row 0 below it).
        scroll.frame = NSRect(x: gutterStripWidth, y: 0,
                              width: max(0, containerBounds.width - gutterStripWidth),
                              height: containerBounds.height)
        // Band: the full-width top strip (window top -> header bottom).
        band.frame = NSRect(x: 0, y: containerBounds.height - NativeGrid.bandHeight,
                            width: containerBounds.width, height: NativeGrid.bandHeight)
        // Header: the bottom 22 pt of the band, aligned with the data columns.
        header.frame = NSRect(x: gutterStripWidth, y: containerBounds.height - NativeGrid.bandHeight,
                              width: max(0, containerBounds.width - gutterStripWidth),
                              height: NativeGrid.headerHeight)
        // Gutter: the fixed left strip, FULL window height (like the scroll
        // view) so its row numbers scroll up under the band and frost through
        // it exactly like the data, instead of stopping dead at the band's
        // bottom edge. z-order (behind the band, above the scroll) does the
        // actual frosting; the frame just gives it the room to draw into.
        gutter.frame = NSRect(x: 0, y: 0, width: gutterStripWidth, height: containerBounds.height)
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
    func refreshColumnWidth(site: String = "layout") {
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
        ColWidthProbe.log(.init(
            site: site, total: dataWidth, viewport: viewportW, scrollFrame: scroll.frame.width,
            documentWidth: table.frame.width, columnWidth: column.width, filler: fillerColumns,
            hScrollerHidden: scroll.horizontalScroller?.isHidden ?? true
        ))
    }

}
