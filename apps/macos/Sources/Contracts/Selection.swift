/// The rectangular cell-SELECTION model in INDEX space (ARCH-select-copy AC1),
/// the pure heart the frontend's mouse/keyboard/gutter/header routing must run
/// its selection state through. Same layering as `ColumnLayouting` /
/// `ColumnVisibilityManaging`: no AppKit, no pixels — only the deterministic
/// geometry (anchor + active corner → a normalized rect, clamped to the doc
/// extent) that is exact and gate-stable. The frontend maps mouse points to
/// (row, column) indices and renders the rect's cells (reusing
/// `SheetCellHighlight`); THIS owns which cell/rect each interaction yields.
///
/// UNBOUNDED by design. A selection is TWO corner indices — O(1) to hold and to
/// compute, O(visible) to draw — so there is NO row/column count clamp: Cmd+A on
/// a 100M × 100k document selects the whole extent in constant time and space
/// (ARCH: "the COST is bounded at COPY, not at selection"). Every operation here
/// is arithmetic on the two corners; nothing materializes cells. The bound lives
/// entirely in the copy builder (`CopyBuilding`), never here.

/// One cell address, mirroring the core's addressing: a 64-bit view-relative
/// ROW index (documents reach 100M+ rows) and a 0-based COLUMN index (an `Int`,
/// as everywhere else in Contracts — `columnCount`, `RowWindow.firstColumn`,
/// `ColumnWindow.first`). A FILTERED row index while a filter is active, exactly
/// like every other row index the frontend holds.
public struct GridCell: Equatable, Hashable, Sendable {
    public let row: UInt64
    public let column: Int

    public init(row: UInt64, column: Int) {
        self.row = row
        self.column = column
    }
}

/// The document's selectable EXTENT — the clamp domain for every interaction:
/// `rowCount` rows (the current view's count — the FILTERED count while a filter
/// is active) and `columnCount` columns. Valid cell indices are `0 ..< rowCount`
/// (rows) and `0 ..< columnCount` (columns). An extent is EMPTY when it has no
/// rows or no columns (an empty document, or a filter matching nothing): no
/// selection exists over it, so the producing operations return nil.
public struct GridExtent: Equatable, Sendable {
    public let rowCount: UInt64
    public let columnCount: Int

    public init(rowCount: UInt64, columnCount: Int) {
        self.rowCount = rowCount
        self.columnCount = columnCount
    }

    /// No selectable cell exists (no rows or no columns).
    public var isEmpty: Bool { rowCount == 0 || columnCount == 0 }
    /// The last valid row index (`rowCount - 1`); 0 for an empty extent (never
    /// consult it without checking `isEmpty`).
    public var lastRow: UInt64 { rowCount == 0 ? 0 : rowCount - 1 }
    /// The last valid column index (`columnCount - 1`); 0 for an empty extent.
    public var lastColumn: Int { columnCount == 0 ? 0 : columnCount - 1 }

    /// `cell` with its row/column clamped into `[0, lastRow] × [0, lastColumn]`.
    /// Meaningless for an empty extent (callers guard on `isEmpty` first).
    public func clamped(_ cell: GridCell) -> GridCell {
        GridCell(row: min(cell.row, lastRow),
                 column: min(max(cell.column, 0), lastColumn))
    }
}

/// A single-step cursor move for arrow / shift-arrow interactions.
public enum SelectionDirection: Sendable, Equatable {
    case upward, down, left, right
}

/// The NORMALIZED selection rectangle — the two corners sorted so `top <= bottom`
/// and `left <= right` — with INCLUSIVE bounds (the cell at `(bottom, right)` is
/// in the selection). This is what the grid draws (its cells) and what the copy
/// builder iterates (row-major over `rows × columns`). Derived from a `Selection`
/// via `Selection.rect`; holding it is O(1) regardless of how many cells it spans.
public struct SelectionRect: Equatable, Sendable {
    public let top: UInt64
    public let bottom: UInt64
    public let left: Int
    public let right: Int

    public init(top: UInt64, bottom: UInt64, left: Int, right: Int) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    /// The inclusive row span `top ... bottom` (what the copy builder iterates).
    public var rows: ClosedRange<UInt64> { top ... bottom }
    /// The inclusive column span `left ... right`.
    public var columns: ClosedRange<Int> { left ... right }
    /// Rows in the rect (`bottom - top + 1`) — up to the whole document; O(1).
    public var rowCount: UInt64 { bottom - top + 1 }
    /// Columns in the rect (`right - left + 1`).
    public var columnCount: Int { right - left + 1 }
    /// Whether the rect is a single cell (drives the raw-value copy special case).
    public var isSingleCell: Bool { top == bottom && left == right }

