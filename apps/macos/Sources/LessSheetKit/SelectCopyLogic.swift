import Contracts

// GREEN (implementer) — the pure select-copy logic (ARCH-select-copy),
// implementer-owned and NON-frozen (Sources/LessSheetKit). Each type CONFORMS
// to its frozen Contracts protocol and implements the real algebra the
// doc-comments specify; the App (NativeGrid event handling + ViewerModel
// selection/copy/width state) routes through these. None of this touches a
// frozen path.

// MARK: - Selecting (AC1)

/// The rectangular-selection algebra (`Selecting`): every operation is O(1) in
/// the extent — two corner indices in, two corner indices out, no
/// materialization — so Cmd+A on a 100M×100k document is free. Producing
/// operations (`select`/`wholeRow`/`wholeColumn`/`selectAll`) return nil only
/// for an empty extent; transition operations (`extend`/`move`) re-clamp BOTH
/// corners of the incoming selection into the CURRENT extent first (a filter
/// may have shrunk it since the selection was made), so they always return a
/// valid selection.
public struct SelectionModel: Selecting {
    public init() {}

    public func select(_ cell: GridCell, in extent: GridExtent) -> Selection? {
        guard !extent.isEmpty else { return nil }
        let clamped = extent.clamped(cell)
        return Selection(anchor: clamped, active: clamped)
    }

    public func extend(_ selection: Selection, to cell: GridCell, in extent: GridExtent) -> Selection {
        Selection(anchor: extent.clamped(selection.anchor), active: extent.clamped(cell))
    }

    public func move(_ selection: Selection, _ direction: SelectionDirection, in extent: GridExtent) -> Selection {
        let stepped = Self.stepped(extent.clamped(selection.active), direction, in: extent)
        return Selection(anchor: stepped, active: stepped)
    }

    public func extend(_ selection: Selection, _ direction: SelectionDirection, in extent: GridExtent) -> Selection {
        let anchor = extent.clamped(selection.anchor)
        let active = Self.stepped(extent.clamped(selection.active), direction, in: extent)
        return Selection(anchor: anchor, active: active)
    }

    public func wholeRow(_ row: UInt64, in extent: GridExtent) -> Selection? {
        guard !extent.isEmpty else { return nil }
        let r = min(row, extent.lastRow)
        return Selection(anchor: GridCell(row: r, column: 0), active: GridCell(row: r, column: extent.lastColumn))
    }

    public func wholeColumn(_ column: Int, in extent: GridExtent) -> Selection? {
        guard !extent.isEmpty else { return nil }
        let c = min(max(column, 0), extent.lastColumn)
        return Selection(anchor: GridCell(row: 0, column: c), active: GridCell(row: extent.lastRow, column: c))
    }

    public func selectAll(in extent: GridExtent) -> Selection? {
        guard !extent.isEmpty else { return nil }
        return Selection(anchor: GridCell(row: 0, column: 0), active: GridCell(row: extent.lastRow, column: extent.lastColumn))
    }

    /// `cell` moved one step in `direction`, saturating at 0 (up/left) or the
    /// extent's last row/column (down/right) — a step past an edge stays on
    /// the edge (never under/overflows the UInt64 row / Int column).
    private static func stepped(_ cell: GridCell, _ direction: SelectionDirection, in extent: GridExtent) -> GridCell {
        switch direction {
        case .up:
            return GridCell(row: cell.row == 0 ? 0 : cell.row - 1, column: cell.column)
        case .down:
            return GridCell(row: cell.row >= extent.lastRow ? extent.lastRow : cell.row + 1, column: cell.column)
        case .left:
            return GridCell(row: cell.row, column: cell.column <= 0 ? 0 : cell.column - 1)
        case .right:
            return GridCell(row: cell.row, column: cell.column >= extent.lastColumn ? extent.lastColumn : cell.column + 1)
        }
    }
}

// MARK: - Streaming copy (ARCH-thin-frontend-shared-core Phase 2)
//
// The former `TSVCopyBuilder` (a `CopyBuilding` conformer driving a per-cell
// `CopyCellFetch`) is DELETED: TSV framing (TAB/LF, spreadsheet quoting,
// single-cell raw, lossless cells, the cell-count cap) now lives ONCE in the
// core (`ls_copy_*`), streamed by `CoreDocumentSession.openCopy` and driven by
// `DocumentModel.streamCopy`. The `CopyBuilding` protocol + `CopyCellFetch`
// typealias were removed from `Contracts/CopyBuilder.swift` (DECISION-2); the
// retained `CopyBudget` / `CopyReport` / `CopyOutcome` / `CopiedCell` /
// `CopyCellStatus` / `SelectionRect` are still used by the streaming drive and
// the `copyCell` / `ls_cell_copy` lossless single-cell read.

// MARK: - ColumnSizing (AC5)

/// The column-width algebra (`ColumnSizing`): a manual override wins over the
/// auto baseline at every width read, regardless of how far auto-grow raised
/// it; `resized`/`cleared` are pure map edits; `autoFit` is the clamped
/// max-content fit over whatever the frontend measured for the visible
/// window. See the protocol doc-comment for the full pinned semantics.
public struct ColumnSizer: ColumnSizing {
    public init() {}

    public func effectiveWidths(auto: [Double], manual: [Int: Double]) -> [Double] {
        guard !manual.isEmpty else { return auto }
        var result = auto
        for (column, width) in manual where result.indices.contains(column) {
            result[column] = width
        }
        return result
    }

    public func resized(manual: [Int: Double], column: Int, to width: Double, minWidth: Double) -> [Int: Double] {
        var result = manual
        result[column] = max(width, minWidth)
        return result
    }

    public func cleared(manual: [Int: Double], column: Int) -> [Int: Double] {
        var result = manual
        result.removeValue(forKey: column)
        return result
    }

    public func autoFit(contentWidths: [Double], minWidth: Double, maxWidth: Double) -> Double {
        let measured = contentWidths.max() ?? minWidth
        return min(max(measured, minWidth), maxWidth)
    }
}
