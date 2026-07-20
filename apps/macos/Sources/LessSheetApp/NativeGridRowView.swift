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
        guard let controller else { return }
        let height = bounds.height
        let grid = NSColor.gridColor
        let accent = NSColor.controlAccentColor
        // Selection reads as a MUTED GRAY marquee (deliberately quieter than the
        // accent), so a selected cell and an accent find-highlight are distinct
        // by BOTH colour and geometry. Tunable — this one colour drives both the
        // selection wash and its marquee (find highlights stay on `accent`).
        let palette = RowPalette(accent: accent, selection: NSColor.systemGray, grid: grid)
        // `controller.widths` is only the current horizontal column WINDOW
        // (ARCH-column-windowing); start at its exact prefix-sum offset so an
        // in-window column lands at the SAME x a full, unwindowed draw would
        // give it (0 for a viewport-fitting file — ARCH AC4 — and the real
        // scrolled-to offset otherwise).
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

    /// Paints one visible column's cell in the SAME layered order the former
    /// single-method `draw` used: find-highlight background, selection wash,
    /// text/placeholder + warning markers, current-match border, selection
    /// marquee, and the column's trailing hairline (ARCH-select-copy AC1: a cell
    /// can be both matched AND selected).
    private func drawColumn(_ index: Int, in cell: NSRect, controller: NativeGridController,
                            palette: RowPalette) {
        let highlight = index < highlights.count ? highlights[index] : .none
        SheetRowView.drawHighlightBackground(highlight, in: cell, accent: palette.accent)
        // ARCH-select-copy AC1: the selection overlay keeps its muted-gray fill +
        // marquee border, layered on top of (never instead of) a find highlight.
        let mark = index < selectionMarks.count ? selectionMarks[index] : .none
        if mark.isSelected {
            palette.selection.withAlphaComponent(0.12).setFill()
            cell.fill()
        }
        drawCellContent(index, in: cell, controller: controller)
        if highlight == .strong {
            // The current match's border: full-strength accent over the chip,
            // so it reads apart from the subtle matches.
            palette.accent.setStroke()
            let chipPath = SheetRowView.highlightChipPath(in: cell)
            chipPath.lineWidth = FindHighlightStyle.borderWidth
            chipPath.stroke()
        }
        if mark.isSelected {
            SheetRowView.drawSelectionBorder(mark, in: cell, color: palette.selection)
        }
        palette.grid.setFill()
        NSRect(x: cell.maxX - NativeGrid.hairline, y: 0,
               width: NativeGrid.hairline, height: cell.height).fill()
    }

    /// The find-highlight chip fill for a cell (accent, rounded + inset chips —
    /// distinct from a SELECTED cell by BOTH colour and geometry). `.none` paints
    /// nothing.
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

    /// The cell's text (aligned) or, for a not-yet-servable empty cell, the
    /// loading placeholder — then any truncation / format / conflict markers.
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

    /// The horizontal text alignment for a visible column (defaults to leading).
    private func textAlignment(_ index: Int, controller: NativeGridController) -> NSTextAlignment {
        switch index < controller.columnAlignments.count ? controller.columnAlignments[index] : .leading {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    /// Truncation dot + format-unavailable / type-conflict glyphs for a cell
    /// (independent; the conflict glyph shifts left of a present format glyph).
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
        let iconX = cell.maxX - 10 - size - CGFloat(trailingSlot) * (size + 3)
        image.draw(in: NSRect(x: iconX, y: cell.midY - size / 2, width: size, height: size),
                   from: .zero, operation: .sourceOver, fraction: 0.75,
                   respectFlipped: true, hints: nil)
    }

    /// The rounded, inset find-highlight chip for one cell — the ONE geometry
    /// both the subtle/strong fills and the current-match border stroke use,
    /// mirroring `FindHighlightStyle` exactly as the SwiftUI dump path does.
    static func highlightChipPath(in cell: NSRect) -> NSBezierPath {
        NSBezierPath(
            roundedRect: cell.insetBy(dx: FindHighlightStyle.inset, dy: FindHighlightStyle.inset),
            xRadius: FindHighlightStyle.cornerRadius, yRadius: FindHighlightStyle.cornerRadius
        )
    }

    /// The selection RANGE border (ARCH-select-copy AC1): strokes only the
    /// side(s) of `cell` that sit on the selection rect's OUTER edge (an
    /// interior selected cell gets the accent fill only, drawn above — no
    /// stroke), so a multi-cell selection reads as one continuous outlined
    /// range rather than a grid of individually-boxed cells. A confident 2 pt
    /// marquee (the Numbers look) in a muted gray — square caps so the per-cell
    /// segments join seamlessly at range corners; the find highlights use the
    /// accent and read as rounded INSET chips, so matched vs selected stay
    /// distinct by both colour and geometry.
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
