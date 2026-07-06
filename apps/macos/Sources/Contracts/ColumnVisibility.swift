/// Hidden-column session state (ARCH-viewer-ui reqs. 9–11). Hiding is PURE
/// PRESENTATION: core row/column addressing is untouched; the grid simply
/// renders the visible subset (widths re-flow).
///
/// Invariants of a value produced by a `ColumnVisibilityManaging`
/// implementation:
/// - `hiddenColumns` only contains indices in 0..<columnCount.
/// - When `columnCount` > 0, at least ONE column is always visible (the
///   "last visible column cannot be hidden" rule).
public struct ColumnVisibility: Equatable, Sendable {
    public let columnCount: Int
    public let hiddenColumns: Set<Int>

    public init(columnCount: Int, hiddenColumns: Set<Int>) {
        self.columnCount = columnCount
        self.hiddenColumns = hiddenColumns
    }

    public func isHidden(_ column: Int) -> Bool {
        hiddenColumns.contains(column)
    }
}

/// Pure transitions over `ColumnVisibility`. Pinned semantics:
/// - `allVisible(columnCount:)` — the initial state of every fresh open:
///   nothing hidden.
/// - `toggling(_:column:)` — hidden column: unhide. Visible column: hide it
///   IF `canHide` allows; otherwise return the value unchanged. Out-of-range
///   columns: unchanged.
/// - `canHide(_:column:)` — false when the column is out of range, already
///   hidden, or is the LAST visible column (its Configure checkbox renders
///   disabled — ARCH criterion 11).
/// - `carriedOver(_:toColumnCount:)` — session survival across a dialect
///   re-open (ARCH req. 10): the SAME column count keeps the value
///   unchanged; a DIFFERENT count resets to `allVisible(columnCount:)`.
/// - `visibleColumns(_:)` — the ascending indices of the visible columns
///   (what the grid renders, in order).
public protocol ColumnVisibilityManaging: Sendable {
    func allVisible(columnCount: Int) -> ColumnVisibility
    func toggling(_ visibility: ColumnVisibility, column: Int) -> ColumnVisibility
    func canHide(_ visibility: ColumnVisibility, column: Int) -> Bool
    func carriedOver(_ visibility: ColumnVisibility, toColumnCount newCount: Int) -> ColumnVisibility
    func visibleColumns(_ visibility: ColumnVisibility) -> [Int]
}
