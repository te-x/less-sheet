import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The column-width measurement at open.

extension DocumentModel {
    /// The real header labels available at open, keyed by ABSOLUTE column. A core
    /// session has them in `windowColumnLabels`, just populated for the fetched
    /// column range; an in-memory one carries them all. Empty for a headerless
    /// document, so the measurement then adds no header component.
    func openHeaderLabels(for session: any DocumentSession) -> [Int: String] {
        guard session.dialect.hasHeader else { return [:] }
        if session is CoreDocumentSession { return windowColumnLabels }
        guard let cells = session.headerCells else { return [:] }
        var labels: [Int: String] = [:]
        for (column, label) in cells.enumerated() where !label.isEmpty { labels[column] = label }
        return labels
    }

    /// Establishes EVERY column's width up front, in one pass over the head
    /// sample.
    ///
    /// Body cells are sized by character-count arithmetic — the monospaced font's
    /// per-character advance times the widest cell — never a text-layout call per
    /// cell: 100k of those across 100k columns is what once put a wide document's
    /// cold open over three seconds. The HEADER label is measured accurately, in
    /// the semibold font it is drawn in, so every column includes its header width
    /// deterministically at open and nothing pops on first interaction; that
    /// measurement is bounded to the labels already fetched. Off-window columns
    /// keep the arithmetic estimate until they enter the horizontal window and
    /// `growColumnWidthsToFitWindow` corrects them, monotonically.
    static func measureColumnWidths(headerLabels: [Int: String], sample: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        // One measurement gives the exact per-character advance of the
        // monospaced data font.
        let advance = max(textWidth("0", bodyFont), 1)
        let minW = GridMetrics.minColumnWidth
        let maxW = GridMetrics.maxColumnWidth
        let padding = GridMetrics.cellHPadding * 2
        // Hoisted: this loop runs up to 100k times, so anything paid per
        // iteration is worth lifting out — and `hasHeaderLabels` lets a headerless
        // document skip the dictionary probe entirely.
        let sampleCount = sample.count
        let hasHeaderLabels = !headerLabels.isEmpty

        var widths = [CGFloat](repeating: minW, count: columnCount)
        // `.utf8.count` is O(1) on a native String, unlike `.count`'s grapheme
        // segmentation, and both are equally rough for exotic glyphs — which the
        // accurate refine corrects the moment the column enters the window.
        widths.withUnsafeMutableBufferPointer { buf in
            for column in 0..<columnCount {
                // The generic A/B/C… name is the floor for a column with no real
                // header; it is narrow enough that the min-width floor dominates.
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
