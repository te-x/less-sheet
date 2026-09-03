import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The row-number gutter, the eager dump-grid helpers, and their window-bound
// counterparts that the live grid draws from.

extension DocumentModel {
    // MARK: - Row-number gutter (fixed leftmost column; 1-based)

    /// Sized to the largest 1-based row number currently in view, so it steps
    /// only when the visible range crosses a power of ten. Tabular digits make
    /// the measurement exact.
    func rowNumberColumnWidth() -> CGFloat {
        let maxVisible: Int
        if isFiltered {
            // Original row numbers are non-contiguous under a filter, so size for
            // the largest POSSIBLE one. Re-deriving it from each visible row's
            // source mapping would make the gutter width change as you scroll.
            let documentRows = filterDocumentRows?.count ?? rowCountInfo.count
            maxVisible = Int(min(documentRows, UInt64(Int.max)))
        } else {
            // Clamp to the last data row so scrolling into the overscroll strip
            // (whose filler rows carry no number) never inflates the gutter.
            maxVisible = min(firstVisibleRow + max(lastVisibleCount, 1), max(displayRowCount, 1))
        }
        return Self.rowNumberWidth(digits: Self.rowNumberDigits(forMaxNumber: maxVisible))
    }

    /// The gutter's value for a row: its ORIGINAL data-row number while a filter
    /// is active, forwarded verbatim from the core and never recomputed, else its
    /// own index. `nil` when filtered and the row is not currently servable — the
    /// gutter leaves it blank until a re-window catches up, exactly like its
    /// cells.
    func gutterRow(forRow row: Int) -> UInt64? {
        guard isFiltered else { return UInt64(row) }
        return session?.sourceRow(UInt64(row))
    }

    static func rowNumberDigits(forMaxNumber maxNumber: Int) -> Int {
        max(GridMetrics.rowNumberMinDigits, String(max(1, maxNumber)).count)
    }

