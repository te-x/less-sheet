// The custom-drawn spreadsheet row view (cells, hairlines, highlights).
import AppKit
import Contracts
import SwiftUI

// MARK: - Row view (custom-drawn cells + hairlines + highlights)

/// The three semantic colors a row's cells paint with, resolved once per `draw`
/// and threaded through the per-column helpers (keeps their parameter lists small).
private struct RowPalette {
    let accent: NSColor
    let selection: NSColor
    let grid: NSColor
}

/// One data or filler row: every visible-column cell, its trailing hairline, the
/// filler hairlines out to the right edge, and a full-width bottom hairline —
/// the spreadsheet fill, one recycled view per row.
final class SheetRowView: NSTableRowView {
    weak var controller: NativeGridController?
    var cells: [String] = []
    /// Display-only warning states parallel to `cells`. They never alter the raw
    /// values copy, find and filter see.
    var formatUnavailable: [Bool] = []
    var conflicts: [Bool] = []
    var accessibilityWarnings: [Int: String] = [:]
    /// The core's per-cell truncation flags, rendered as given and never
    /// re-derived from measured text.
    var truncated: [Bool] = []
    var highlights: [SheetCellHighlight] = []
    /// Precomputed by the model, never derived here, so `draw` stays a flat
    /// per-column read.
    var selectionMarks: [SelectionMark] = []
    var isFiller = false
    /// A row inside the estimated range but not yet servable, as opposed to a
    /// genuinely empty one. `cells` is empty-padded identically for both, so this
    /// is the ONLY thing that separates "still loading" from "loaded and blank".
    /// Always false past EOF, which is not a loading state.
    var pending = false

    override var isFlipped: Bool { true }
    override var isEmphasized: Bool { get { false } set {} }   // never draw selection emphasis
    override func drawSelection(in dirtyRect: NSRect) {}       // pure viewer

    // Fully monospaced, so the content reads like the raw file and columns line
    // up. MUST match the width-measurement font in the model, or columns would be
    // sized for the wrong glyphs.
    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        // The launch measurement's ground truth: the first REAL data row to
        // paint. All three conditions are load-bearing, and `pending` is the easy
        // one to get wrong — a not-yet-servable row is populated and draws a
        // LOADING PLACEHOLDER, so without it this could stamp "rows are on
        // screen" for a grid showing none. That cannot happen at launch today,
        // but an instrument that is only accidentally correct reports the wrong
        // number the moment it changes.
        if !isFiller, !pending, !cells.isEmpty { LaunchTiming.phaseOnce("first_row_pixels") }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let controller else { return }
        let height = bounds.height
        let grid = NSColor.gridColor
        let accent = NSColor.controlAccentColor
        // Selection is a MUTED GRAY marquee, deliberately quieter than the
        // accent, so a selected cell and a find highlight stay distinct by both
        // colour and geometry. This one colour drives both the wash and the
        // marquee.
        let palette = RowPalette(accent: accent, selection: NSColor.systemGray, grid: grid)
        // `widths` is only the current column WINDOW, so start at its exact
        // prefix-sum offset: an in-window column then lands at the same x a full
        // unwindowed draw would give it.
        var cursorX: CGFloat = controller.columnFirstX

