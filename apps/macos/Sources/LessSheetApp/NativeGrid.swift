import AppKit
import Contracts
import SwiftUI

// The live chromeless spreadsheet grid, on `NSTableView` for native row
// recycling: a landing is a window materialize plus a clip scroll, so it costs
// O(viewport) whatever the distance. It ships as an `NSViewRepresentable` inside
// the SwiftUI shell and reads the same `DocumentModel`; `GridView.body` touches
// the model facts that must drive AppKit, so `updateNSView` re-syncs on each.
//
// Layout, window-space and y-down (pinned by LESSSHEET_LOG_LAYOUT):
//   band   y[0,54]   the glass header band, EXPLICITLY drawn — never emergent
//                    titlebar/scroll-edge compositing, which does not survive
//                    a chromeless window.
//   header y[32,54]  the sticky column header, scrolling horizontally with its
//                    columns and transparent so data frosts through the band.
//   row1   y[54,76]  the first data row. Rows recycle below.
//   scrollview minY 0  the scroll view fills the window from its top edge, so
//                    content scrolls up UNDER the band.
// The row-number gutter is a fixed left strip that also fills the full window
// height and sits BEHIND the band, so numbers frost under it exactly like the
// data and row 0's number shares row 0's baseline.

// MARK: - Grid geometry

enum NativeGrid {
    static let rowHeight = GridMetrics.rowHeight            // 22
    static let headerHeight = GridMetrics.rowHeight         // 22
    static let bandHeight = GridMetrics.titleBarInset + GridMetrics.rowHeight  // 54
    /// The scroll view's top content inset: content rests below the band, so
    /// row 0 sits at window-y 54, while scrolled rows still travel up under it.
    static let contentInsetTop = GridMetrics.titleBarInset + GridMetrics.rowHeight  // 54
    static let hairline: CGFloat = 1
}

/// The visible-window identity a scroll-driven column fit acts on: the clamped
/// top data row, the visible row count, and the horizontal clip.
struct GridFitViewport {
    let top: Int
    let length: Int
    let offsetX: CGFloat
    let width: CGFloat
}

// MARK: - SwiftUI seam

/// The grid as the SwiftUI shell sees it: a thin wrapper over the AppKit engine.
struct GridView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        // Reading these here is what makes this body — and so `updateNSView` —
        // re-run when they change. It is the bridge from an @Observable mutation
        // to the coordinator.
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

/// Fills the SwiftUI frame, which extends under the transparent title bar, so
/// the scroll view's top edge is the window's top edge.
final class GridContainerView: NSView {
    weak var controller: NativeGridController?
    override var isFlipped: Bool { false }
    override func layout() {
        super.layout()
        controller?.layoutContainer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A landing can arrive between `makeNSView` and entering a window.
        // Re-apply now that AppKit has usable geometry, rather than waiting for
        // an unrelated model change.
        if window != nil { controller?.apply() }
    }
}

// MARK: - Controller (data source + delegate + model bridge)