    static func rowNumberWidth(digits: Int) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let sample = String(repeating: "8", count: max(1, digits)) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + GridMetrics.rowNumberHPadding * 2
            + GridMetrics.oversizedMarkerReserve
    }

    // MARK: - Eager, all-visible-columns helpers (the dump grid)
    //
    // The dump renders small, already-loaded fixtures off the cold-open path, so
    // an O(visible columns) pass is fine here. This is NOT what the live grid
    // draws — see the window-bound counterparts below.

    /// Effective widths of the visible columns, in render order.
    func visibleWidths() -> [CGFloat] {
        effectiveWidths(for: visibleColumns)
    }

    /// Header labels of the visible columns (effective names or generic A/B/C).
    func headerLabels() -> [String] {
        visibleColumns.map { columnLabel($0) }
    }

    /// Visible-column cells for a data row, empty-padded while not yet loaded or
    /// not yet in the fetched column range.
    func visibleBodyCells(forRow row: Int) -> [String] {
        cellsAt(visibleColumns, forRow: row)
    }

    /// Visible-column truncation flags, parallel to `visibleBodyCells`. Driven
    /// entirely by the core's per-cell flag; never re-measured here.
    func visibleBodyTruncated(forRow row: Int) -> [Bool] {
        truncatedAt(visibleColumns, forRow: row)
    }

    // MARK: - Horizontal column window (the LIVE grid)
    //
    // The window-bound counterparts: every one is O(the column window), never
    // O(columnCount), so the grid can call them on every scroll tick even on a
    // 100k-column document.

    /// The current column window's ABSOLUTE column indices, in render order.
    func windowColumns() -> [Int] { cachedWindowColumns }

    /// Effective widths of the current column window, in render order — exactly
    /// what the live grid draws.
    func windowWidths() -> [CGFloat] {
        effectiveWidths(for: windowColumns())
    }

    /// `columns`' effective widths, manual override winning. Builds a
    /// columns-local auto/manual pair so the call stays O(columns.count) rather
    /// than O(columnCount).
    private func effectiveWidths(for columns: [Int]) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let auto = columns.map {
            $0 < columnWidths.count ? Double(columnWidths[$0]) : Double(GridMetrics.minColumnWidth)
        }
        var manual: [Int: Double] = [:]
        if !manualColumnWidths.isEmpty {
            for (index, column) in columns.enumerated() {
                if let width = manualColumnWidths[column] { manual[index] = width }
            }
        }
        return columnSizer.effectiveWidths(auto: auto, manual: manual).map { CGFloat($0) }
    }

    /// Header labels of the current column window, in render order.
    func windowHeaderLabels() -> [String] {
        windowColumns().map { columnLabel($0) }
    }

    /// Header-label truncation flags parallel to `windowHeaderLabels`.
    func windowHeaderTruncated() -> [Bool] {
        windowColumns().map { windowTruncatedLabels.contains($0) }
    }

    /// The click-to-cell mapping's column half: position `i` here is the same
    /// absolute column `windowWidths()[i]` is the width of.
    func windowAbsoluteColumns() -> [Int] {
        windowColumns()
    }

    /// Column-window cells for a data row, empty-padded while not yet loaded.
    func windowBodyCells(forRow row: Int) -> [String] {
        windowCellPresentations(forRow: row).map(\.text)
    }

    func windowCellPresentations(forRow row: Int) -> [WindowCellPresentation] {
        let columns = windowColumns()
        let raw = cellsAt(columns, forRow: row)
        let truncated = truncatedAt(columns, forRow: row)
        let rowIsOversized = rowOversized(forRow: row)
        let formatter = ColumnDisplayFormatter()
        return columns.enumerated().map { offset, column in
            let source = offset < raw.count ? raw[offset] : ""
            guard !rowIsOversized, !(offset < truncated.count && truncated[offset]),
                  let metadata = windowColumnMetadata[column] else {
                return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
            }
            let settings = userSettings(for: column)
            if let sentinel = settings.nullSentinel, sentinel == Array(source.utf8) {
                return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
            }
            let outcome = formatter.display(raw: source, type: metadata.effective,
                                            options: settings.format, locale: sessionLocale)
            let unavailable: Bool
            if case .formatUnavailable = outcome { unavailable = true } else { unavailable = false }
            return WindowCellPresentation(
                text: outcome.text, formatUnavailable: unavailable,
                conflict: Self.cellConflicts(source, type: metadata.effective, formatter: formatter)
            )
        }
    }

    /// One column only, under exactly the same raw/truncated/oversized/null/
    /// conflict rules as the vector helper above.
    func windowCellPresentation(forRow row: Int, column: Int) -> WindowCellPresentation {
        let source = cellsAt([column], forRow: row).first ?? ""
        let isTruncated = truncatedAt([column], forRow: row).first ?? false
        guard !rowOversized(forRow: row), !isTruncated,
              let metadata = windowColumnMetadata[column] else {
            return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
        }
        let settings = userSettings(for: column)
        if let sentinel = settings.nullSentinel, sentinel == Array(source.utf8) {
            return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
        }
        let formatter = ColumnDisplayFormatter()
        let outcome = formatter.display(raw: source, type: metadata.effective,
                                        options: settings.format, locale: sessionLocale)
        let unavailable: Bool
        if case .formatUnavailable = outcome { unavailable = true } else { unavailable = false }
        return WindowCellPresentation(
            text: outcome.text, formatUnavailable: unavailable,
            conflict: Self.cellConflicts(source, type: metadata.effective, formatter: formatter)
        )
    }

    private static func cellConflicts(_ raw: String, type: ColumnType,
                                      formatter: ColumnDisplayFormatter) -> Bool {
        guard !raw.isEmpty else { return false }
        switch type.kind {
        case .unknown, .unsupported, .text: return false
        case .boolean: return formatter.strictKind(of: raw) != .boolean
        case .integer: return formatter.strictKind(of: raw) != .integer
        case .decimal:
            let kind = formatter.strictKind(of: raw)
            return kind != .integer && kind != .decimal
        case .date: return formatter.strictKind(of: raw) != .date
        case .datetime:
            let expected: ColumnScalarKind = type.datetimeSemantics == .zoned ? .datetimeZoned : .datetimeNaive
            return formatter.strictKind(of: raw) != expected
        }
    }

    func windowColumnAlignments() -> [ColumnTextAlignment] {
        let rules = ColumnAlignmentRules()
        return windowColumns().map { column in
            rules.alignment(for: windowColumnMetadata[column]?.effective.kind ?? .unknown, isConflict: false)
        }
    }

    func columnAlignment(_ column: Int) -> ColumnTextAlignment {
        ColumnAlignmentRules().alignment(
            for: windowColumnMetadata[column]?.effective.kind ?? .unknown,
            isConflict: false
        )
    }

    /// Column-window truncation flags for a data row.
    func windowBodyTruncated(forRow row: Int) -> [Bool] {
        truncatedAt(windowColumns(), forRow: row)
    }

    /// The document's total horizontal content extent — every VISIBLE column,
    /// independent of the window — which drives the scrollable column width and
    /// the filler count. Memoized alongside `cachedLayoutWidths`, so reading it
    /// costs nothing once that cache is warm.
    var totalVisibleWidth: CGFloat {
        refreshLayoutWidthsIfNeeded()
        return cachedTotalVisibleWidth
    }
}
