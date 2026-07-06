import Contracts
import SwiftUI

// The chromeless spreadsheet grid: a single bidirectional ScrollView whose
// content is a LazyVStack of row views (rows are DIRECT children so only the
// viewport's rows are ever realized), a pinned sticky header that scrolls
// horizontally with its columns, a fixed leftmost row-number gutter that scrolls
// vertically with the rows but stays put under horizontal scroll, frozen-from-
// head column widths, hidden-column reflow, and the spreadsheet fill (empty grid
// cells to both window edges). Vertical extent is the full row count, so the
// native scrollbar reflects the estimate and refines as the index completes;
// jumps drive `ScrollPosition`.

struct GridView: View {
    @Bindable var model: DocumentModel

    @State private var scrollPos = ScrollPosition()
    @State private var viewportSize: CGSize = .zero

    /// Row window the viewport currently spans (drives core paging); Equatable
    /// so `onScrollGeometryChange` only fires when the visible rows change.
    private struct RowSpan: Equatable { let first: Int; let count: Int }

    var body: some View {
        let widths = model.visibleWidths()
        let dataWidth = widths.reduce(0, +)
        let gutterWidth = model.rowNumberColumnWidth()
        let fillerColumns = fillerColumnCount(dataWidth: dataWidth, gutterWidth: gutterWidth)
        let rowWidth = gutterWidth + dataWidth + CGFloat(fillerColumns) * GridMetrics.fillerColumnWidth
        let rowH = GridMetrics.rowHeight

        // Window-anchored virtualization (item 1). A file can hold 100M+ rows;
        // instantiating a child per row (`ForEach(0..<rowCount)`) makes a
        // programmatic `scrollTo` a far offset resolve a scroll position inside
        // a giant ForEach — a multi-million-row main-thread relayout that
        // beach-balls the UI, and re-diffs on every estimate refresh. Instead we
        // render ONLY the materialized band (the core window = viewport + scroll
        // buffer) as lazy DIRECT children and reserve the rows above/below it
        // with two O(1) spacer views. Total content height still equals the full
        // (estimated) row count, so the native scrollbar and every absolute row
        // position are unchanged — but layout is O(viewport) and a jump is O(1).
        let total = max(0, model.displayRowCount)
        let bandStart = min(Int(model.window.firstRow), total)
        let bandCount = max(0, min(model.window.rows.count, total - bandStart))
        let bandEnd = bandStart + bandCount
        let atEnd = bandEnd == total
        let belowRows = belowFillRowCount(total: total)
        let topSpacer = CGFloat(bandStart) * rowH
        // Keep total content height constant regardless of band position: the
        // below-band area is (data rows below the band) + the empty fill strip.
        // Only when the band reaches the last data row do we render that fill as
        // real grid rows (so the spreadsheet fill / end-of-file overscroll keep
        // their per-row hairlines); otherwise it is off-screen and a blank
        // spacer of the identical height suffices.
        let bottomSpacer = atEnd ? 0 : CGFloat(total - bandEnd + belowRows) * rowH

        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if topSpacer > 0 {
                        Color.clear.frame(width: rowWidth, height: topSpacer)
                    }
                    // Band data rows — lazy DIRECT children (only the viewport's
                    // rows realize), each with its own per-row hairlines.
                    ForEach(bandStart..<bandEnd, id: \.self) { row in
                        SheetRow(
                            rowNumber: row + 1,          // 1-based, matches jump numbering
                            rowNumberWidth: gutterWidth,
                            stickyRowNumber: true,
                            cells: model.visibleBodyCells(forRow: row),
                            widths: widths,
                            fillerColumns: fillerColumns,
                            isHeader: false
                        )
                    }
                    // End-of-file fill: rendered as grid rows only once the band
                    // reaches the last data row. Empty grid rows — never data.
                    if atEnd && belowRows > 0 {
                        ForEach(0..<belowRows, id: \.self) { _ in
                            SheetRow(
                                rowNumber: nil,          // filler rows carry no number
                                rowNumberWidth: gutterWidth,
                                stickyRowNumber: true,
                                cells: [],
                                widths: widths,
                                fillerColumns: fillerColumns,
                                isHeader: false
                            )
                        }
                    }
                    if bottomSpacer > 0 {
                        Color.clear.frame(width: rowWidth, height: bottomSpacer)
                    }
                } header: {
                    SheetRow(
                        rowNumber: nil,                  // the corner cell above the gutter
                        rowNumberWidth: gutterWidth,
                        stickyRowNumber: true,
                        cells: model.headerLabels(),
                        widths: widths,
                        fillerColumns: fillerColumns,
                        isHeader: true
                    )
                }
            }
        }
        .scrollPosition($scrollPos)
        // Item 2: rest the initial content offset at the top-left corner (not a
        // drifted/elastic position), so the grid opens at exactly (0,0) with the
        // row-number gutter fully visible. Scoped to the initial offset only —
        // user scrolling and size-change anchoring are untouched.
        .defaultScrollAnchor(.topLeading, for: .initialOffset)
        .onScrollGeometryChange(for: RowSpan.self) { geo in
            let first = max(0, Int((geo.contentOffset.y - rowH) / rowH))   // minus the sticky header row
            let count = max(1, Int(ceil(geo.containerSize.height / rowH)) + 1)
            return RowSpan(first: first, count: count)
        } action: { _, span in
            model.viewportChanged(firstVisibleRow: span.first, visibleRowCount: span.count)
        }
        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in
            viewportSize = size
        }
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, offset in
            ScrollProbe.note(offset)      // inert unless LESSSHEET_LOG_OFFSET is set
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, top in
            // Item 1: the top content inset equals the title-bar safe area, so
            // row 1 rests fully below the title-bar region at (0,0) while
            // scrolled content still travels under it (native chrome). Logged
            // for headless verification; inert unless LESSSHEET_LOG_OFFSET is set.
            ScrollProbe.noteInsets(top: top, label: "contentInset")
        }
        .onChange(of: model.pendingScrollRow) { _, row in
            guard let row else { return }
            scrollPos.scrollTo(y: CGFloat(row) * rowH)
            model.pendingScrollRow = nil
        }
        .onChange(of: model.openGeneration, initial: true) { _, _ in
            // Item 2: every open (and dialect re-open) starts at the exact
            // origin — top-left, gutter fully visible — never scrolled right.
            scrollPos.scrollTo(point: .zero)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Derived layout

    private func fillerColumnCount(dataWidth: CGFloat, gutterWidth: CGFloat) -> Int {
        let available = viewportSize.width - gutterWidth
        guard available > dataWidth else { return 0 }
        return Int(ceil((available - dataWidth) / GridMetrics.fillerColumnWidth))
    }

    /// Empty grid rows kept below the last data row: the end-of-file overscroll
    /// strip (so the last rows clear the floating controls), extended to fill
    /// the viewport when the document is shorter than it. Pure fill — never
    /// counted as data (row count / scrollbar estimate use displayRowCount).
    private func belowFillRowCount(total: Int) -> Int {
        guard viewportSize.height > 0 else { return GridMetrics.overscrollRows }
        let rowH = Double(GridMetrics.rowHeight)
        let dataHeight = (Double(total) + 1) * rowH   // header + data rows
        let overscroll = Double(GridMetrics.overscrollRows) * rowH
        let extra = max(overscroll, Double(viewportSize.height) - dataHeight)
        return max(GridMetrics.overscrollRows, Int(ceil(extra / rowH)))
    }
}

