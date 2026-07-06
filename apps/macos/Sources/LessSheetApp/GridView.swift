import Contracts
import SwiftUI

// The chromeless spreadsheet grid: a single bidirectional ScrollView whose
// content is a LazyVStack of row views (rows are DIRECT children so only the
// viewport's rows are ever realized), a pinned sticky header that scrolls
// horizontally with its columns, frozen-from-head column widths, hidden-column
// reflow, and the spreadsheet fill (empty grid cells to both window edges).
// Vertical extent is the full row count, so the native scrollbar reflects the
// estimate and refines as the index completes; jumps drive `ScrollPosition`.

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
        let fillerColumns = fillerColumnCount(dataWidth: dataWidth)

        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    // Data rows — lazy direct children; only the viewport realizes.
                    ForEach(0..<model.displayRowCount, id: \.self) { row in
                        SheetRow(
                            cells: model.visibleBodyCells(forRow: row),
                            widths: widths,
                            fillerColumns: fillerColumns,
                            isHeader: false
                        )
                    }
                    // Bottom fill: empty grid rows to the window's lower edge
                    // (only when the whole document is shorter than the viewport).
                    let fillerRows = fillerRowCount
                    if fillerRows > 0 {
                        ForEach(0..<fillerRows, id: \.self) { _ in
                            SheetRow(
                                cells: [],
                                widths: widths,
                                fillerColumns: fillerColumns,
                                isHeader: false
                            )
                        }
                    }
                } header: {
                    SheetRow(
                        cells: model.headerLabels(),
                        widths: widths,
                        fillerColumns: fillerColumns,
                        isHeader: true
                    )
                }
            }
        }
        .scrollPosition($scrollPos)
        .onScrollGeometryChange(for: RowSpan.self) { geo in
            let h = GridMetrics.rowHeight
            let first = max(0, Int((geo.contentOffset.y - h) / h))   // minus the sticky header row
            let count = max(1, Int(ceil(geo.containerSize.height / h)) + 1)
            return RowSpan(first: first, count: count)
        } action: { _, span in
            model.viewportChanged(firstVisibleRow: span.first, visibleRowCount: span.count)
        }
        .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in
            viewportSize = size
        }
        .onChange(of: model.pendingScrollRow) { _, row in
            guard let row else { return }
            scrollPos.scrollTo(y: CGFloat(row) * GridMetrics.rowHeight)
            model.pendingScrollRow = nil
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Derived layout

    private func fillerColumnCount(dataWidth: CGFloat) -> Int {
        guard viewportSize.width > dataWidth else { return 0 }
        return Int(ceil((viewportSize.width - dataWidth) / GridMetrics.fillerColumnWidth))
    }

    private var fillerRowCount: Int {
        guard viewportSize.height > 0 else { return 0 }
        let contentRows = Double(model.displayRowCount) + 1 // + header
        let contentHeight = contentRows * Double(GridMetrics.rowHeight)
        guard Double(viewportSize.height) > contentHeight else { return 0 }
        return Int(ceil((Double(viewportSize.height) - contentHeight) / Double(GridMetrics.rowHeight)))
    }
}

/// One grid row: fixed-width cells with their own hairlines (a single
/// full-width bottom line and per-column right lines — never a full-height
/// Canvas). Data cells use tabular numerals; the header row is semibold on the
/// window background so it reads as pinned. Semantic colors only.
struct SheetRow: View {
    let cells: [String]
    let widths: [CGFloat]
    let fillerColumns: Int
    let isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
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