        for (columnIndex, width) in controller.widths.enumerated() {
            let cell = NSRect(x: cursorX, y: 0, width: width, height: height)
            cursorX += width
            guard cell.intersects(dirtyRect) else { continue }
            drawColumn(columnIndex, in: cell, controller: controller, palette: palette)
        }
        grid.setFill()
        for _ in 0..<controller.fillerColumns {
            cursorX += GridMetrics.fillerColumnWidth
            let line = NSRect(x: cursorX - NativeGrid.hairline, y: 0, width: NativeGrid.hairline, height: height)
            if line.intersects(dirtyRect) { line.fill() }
        }
        // Full-width bottom hairline (data -> filler seam is continuous).
        NSRect(x: dirtyRect.minX, y: height - NativeGrid.hairline,
               width: dirtyRect.width, height: NativeGrid.hairline).fill()
    }

    /// One cell, layered: find-highlight background, selection wash, text or
    /// placeholder plus warning markers, current-match border, selection marquee,
    /// trailing hairline. A cell can be both matched and selected.
    private func drawColumn(_ index: Int, in cell: NSRect, controller: NativeGridController,
                            palette: RowPalette) {
        let highlight = index < highlights.count ? highlights[index] : .none
        SheetRowView.drawHighlightBackground(highlight, in: cell, accent: palette.accent)
        // Layered on top of a find highlight, never instead of it.
        let mark = index < selectionMarks.count ? selectionMarks[index] : .none
        if mark.isSelected {
            palette.selection.withAlphaComponent(0.12).setFill()
            cell.fill()
        }
        drawCellContent(index, in: cell, controller: controller)
        if highlight == .strong {
            palette.accent.setStroke()
            let chipPath = SheetRowView.highlightChipPath(in: cell)
            chipPath.lineWidth = FindHighlightStyle.borderWidth
            chipPath.stroke()
        }
        if mark.isSelected {
            SheetRowView.drawSelectionBorder(mark, in: cell, color: palette.selection)
        }
        if mark.isActive {
            SheetRowView.drawActiveOutline(in: cell, color: palette.accent)
        }
        palette.grid.setFill()
        NSRect(x: cell.maxX - NativeGrid.hairline, y: 0,
               width: NativeGrid.hairline, height: cell.height).fill()
    }

    /// Accent, rounded and inset — distinct from a selected cell by both colour
    /// and geometry.
    static func drawHighlightBackground(_ highlight: SheetCellHighlight, in cell: NSRect, accent: NSColor) {
        switch highlight {
        case .subtle:
            accent.withAlphaComponent(FindHighlightStyle.subtleAlpha).setFill()
            highlightChipPath(in: cell).fill()
        case .strong:
            accent.withAlphaComponent(FindHighlightStyle.strongAlpha).setFill()
            highlightChipPath(in: cell).fill()
        case .none:
            break
        }
    }

    /// The cell's text, or the loading placeholder for a not-yet-servable empty
    /// one, then any warning markers.
    private func drawCellContent(_ index: Int, in cell: NSRect, controller: NativeGridController) {
        if index < cells.count, !cells[index].isEmpty {
            SheetRowView.drawText(cells[index], in: cell.insetBy(dx: GridMetrics.cellHPadding, dy: 0),
                                  font: SheetRowView.font, color: .labelColor,
                                  alignment: textAlignment(index, controller: controller))
        } else if pending {
            SheetRowView.drawPendingPlaceholder(in: cell)
        }
        drawWarningMarkers(index, in: cell)
    }

    /// Defaults to leading.
    private func textAlignment(_ index: Int, controller: NativeGridController) -> NSTextAlignment {
        switch index < controller.columnAlignments.count ? controller.columnAlignments[index] : .leading {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    /// The three warning glyphs; the conflict one shifts left of a present
    /// format glyph.
    private func drawWarningMarkers(_ index: Int, in cell: NSRect) {
        if index < truncated.count, truncated[index] {
            SheetRowView.drawTruncationMarker(in: cell)
        }
        if index < formatUnavailable.count, formatUnavailable[index] {
            SheetRowView.drawStatusMarker(symbol: "number.circle", description: "Format unavailable",
                                          in: cell, trailingSlot: 0)
        }
        if index < conflicts.count, conflicts[index] {
            let hasFormatMarker = formatUnavailable.indices.contains(index) && formatUnavailable[index]
            SheetRowView.drawStatusMarker(symbol: "exclamationmark.triangle", description: "Type conflict",
                                          in: cell, trailingSlot: hasFormatMarker ? 1 : 0)
        }
    }

    /// A subtle dot inset from the trailing hairline. The tail "…" already means
    /// "wider than the column"; this is the separate cue that the CORE cut the
    /// underlying data at its display cap.
    static func drawTruncationMarker(in cell: NSRect) {
        let diameter: CGFloat = 5
        let margin: CGFloat = 3   // clearance from the column's trailing hairline
        let dot = NSRect(x: cell.maxX - margin - diameter, y: (cell.height - diameter) / 2,
                         width: diameter, height: diameter)
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// A glyph, not a colour alone, so the warning survives colour blindness.
    static func drawStatusMarker(symbol: String, description: String, in cell: NSRect, trailingSlot: Int) {
        guard cell.width >= 22,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else { return }
        image.isTemplate = true
        let size: CGFloat = 12
        let iconX = cell.maxX - 10 - size - CGFloat(trailingSlot) * (size + 3)
        image.draw(in: NSRect(x: iconX, y: cell.midY - size / 2, width: size, height: size),
                   from: .zero, operation: .sourceOver, fraction: 0.75,
                   respectFlipped: true, hints: nil)
    }

    /// The ONE chip geometry both fills and the current-match border use.
    static func highlightChipPath(in cell: NSRect) -> NSBezierPath {
        NSBezierPath(
            roundedRect: cell.insetBy(dx: FindHighlightStyle.inset, dy: FindHighlightStyle.inset),
            xRadius: FindHighlightStyle.cornerRadius, yRadius: FindHighlightStyle.cornerRadius
        )
    }

    /// Strokes only the sides of `cell` that sit on the selection's OUTER edge,
    /// so a multi-cell selection reads as one continuous outline rather than a
    /// grid of boxed cells. Square caps, so the per-cell segments join seamlessly
    /// at the corners.
    static func drawSelectionBorder(_ mark: SelectionMark, in cell: NSRect, color: NSColor) {
        color.setStroke()
        let rect = cell.insetBy(dx: 1.0, dy: 1.0)
        let path = NSBezierPath()
        path.lineWidth = 2.0
        path.lineCapStyle = .square
        if mark.borderTop {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY)); path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        if mark.borderBottom {
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY)); path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        if mark.borderLeft {
            path.move(to: NSPoint(x: rect.minX, y: rect.minY)); path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        if mark.borderRight {
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY)); path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        path.stroke()
    }

    /// The active corner's focus outline, stroked atop the marquee. Its inset
    /// matches the marquee's, so on a bare 1×1 cursor the two coincide; drawing
    /// all four sides is what distinguishes it from the marquee's outer-edge
    /// segments and from the rounded find chips.
    static let activeOutlineWidth: CGFloat = 2
    static let activeOutlineInset: CGFloat = 1
    static func drawActiveOutline(in cell: NSRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(rect: cell.insetBy(dx: activeOutlineInset, dy: activeOutlineInset))
        path.lineWidth = activeOutlineWidth
        path.lineJoinStyle = .miter
        path.stroke()
    }

    /// So scrolling ahead of the scan frontier reads as "loading", never as
    /// silently empty data. One flat, low-alpha rounded bar — the redacted-line
    /// idea, hand-drawn since this view paints its own cells. Deliberately
    /// STATIC: no shimmer, so it costs one extra fill per empty cell on the
    /// scroll path and never schedules a redraw loop.
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
        let resolvedFont = weight.map { NSFont.systemFont(ofSize: font.pointSize, weight: $0) } ?? font
        let attrs: [NSAttributedString.Key: Any] = [.font: resolvedFont, .foregroundColor: color,
                                                    .paragraphStyle: para]
        let size = (string as NSString).size(withAttributes: attrs)
        let offsetY = (rect.height - size.height) / 2
        (string as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.minY + offsetY, width: rect.width, height: size.height),
            withAttributes: attrs)
    }
}
