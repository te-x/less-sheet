import Contracts

// The pure selection and column-width algebra behind the grid's event handling
// and the model's selection/copy/width state. Semantics live in the `Contracts`
// protocols.

// MARK: - Selection

/// The rectangular-selection algebra: every operation is O(1) in the extent —
/// two corner indices in, two corner indices out, no materialization — so Cmd+A
/// on a 100M×100k document is free. Producing operations return nil only for an
/// empty extent; transition operations re-clamp BOTH incoming corners into the
/// CURRENT extent first, since a filter may have shrunk it since the selection
/// was made.
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
        let clampedRow = min(row, extent.lastRow)
        return Selection(anchor: GridCell(row: clampedRow, column: 0),
                         active: GridCell(row: clampedRow, column: extent.lastColumn))
    }

    public func wholeColumn(_ column: Int, in extent: GridExtent) -> Selection? {
        guard !extent.isEmpty else { return nil }
        let clampedColumn = min(max(column, 0), extent.lastColumn)
        return Selection(anchor: GridCell(row: 0, column: clampedColumn),
                         active: GridCell(row: extent.lastRow, column: clampedColumn))
    }

    public func selectAll(in extent: GridExtent) -> Selection? {
        guard !extent.isEmpty else { return nil }
        return Selection(anchor: GridCell(row: 0, column: 0),
                         active: GridCell(row: extent.lastRow, column: extent.lastColumn))
    }

    /// `cell` moved one step in `direction`, saturating at the extent's edges so
    /// the UInt64 row and Int column can never under/overflow.
    private static func stepped(_ cell: GridCell, _ direction: SelectionDirection, in extent: GridExtent) -> GridCell {
        switch direction {
        case .upward:
            return GridCell(row: cell.row == 0 ? 0 : cell.row - 1, column: cell.column)
        case .down:
            return GridCell(row: cell.row >= extent.lastRow ? extent.lastRow : cell.row + 1, column: cell.column)
        case .left:
            return GridCell(row: cell.row, column: cell.column <= 0 ? 0 : cell.column - 1)
        case .right:
            return GridCell(row: cell.row,
                            column: cell.column >= extent.lastColumn ? extent.lastColumn : cell.column + 1)
        }
    }
}

// MARK: - Column widths

/// A manual override wins over the auto baseline at every width read, regardless
/// of how far auto-grow raised it; `resized`/`cleared` are pure map edits;
/// `autoFit` is the clamped max-content fit over whatever the frontend measured
/// for the visible window.
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