@MainActor
final class NativeGridController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// The live controller, so a model mutation from another window can poke a
    /// repaint and the frame dump can capture the REAL table. Weak: the view tree
    /// owns it.
    static weak var live: NativeGridController?

    let model: DocumentModel

    let container = GridContainerView()
    let scroll = NSScrollView()
    let table = SheetTableView()
    let header = GridHeaderView()
    let gutter = GridGutterView()
    let band = NSGlassEffectView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cells"))

    // Layout state mirrored from the model, read by the row/header/gutter draw.
    // These cover the CURRENT HORIZONTAL COLUMN WINDOW only — tens to hundreds
    // of columns, never all of them — positioned from `columnFirstX`, the
    // window's exact prefix-sum offset, so an in-window column lands at the same
    // x a full unwindowed draw would give it.
    var widths: [CGFloat] = []
    var headerLabels: [String] = []
    var headerTruncated: [Bool] = []
    var columnAlignments: [ColumnTextAlignment] = []
    /// Absolute indices parallel to `widths`: position `i` here is the same
    /// absolute column `widths[i]` is the width of.
    var absoluteColumns: [Int] = []
    var columnFirstX: CGFloat = 0
    var fillerColumns = 0
    var gutterWidth: CGFloat = 0
    /// Every VISIBLE column's width summed, independent of the column window;
    /// drives the scrollable column width and the filler count. Refreshed only on
    /// a structural change, never per scroll tick.
    var totalDataWidth: CGFloat = 0

    // Change-detection caches (avoid redundant reloads).
    var lastOpenGeneration = -1
    var lastRowCount = -1
    var lastVisibleColumns: [Int] = []
    var lastColumnWidths: [CGFloat] = []
    var lastColumnPresentationRevision = -1
    var lastColumnWidthRevision = -1
    var lastColumnConfigurationRevision = -1
    // Read-only seams for the headless repaint probes: what the controller has
    // actually APPLIED, so a probe can check that a mutation drove a repaint
    // itself rather than deferring to the next event — without calling apply().
    var appliedColumnConfigurationRevision: Int { lastColumnConfigurationRevision }
    var appliedFilterState: Bool { lastIsFiltered }
    /// Increments each time `apply()` runs its repaint body past the built guard.
    var applyTick = 0
    var lastIsFiltered = false
    var built = false
    var landingApplyScheduled = false
    var pendingCellToggle: GridCell?
    /// The visible-window identity the last scroll-driven column fit acted on.
    /// The row paging, the column window and the table width are a pure function
    /// of exactly these, so a clip tick that leaves all four unchanged — an
    /// elastic bounce whose whole travel is past a hard edge — must NOT
    /// re-derive them: that re-derivation is the only thing that can churn an
    /// established column width. Reset on a re-open, so a new document re-fits.
    var lastFitViewport: GridFitViewport?
    /// Re-entrancy guard for the stranded-viewport re-anchor's own
    /// `clip.scroll(to:)`, which can synchronously re-enter the bounds-changed
    /// path. AppKit is not documented to skip a same-value set, so relying on
    /// "the origin no longer needs correcting" would be unproven; this makes the
    /// recursion bounded regardless.
    var reanchoring = false

    init(model: DocumentModel) {
        self.model = model
        super.init()
        model.viewportLandingHandler = { [weak self] _ in self?.scheduleLandingApply() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The data rows the file exposes — the estimate the scrollbar reflects,
    /// refining toward exact. Filler rows extend below it.
    var dataRowCount: Int { max(0, model.displayRowCount) }
}

extension NativeGridController {
    // MARK: Fixed-strip layout (gutter | data)

    func layoutContainer() {
        let containerBounds = container.bounds
        guard containerBounds.width > 0, containerBounds.height > 0 else { return }
        let gutterStripWidth = gutterWidth
        // Right of the fixed gutter strip, and the full window height so it
        // extends under the band; the top inset rests row 0 below it.
        scroll.frame = NSRect(x: gutterStripWidth, y: 0,
                              width: max(0, containerBounds.width - gutterStripWidth),
                              height: containerBounds.height)
        band.frame = NSRect(x: 0, y: containerBounds.height - NativeGrid.bandHeight,
                            width: containerBounds.width, height: NativeGrid.bandHeight)
        // The bottom of the band, aligned with the data columns.
        header.frame = NSRect(x: gutterStripWidth, y: containerBounds.height - NativeGrid.bandHeight,
                              width: max(0, containerBounds.width - gutterStripWidth),
                              height: NativeGrid.headerHeight)
        // Full window height, like the scroll view, so row numbers scroll up
        // under the band instead of stopping at its bottom edge. The z-order does
        // the frosting; this frame just gives the gutter room to draw into.
        gutter.frame = NSRect(x: 0, y: 0, width: gutterStripWidth, height: containerBounds.height)
        header.contentOffsetX = scroll.contentView.bounds.origin.x
        // Re-derive the column window BEFORE sizing the table column, so a width
        // grown by newly revealed columns lands in this same layout pass.
        refreshColumnWindow()
        refreshColumnWidth()
        header.needsDisplay = true
        gutter.needsDisplay = true
        emitLayoutFramesIfEnabled()
    }

    /// The single table column's width: exactly the viewport when the data fits
    /// inside it, the data width only when it genuinely overflows — the sole case
    /// that warrants a horizontal scroller. The filler columns are a drawing
    /// device, not extra width. Reads `totalDataWidth` rather than summing
    /// `widths`, which is only the column window and far narrower than the true
    /// scrollable extent. `site` labels the probe line with the caller.
    func refreshColumnWidth(site: String = "layout") {
        let dataWidth = totalDataWidth
        let viewportW = scroll.contentView.bounds.width
        fillerColumns = viewportW > dataWidth
            ? Int(ceil((viewportW - dataWidth) / GridMetrics.fillerColumnWidth)) : 0
        // Fill to the viewport, never past it: rounding the filler count up and
        // then adding its full width would leave a permanent sliver of horizontal
        // overscroll, i.e. a spurious scroller for a few short columns. The filler
        // hairlines still reach the edge — only the column's own width is clamped.
        let target = max(dataWidth, viewportW)
        if abs(column.width - target) > 0.5 { column.width = target }
        ColWidthProbe.log(.init(
            site: site, total: dataWidth, viewport: viewportW, scrollFrame: scroll.frame.width,
            documentWidth: table.frame.width, columnWidth: column.width, filler: fillerColumns,
            hScrollerHidden: scroll.horizontalScroller?.isHidden ?? true
        ))
    }

}
