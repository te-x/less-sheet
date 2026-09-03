import Contracts
import SwiftUI

// The LIVE grid is the AppKit engine in NativeGrid.swift. This file keeps the
// SwiftUI spreadsheet row as the off-screen DUMP MIRROR: `ImageRenderer` can
// capture it where the frame dump composites an overlay or popup scene over a
// grid, which it cannot do for the live table. The two share only the pinned
// geometry in `GridMetrics`.

/// One mirrored grid row: a fixed row-number cell, then fixed-width data cells,
/// each with their own hairlines — one full-width bottom line and per-column
/// right lines, never a full-height Canvas, which would allocate a backing store
/// the size of the whole document.
struct SheetRow: View {
    let rowNumber: Int?
    let rowNumberWidth: CGFloat
    let stickyRowNumber: Bool
    let cells: [String]
    let widths: [CGFloat]
    let fillerColumns: Int
    let isHeader: Bool
    /// Empty for header and filler rows, which are never matched.
    var highlights: [SheetCellHighlight] = []
    /// Per-cell truncation flags, parallel to `cells`.
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
        // The header is transparent live, so the glass band behind it shows
        // through; it falls back to opaque only in a dump, where glass cannot be
        // captured at all.
        .background(isHeader && dumpChrome ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) { hairline.frame(height: 1) }   // hairline ON TOP of the glass
    }

    /// The 1-based row number, or blank for the header corner and filler rows.
    /// Opaque, so data scrolling under it is occluded.
    private var gutterCell: some View {
        Text(rowNumber.map(String.init) ?? "")
            .font(.system(.body).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, GridMetrics.rowNumberHPadding)
            .frame(width: rowNumberWidth, height: GridMetrics.rowHeight, alignment: .trailing)
            // The header corner stays transparent live, so the glass band is
            // continuous across the full header width.
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

    /// A rounded, inset chip rather than a full-bleed painted cell. It shares the
    /// accent with the selection overlay, so the two are told apart by GEOMETRY:
    /// a match is an inset chip, a selection a full-cell wash inside a marquee.
    @ViewBuilder
    private func highlightFill(at index: Int) -> some View {
        switch highlight(at: index) {
        case .none: Color.clear
        case .subtle:
            RoundedRectangle(cornerRadius: FindHighlightStyle.cornerRadius)
                .fill(Color.accentColor.opacity(FindHighlightStyle.subtleAlpha))
                .padding(FindHighlightStyle.inset)
        case .strong:
            RoundedRectangle(cornerRadius: FindHighlightStyle.cornerRadius)
                .fill(Color.accentColor.opacity(FindHighlightStyle.strongAlpha))
                .padding(FindHighlightStyle.inset)
        }
    }

    /// A full-strength border, so the current match reads apart from the subtle
    /// ones.
    @ViewBuilder
    private func highlightBorder(at index: Int) -> some View {
        if highlight(at: index) == .strong {
            RoundedRectangle(cornerRadius: FindHighlightStyle.cornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: FindHighlightStyle.borderWidth)
                .padding(FindHighlightStyle.inset)
        }
    }

    /// Mirrors the live grid's own truncation marker, so the cue is verifiable in
    /// a dump. Distinct from the tail "…", which only means the text overflows
    /// the column.
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

/// Per-cell find-highlight state. Header cells are never highlighted.
enum SheetCellHighlight: Equatable {
    case none
    /// A matching cell currently in the viewport.
    case subtle
    /// The current match (the strong, focused highlight).
    case strong
}

/// Read by BOTH the live AppKit draw and the SwiftUI dump mirror, so the two
/// renderings cannot drift.
enum FindHighlightStyle {
    static let cornerRadius: CGFloat = 4
    /// The chip's inset from the cell bounds (clears the hairlines, so a chip
    /// reads as a highlight ON the cell rather than a repainted cell).
    static let inset: CGFloat = 1.5
    static let subtleAlpha: CGFloat = 0.18
    static let strongAlpha: CGFloat = 0.35
    static let borderWidth: CGFloat = 1.5
}

/// One cell's selection-overlay state: whether it is inside the selection, and
/// which of its four sides sit on the rect's OUTER boundary — so a multi-cell
/// selection reads as one continuous outline rather than a grid of boxed cells.
/// Precomputed outside the draw loop, so the row view's draw stays a flat
/// per-column read.
struct SelectionMark: Equatable {
    var isSelected = false
    var borderTop = false
    var borderBottom = false
    var borderLeft = false
    var borderRight = false
    /// The cursor cell. Set on exactly one visible cell when the active corner is
    /// on screen.
    var isActive = false

    static let none = SelectionMark()
}

/// Pins a view to the leading edge by counter-translating the horizontal
/// scroll. GPU-composited, so it never lags the scroll the way a state
/// round-trip would. Disabled for the dump grid, which has no scroll view.
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