/// One grid row: a fixed leftmost row-number cell, then fixed-width data cells,
/// each with their own hairlines (a single full-width bottom line and per-column
/// right lines — never a full-height Canvas). Data cells use tabular numerals;
/// the header row is semibold on the window background so it reads as pinned. The
/// row-number gutter uses secondary text on the window background so it reads as
/// chrome, not data, and (in the live grid) counter-translates the horizontal
/// scroll so it stays pinned to the left edge. Semantic colors only.
struct SheetRow: View {
    let rowNumber: Int?
    let rowNumberWidth: CGFloat
    let stickyRowNumber: Bool
    let cells: [String]
    let widths: [CGFloat]
    let fillerColumns: Int
    let isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
            gutterCell
                .zIndex(1)   // stays above the data cells that scroll under it
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                cellText(index < cells.count ? cells[index] : "")
                    .padding(.horizontal, GridMetrics.cellHPadding)
                    .frame(width: width, height: GridMetrics.rowHeight, alignment: .leading)
                    .overlay(alignment: .trailing) { hairline.frame(width: 1) }
            }
            if fillerColumns > 0 {
                ForEach(0..<fillerColumns, id: \.self) { _ in
                    Color.clear
                        .frame(width: GridMetrics.fillerColumnWidth, height: GridMetrics.rowHeight)
                        .overlay(alignment: .trailing) { hairline.frame(width: 1) }
                }
            }
        }
        .frame(height: GridMetrics.rowHeight)
        .background(isHeader ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) { hairline.frame(height: 1) }
    }

    /// The leftmost fixed cell: the 1-based row number (right-aligned, faded), or
    /// blank for the header corner and filler rows. Opaque so data scrolling
    /// under it is occluded; pinned to the left edge under horizontal scroll.
    private var gutterCell: some View {
        Text(rowNumber.map(String.init) ?? "")
            .font(.system(.body).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, GridMetrics.rowNumberHPadding)
            .frame(width: rowNumberWidth, height: GridMetrics.rowHeight, alignment: .trailing)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .trailing) { hairline.frame(width: 1) }
            .modifier(StickyLeading(enabled: stickyRowNumber))
            .accessibilityHidden(true)
    }

    private func cellText(_ text: String) -> some View {
        Text(text)
            .font(.system(.body).monospacedDigit())
            .fontWeight(isHeader ? .semibold : .regular)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
    }

    private var hairline: some View { Rectangle().fill(Color(nsColor: .gridColor)) }
}

/// Pins a view to the leading edge of its enclosing ScrollView by counter-
/// translating the horizontal scroll (GPU-composited via `visualEffect`, so it
/// never lags the scroll the way a state round-trip would). Disabled for the
/// eager dump grid, which has no ScrollView to read.
private struct StickyLeading: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.visualEffect { effect, proxy in
                let minX = proxy.frame(in: .scrollView).minX
                return effect.offset(x: max(0, -minX))
            }
        } else {
            content
        }
    }
}
