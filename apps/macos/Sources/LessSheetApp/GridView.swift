import Contracts
import SwiftUI

// The LIVE chromeless spreadsheet grid is the NSTableView-backed engine in
// NativeGrid.swift (`GridView` -> `NativeGridRepresentable`): native row
// recycling makes every landing O(viewport). This file RETAINS the SwiftUI
// spreadsheet row (`SheetRow`) + its highlight type as the off-screen DUMP
// MIRROR — `ImageRenderer` can capture these where FrameDump composites the
// SwiftUI overlay/popup/find scenes over a grid (see FrameDump.DumpGrid /
// DumpEndGrid). The live grid ships its own AppKit cell drawing and its own
// cacheDisplay capture; the two share only the pinned geometry in `GridMetrics`.

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
    /// Find-highlight state per visible column (render order). Empty = none;
    /// header / filler rows never pass highlights (header cells are never
    /// matched).
    var highlights: [SheetCellHighlight] = []
    /// Per-cell display-truncation flags (ARCH req. 13/20), PARALLEL to
    /// `cells`; mirrors `RowWindow.truncated`. Empty = none (header/filler rows
    /// never carry a truncation flag, like `headerCells` in the contract).
    var truncated: [Bool] = []
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        HStack(spacing: 0) {
            gutterCell
                .zIndex(1)   // stays above the data cells that scroll under it
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                cellText(index < cells.count ? cells[index] : "")
                    .padding(.horizontal, GridMetrics.cellHPadding)
                    .frame(width: width, height: GridMetrics.rowHeight, alignment: .leading)
                    .background { highlightFill(at: index) }
                    .overlay { highlightBorder(at: index) }
                    .overlay(alignment: .trailing) { truncationMarker(at: index) }
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
        // The header is transparent in the live app so the Liquid Glass band
        // behind it shows through (data frosts through the glass); it falls back
        // to an opaque background only in headless dumps, where glass can't be
        // captured. Data/filler rows are always clear (over the grid fill).
        .background(isHeader && dumpChrome ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) { hairline.frame(height: 1) }   // hairline ON TOP of the glass
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
            // Data/filler gutter is opaque (occludes data scrolled horizontally
            // behind the pinned gutter); the HEADER corner is transparent live so
            // the glass band is continuous across the full header width.
            .background(isHeader && !dumpChrome ? Color.clear : Color(nsColor: .windowBackgroundColor))
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

    private func highlight(at index: Int) -> SheetCellHighlight {
        index < highlights.count ? highlights[index] : .none
    }

    /// Find highlight fill (semantic accent, legible in light/dark and over the
    /// glass band): a subtle wash on every matching visible cell, a stronger one
    /// on the current match.
    @ViewBuilder
    private func highlightFill(at index: Int) -> some View {
        switch highlight(at: index) {
        case .none: Color.clear
        case .subtle: Color.accentColor.opacity(0.20)
        case .strong: Color.accentColor.opacity(0.42)
        }
    }

    /// The current match gets a distinct accent border so it reads apart from
    /// the other (subtle) matches.
    @ViewBuilder
    private func highlightBorder(at index: Int) -> some View {
        if highlight(at: index) == .strong {
            Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5)
        }
    }

    /// A truncated cell's indicator (ARCH req. 13/20): a subtle dot inset from
    /// the column's trailing hairline, in addition to the tail-truncating "…"
    /// `cellText` already applies when the (possibly 4 KiB-capped) text
    /// overflows the column. Mirrors the live grid's `drawTruncationMarker` so
    /// the same cue is headlessly verifiable through `FrameDump`. Purely
    /// presentational: rendered exactly as the flag says, no re-measuring.
    @ViewBuilder
    private func truncationMarker(at index: Int) -> some View {
        if index < truncated.count, truncated[index] {
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.trailing, 3)
        }
    }
}

/// Per-cell find-highlight state (semantic, adaptive colors). Header cells are
/// never highlighted (they are never matched).
enum SheetCellHighlight: Equatable {
    case none
    /// A matching cell currently in the viewport.
    case subtle
    /// The current match (the strong, focused highlight).
    case strong
}

/// One cell's selection-overlay state (ARCH-select-copy AC1): whether it is
/// inside the live selection rect, and which of its FOUR sides sit on the
/// rect's OUTER boundary — an interior selected cell gets the accent fill
/// only (`isSelected`), a boundary cell ALSO gets a border stroke on the
/// matching side(s), so a multi-cell selection reads as one continuous
/// outlined range rather than a grid of individually-boxed cells. Mirrors
/// `SheetCellHighlight`'s role: precomputed OUTSIDE the draw loop (by
/// `DocumentModel.windowSelectionMarks`) so `SheetRowView.draw` stays a flat,
/// O(visible columns) per-frame read — never a per-cell model call.
struct SelectionMark: Equatable {
    var isSelected = false
    var borderTop = false
    var borderBottom = false
    var borderLeft = false
    var borderRight = false

    static let none = SelectionMark()
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
