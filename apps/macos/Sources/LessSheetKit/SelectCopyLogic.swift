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

// MARK: - CopyBuilding (AC2 / AC3)

/// The TSV clipboard builder (`CopyBuilding`): row-major, byte-bounded,
/// lossless per cell. See the protocol doc-comment for the seven pinned
/// rules this implements verbatim (single-cell raw value, TSV structure,
/// Excel/Numbers quoting, byte budget with a first-cell progress guarantee,
/// the cell-count safety cap, the frontier stop, and totality/lossiness).
public struct TSVCopyBuilder: CopyBuilding {
    public init() {}

    public func build(_ rect: SelectionRect, budget: CopyBudget, fetch: CopyCellFetch) -> CopyReport {
        if rect.isSingleCell {
            return Self.buildSingleCell(rect, fetch: fetch)
        }

        var text = ""
        var byteCount = 0
        var cellsFetched = 0
        var lossyCells = false
        var rowCount: UInt64 = 0
        var lastRowWithOutput: UInt64?
        var outcome: CopyOutcome = .complete
        var emittedAny = false

        rowLoop: for row in rect.rows {
            var isFirstColumnInRow = true
            for column in rect.columns {
                // Cell-count SAFETY (rule 5): checked before every fetch, so a
                // pathological all-empty selection can never do more than
                // `maxCells` fetches regardless of the byte budget.
                guard cellsFetched < budget.maxCells else {
                    outcome = .stoppedAtCellCap
                    break rowLoop
                }
                let cell = fetch(row, column)
                cellsFetched += 1

                // FRONTIER (rule 6): a per-row condition — stop at this row
                // boundary, nothing from this row is emitted.
                if cell.status == .pending {
                    outcome = .stoppedAtFrontier
                    break rowLoop
                }

                // TOTALITY (rule 7): a missing cell reads as empty.
                let raw = cell.status == .noCell ? "" : cell.text
                let field = Self.quoted(raw)
                let separator = !emittedAny ? "" : (isFirstColumnInRow ? "\n" : "\t")
                let addition = separator.utf8.count + field.utf8.count

                // BYTE BUDGET (rule 4): the first cell overall is ALWAYS
                // emitted (progress guarantee) — only checked once something
                // has already been emitted.
                if emittedAny, byteCount + addition > budget.maxTotalBytes {
                    outcome = .stoppedAtBudget
                    break rowLoop
                }

                text += separator
                text += field
                byteCount += addition
                emittedAny = true
                isFirstColumnInRow = false
                if cell.truncated { lossyCells = true }
                if row != lastRowWithOutput { rowCount += 1; lastRowWithOutput = row }
            }
        }

        return CopyReport(text: text, byteCount: byteCount, rowCount: rowCount, outcome: outcome, lossyCells: lossyCells)
    }

    /// SINGLE CELL (rule 1): the raw value, verbatim — never quoted, no
    /// trailing newline — regardless of the byte budget (the atomic unit is
    /// already bounded by the per-cell cap the fetch closure applied). A
    /// `.pending` single cell copies nothing (`.stoppedAtFrontier`).
    private static func buildSingleCell(_ rect: SelectionRect, fetch: CopyCellFetch) -> CopyReport {
        let cell = fetch(rect.top, rect.left)
        guard cell.status != .pending else {
            return CopyReport(text: "", byteCount: 0, rowCount: 0, outcome: .stoppedAtFrontier, lossyCells: false)
        }
        let text = cell.status == .noCell ? "" : cell.text
        return CopyReport(text: text, byteCount: text.utf8.count, rowCount: 1, outcome: .complete, lossyCells: cell.truncated)
    }

    /// EXCEL/NUMBERS QUOTING (rule 3): a cell containing a tab, CR, LF, or a
    /// double-quote is wrapped in double-quotes with every interior quote
    /// doubled; anything else is emitted raw.
    private static func quoted(_ text: String) -> String {
        guard Self.needsQuoting(text) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Byte-level check (tab/CR/LF/quote are all single-byte ASCII, so a raw
    /// UTF-8 byte scan is exact — no multibyte sequence can contain one of
    /// these bytes as a continuation byte, which are all >= 0x80).
    private static func needsQuoting(_ text: String) -> Bool {
        text.utf8.contains {
            $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\"")
        }
    }
}

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
