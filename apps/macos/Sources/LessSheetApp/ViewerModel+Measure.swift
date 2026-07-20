import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the O(head) column-width measurement at open (arithmetic body
// sizing + accurate header `.size()`), plus the open-time header labels it
// samples. Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    /// The real header labels available at open, keyed by ABSOLUTE column, for
    /// `measureColumnWidths` (the header-width-at-open fix). Core sessions expose
    /// them through `windowColumnLabels`, just populated by the open-time
    /// `materialize`→`refreshWindowLabels` for the fetched column range; a legacy
    /// in-memory session carries them all in `headerCells`. Empty when the
    /// document has no header row (so the measurement adds no header component).
    func openHeaderLabels(for session: any DocumentSession) -> [Int: String] {
        guard session.dialect.hasHeader else { return [:] }
        if session is CoreDocumentSession { return windowColumnLabels }
        guard let cells = session.headerCells else { return [:] }
        var labels: [Int: String] = [:]
        for (column, label) in cells.enumerated() where !label.isEmpty { labels[column] = label }
        return labels
    }

    // MARK: - Column width measurement (head sample; O(head) arithmetic, no
    // per-cell text layout — ARCH-column-windowing)

    /// Establishes EVERY column's width up front, in ONE O(head) pass. The
    /// BODY cells are sized by cheap character-count arithmetic — the
    /// monospaced data font's per-character advance times the widest display-
    /// cell count over the head sample — NEVER a `.size(withAttributes:)` per
    /// cell (100k text-layout calls across 100k columns is exactly what made a
    /// wide document's cold-open take 3+ s; ARCH-column-windowing). The HEADER
    /// label, in contrast, is measured ACCURATELY with the SEMIBOLD header font
    /// it is actually drawn in (via `.size()`), so each column includes its
    /// header width DETERMINISTICALLY at open — no header-driven widening pops
    /// in on the user's first interaction. That `.size()` is bounded to the
    /// columns whose real labels have already been fetched (`headerLabels`), so
    /// it is O(fetched) text layout, never O(columnCount). A wide document's
    /// off-window columns keep the estimate until `growColumnWidthsToFitWindow`
    /// gives them the ACCURATE `.size()` correction (body AND header) the moment
    /// they enter the horizontal column window, monotone (ARCH AC4).
    static func measureColumnWidths(headerLabels: [Int: String], sample: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        // One O(1) measurement (not per-column, not per-cell) gives the exact
        // per-character advance of the monospaced data font.
        let advance = max(textWidth("0", bodyFont), 1)
        let minW = GridMetrics.minColumnWidth
        let maxW = GridMetrics.maxColumnWidth
        let padding = GridMetrics.cellHPadding * 2
        // Hoisted out of the loop (read once, not per column): this loop runs
        // `columnCount` times (up to 100k on a wide document) so anything paid
        // per-iteration, however small, is worth hoisting. `hasHeaderLabels`
        // lets a no-header document skip the per-column dictionary probe below.
        let sampleCount = sample.count
        let hasHeaderLabels = !headerLabels.isEmpty

        var widths = [CGFloat](repeating: minW, count: columnCount)
        // `.utf8.count` (a stored length on a native Swift String, O(1)) is a
        // cheaper display-cell proxy than `.count` (grapheme-cluster
        // segmentation) for this cheap pass; both are estimates for the SAME
        // exotic-glyph cases (ARCH), and both are superseded by the accurate
        // `.size()` refine the moment a column enters the horizontal window.
        widths.withUnsafeMutableBufferPointer { buf in
            for column in 0..<columnCount {
                // Body cells + the generic A/B/C… name floor (the label shown
                // when a column has no real header; narrow enough that the
                // min-width floor dominates, so measuring it by arithmetic —
                // not `.size()` — costs nothing on a wide no-header document).
                var cells = GenericColumnName.name(at: column).utf8.count
                var sampleIndex = 0
                while sampleIndex < sampleCount {
                    let row = sample[sampleIndex]
                    if column < row.count {
                        let cellLength = row[column].utf8.count
                        if cellLength > cells { cells = cellLength }
                    }
                    sampleIndex += 1
                }
                var textW = CGFloat(cells) * advance
                // Real header label: measured with the semibold header font it
                // is drawn in, so the header width is baked into the column AT
                // OPEN (bounded to the fetched range — see the doc above).
                if hasHeaderLabels, let label = headerLabels[column], !label.isEmpty {
                    textW = max(textW, textWidth(label, headFont))
                }
                buf[column] = min(max(textW + padding, minW), maxW)
            }
        }
        return widths
    }

    static func textWidth(_ string: String, _ font: NSFont) -> CGFloat {
        // A single measured line; ceil to a whole point for crisp grid lines.
        let size = (string as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
}