    public func contains(_ cell: GridCell) -> Bool {
        cell.row >= top && cell.row <= bottom && cell.column >= left && cell.column <= right
    }
}

/// A live selection: the fixed `anchor` corner and the moving `active` corner
/// (the cell the last interaction landed on). The rect is their bounding box —
/// so extend-to (drag / shift-click / shift-arrow) simply moves `active` while
/// `anchor` stays put, and a whole-row / whole-column / select-all is just the
/// two corners placed at the extent's edges. There is no separate "kind": the
/// frontend derives full-row / full-column visual emphasis from the rect vs. the
/// extent (e.g. a column is fully selected iff `top == 0 && bottom == lastRow`).
public struct Selection: Equatable, Sendable {
    public let anchor: GridCell
    public let active: GridCell

    public init(anchor: GridCell, active: GridCell) {
        self.anchor = anchor
        self.active = active
    }

    /// The normalized bounding rect of the two corners (inclusive).
    public var rect: SelectionRect {
        SelectionRect(top: min(anchor.row, active.row),
                      bottom: max(anchor.row, active.row),
                      left: min(anchor.column, active.column),
                      right: max(anchor.column, active.column))
    }
}

/// Pure, deterministic rectangular-selection transitions (ARCH-select-copy AC1).
/// Implemented in `LessSheetKit` as `SelectionModel`, pinned by a frozen
/// conformance test (`let _: any Selecting = SelectionModel()`), exactly like the
/// other view-model logic contracts. Every method is O(1) in the extent — no
/// clamping loop, no materialization — so Cmd+A on the largest document is free.
///
/// Producing operations return `Selection?`: nil ONLY when the extent is empty
/// (nothing to select). Transition operations (`extend`, `move`) take a valid
/// `Selection` and return a valid one, re-clamped to the (current) extent.
///
/// Pinned semantics:
/// - `select(_:in:)` — a click: a single-cell selection at the clicked cell
///   (clamped into the extent). `anchor == active == cell`.
/// - `extend(_:to:in:)` — a drag or shift-click: `anchor` is kept, `active` moves
///   to the target cell (clamped). The rect becomes their bounding box.
/// - `move(_:_:in:)` — an arrow key: COLLAPSE to a single cell, stepping the
///   ACTIVE corner one cell in `direction` (clamped at the extent edge — a step
///   past an edge stays on the edge). `anchor == active == stepped`.
/// - `extend(_:_:in:)` — a shift-arrow: `anchor` is kept, the ACTIVE corner steps
///   one cell in `direction` (clamped), growing/shrinking the rect.
/// - `wholeRow(_:in:)` — a gutter click: the rect spanning that row across ALL
///   columns (`anchor = (row, 0)`, `active = (row, lastColumn)` — so a following
///   shift-arrow-down / gutter-shift extends whole rows). `row` clamped.
/// - `wholeColumn(_:in:)` — a header click: the rect spanning that column across
///   ALL rows (`anchor = (0, column)`, `active = (lastRow, column)`). Clamped.
/// - `selectAll(in:)` — Cmd+A: the whole extent (`(0,0) … (lastRow, lastColumn)`),
///   computed in O(1) for any extent size.
///
/// Whole-row/whole-column EXTEND (shift + gutter / header) is composed by the
/// frontend from `extend(_:to:in:)` — e.g. gutter shift-click of row r keeps the
/// anchor and extends to `GridCell(row: r, column: extent.lastColumn)`; header
/// shift-click of column c extends to `GridCell(row: extent.lastRow, column: c)`.
public protocol Selecting: Sendable {
    func select(_ cell: GridCell, in extent: GridExtent) -> Selection?
    func extend(_ selection: Selection, to cell: GridCell, in extent: GridExtent) -> Selection
    func move(_ selection: Selection, _ direction: SelectionDirection, in extent: GridExtent) -> Selection
    func extend(_ selection: Selection, _ direction: SelectionDirection, in extent: GridExtent) -> Selection
    func wholeRow(_ row: UInt64, in extent: GridExtent) -> Selection?
    func wholeColumn(_ column: Int, in extent: GridExtent) -> Selection?
    func selectAll(in extent: GridExtent) -> Selection?
}
