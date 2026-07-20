import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the row-number gutter, the eager (dump) grid helpers, and the
// window-bound live-grid helpers (cells / widths / labels / alignments /
// highl' presentations over the horizontal column window). Pure code motion.

extension DocumentModel {
    // MARK: - Row-number gutter (fixed leftmost column; 1-based)

    /// Width of the fixed row-number gutter, sized to fit the largest 1-based
    /// row number currently in view (ARCH: "width fits the largest visible
    /// number"). Stable per digit count — it only steps when the visible range
    /// crosses a power-of-ten — and never below a 2-digit floor. Uses tabular
    /// digits so the width is exact.
    func rowNumberColumnWidth() -> CGFloat {
        let maxVisible: Int
        if isFiltered {
            // Original row numbers are non-contiguous under a filter (ARCH
            // criterion 13): size for the largest POSSIBLE original number —
            // the captured document row count — so the gutter width stays
            // stable across a scroll instead of re-deriving it from each
            // visible row's source mapping.
            let documentRows = filterDocumentRows?.count ?? rowCountInfo.count
            maxVisible = Int(min(documentRows, UInt64(Int.max)))
        } else {
            // Clamp to the last data row so scrolling into the overscroll strip
            // (whose filler rows carry no number) never inflates the gutter.
            maxVisible = min(firstVisibleRow + max(lastVisibleCount, 1), max(displayRowCount, 1))
        }
        return Self.rowNumberWidth(digits: Self.rowNumberDigits(forMaxNumber: maxVisible))
    }

    /// The row-number gutter's value for row `row` (ARCH criteria 13/17): the
    /// row's ORIGINAL (unfiltered) data-row number while a filter is active —
    /// forwarded verbatim from the core's `sourceRow`, never recomputed — else
    /// the row's own identity index. `nil` while filtered and the row is not
    /// currently servable (outside the materialized window) — the gutter
    /// leaves such a row blank until a re-window catches up, exactly like its
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

    // MARK: - Grid view helpers (the EAGER, all-visible-columns dump grid;
    // ARCH-headless-dump / FrameDump). The dump renders small, already-loaded
    // fixtures off the cold-open path, so an O(visible columns) pass here is
    // fine — it is NOT what the live grid draws; see the window-bound
    // counterparts below for that (ARCH-column-windowing).

    /// Frozen widths of the visible columns, in render order — EFFECTIVE
    /// widths (ARCH-select-copy AC5: a manual override wins over the auto
    /// baseline), see `effectiveWidths(for:)`.
    func visibleWidths() -> [CGFloat] {
        effectiveWidths(for: visibleColumns)
    }

    /// Header labels of the visible columns (effective names or generic A/B/C).
    func headerLabels() -> [String] {
        visibleColumns.map { columnLabel($0) }
    }

    /// Visible-column cells for a data row, empty-padded while not yet loaded
    /// (or, on a wide document, not yet in the fetched column range — see
    /// `cellsAt`).
    func visibleBodyCells(forRow row: Int) -> [String] {
        cellsAt(visibleColumns, forRow: row)
    }

    /// Visible-column truncation flags for a data row (ARCH req. 13/20),
    /// false-padded while not yet loaded — same shape as `visibleBodyCells`.
    /// Driven entirely by the core's per-cell flag; never re-measures cells.
    func visibleBodyTruncated(forRow row: Int) -> [Bool] {
        truncatedAt(visibleColumns, forRow: row)
    }

    // MARK: - Horizontal column window (the LIVE grid; ARCH-column-windowing)
    //
    // The window-bound counterparts of the helpers above: every one is O(the
    // horizontal column window), NEVER O(columnCount), so `NativeGridController`
    // can call them on every scroll/materialize tick even on a 100k-column
    // document. Each slices `windowColumns()` — itself an O(window) slice of the
    // memoized `visibleColumns` — so none of these ever re-filters `0..<columnCount`.

    /// The current column window's ABSOLUTE column indices, in render order.
    func windowColumns() -> [Int] {
        let cols = visibleColumns
        guard !cols.isEmpty else { return [] }
        let clamped = columnWindow.range.clamped(to: 0..<cols.count)
        guard !clamped.isEmpty else { return [] }
        return Array(cols[clamped])
    }

    /// Widths of the current column window, in render order — what the live
    /// grid draws (`NativeGridController.widths`); EFFECTIVE widths, see
    /// `effectiveWidths(for:)`.
    func windowWidths() -> [CGFloat] {
        effectiveWidths(for: windowColumns())
    }

    /// `columns`' EFFECTIVE widths (`ColumnSizing.effectiveWidths`, "manual
    /// wins" — ARCH-select-copy AC5): builds a COLUMNS-local `auto`/`manual`
    /// pair so the contract call stays O(columns.count) — a window or the
    /// visible-columns list, never O(columnCount) beyond what the caller
    /// already asked for — then folds them through the contract.
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

    /// Absolute column indices of the current column window, in render
    /// order — PARALLEL to `windowWidths()`/`windowHeaderLabels()`: the
    /// click→cell mapping's column half (ARCH-select-copy). Position `i`
    /// here is the SAME absolute column `windowWidths()[i]` is the width of.
    func windowAbsoluteColumns() -> [Int] {
        windowColumns()
    }

    /// Column-window cells for a data row, empty-padded while not yet loaded
    /// — the window-bound analog of `visibleBodyCells`.
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

    /// Targeted counterpart used by a direct column-config redraw. It reads
    /// and formats one logical column only, preserving the same raw/truncated/
    /// oversized/null/conflict rules as the vector helper above.
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

    /// Column-window truncation flags for a data row — the window-bound
    /// analog of `visibleBodyTruncated`.
    func windowBodyTruncated(forRow row: Int) -> [Bool] {
        truncatedAt(windowColumns(), forRow: row)
    }

    /// Sum of every VISIBLE column's width — the document's total horizontal
    /// content extent, independent of the window (drives the live grid's
    /// scrollable table-column width / filler-column count —
    /// `NativeGridController.refreshColumnWidth`). Memoized alongside
    /// `cachedLayoutWidths` (see `refreshLayoutWidthsIfNeeded`); meant to be
    /// read only on a structural change (open, hidden-column toggle, a
    /// width-batch change) via `refreshLayoutMetrics`, never per scroll tick
    /// — though it costs nothing extra even then, once the shared cache is
    /// warm.
    var totalVisibleWidth: CGFloat {
        refreshLayoutWidthsIfNeeded()
        return cachedTotalVisibleWidth
    }
}
