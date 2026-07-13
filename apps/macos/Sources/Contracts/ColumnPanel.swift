import Foundation

/// The compact column-configuration panel's PURE geometry + label search
/// (ARCH-column-config criteria 11/12). The panel replaces the old Settings
/// `ForEach(0..<columnCount)` with a virtualized list: on `wide_100k_cols` it
/// must instantiate O(viewport) rows and request O(viewport) label/metadata IDs,
/// never O(total columns). The AppKit `NSTableView` reuse + off-main search
/// live in `LessSheetApp`; THIS owns the deterministic decisions
/// (which rows to instantiate, which labels match), implemented in
/// `LessSheetKit` and pinned by frozen conformance tests. No AppKit here.

/// The panel's vertical viewport over the column list (one row per column).
public struct ColumnPanelViewport: Equatable, Sendable {
    /// Total columns in the document (may be 100_000+).
    public let totalColumns: Int
    /// The 0-based column index at the top of the viewport.
    public let firstVisibleRow: Int
    /// The number of rows that fit the viewport.
    public let visibleRowCount: Int

    public init(totalColumns: Int, firstVisibleRow: Int, visibleRowCount: Int) {
        self.totalColumns = totalColumns
        self.firstVisibleRow = firstVisibleRow
        self.visibleRowCount = visibleRowCount
    }
}

/// The bounded set of column rows a panel paint instantiates + requests
/// metadata/labels for.
public struct ColumnPanelPlan: Equatable, Sendable {
    /// The half-open column-index range whose row views are instantiated (and
    /// whose labels/metadata are requested). Bounded by `3·visibleRowCount + 8`
    /// and clamped to `0 ..< totalColumns`, INDEPENDENT of `totalColumns`.
    public let instantiatedRows: Range<Int>

    public init(instantiatedRows: Range<Int>) {
        self.instantiatedRows = instantiatedRows
    }
}

/// Pure virtualized-panel geometry (ARCH criterion 11). Implemented in
/// `LessSheetKit` (`ColumnPanelLayout`), pinned by a frozen conformance test.
///
/// Pinned semantics (the spec the RED seed does NOT satisfy — the seed returns
/// the whole `0 ..< totalColumns`, i.e. the old eager list):
/// - `plan(for:)` instantiates the visible rows PLUS one viewport of overscan on
///   EACH side, clamped to `0 ..< totalColumns`; `instantiatedRows.count` is at
///   most `3·visibleRowCount + 8` for ANY `totalColumns` (the O(viewport) bound);
/// - the range COVERS the visible rows `firstVisibleRow ..< firstVisibleRow +
///   visibleRowCount` (clamped), so a paint never misses a visible column;
/// - a zero/negative `visibleRowCount` or empty document yields an empty range;
/// - the plan is the requested label/metadata ID set for the panel (each row is
///   its column), so requesting is O(viewport) too.
public protocol ColumnPanelLayouting: Sendable {
    func plan(for viewport: ColumnPanelViewport) -> ColumnPanelPlan
}

/// One column's search candidate: its ID and decoded source label, or `nil`
/// when the column has no effective header label (headerless / empty header),
/// in which case the searcher matches on the generic name + 1-based index.
public struct ColumnLabelCandidate: Equatable, Sendable {
    public let column: UInt32
    public let label: String?

    public init(column: UInt32, label: String?) {
        self.column = column
        self.label = label
    }
}

/// The maximum candidates a single off-main search batch scans (ARCH criterion
/// 12: "label batches of at most 1024").
public let columnLabelSearchBatchMax: Int = 1024

/// Pure column-label search (ARCH criterion 12). The off-main scheduling,
/// cancellation on query replacement / panel close, and result streaming live in
/// `LessSheetApp`; THIS owns the pure per-batch MATCH decision (deterministic,
/// unit-testable). Implemented in `LessSheetKit` (`ColumnLabelSearch`), pinned
/// by a frozen conformance test.
///
/// Pinned semantics (the spec the RED seed does NOT satisfy — the seed reports
/// `batchSize == 0` and matches nothing):
/// - `batchSize == columnLabelSearchBatchMax` (1024);
/// - `matches(query:in:locale:)` returns the matching column IDs of the batch in
///   SOURCE-COLUMN order (the candidates' given order), where a match is a
///   LOCALIZED, case-insensitive substring of the searchable text under
///   `locale`; a headered column's searchable text is its label, and a
///   header-off/empty column's is `GenericColumnName.name(at:) + " " + (1-based
///   index)` (e.g. column 26 → "AA 27");
/// - an empty query matches nothing (the panel shows its unsearched list);
/// - only IDs are returned (the caller retains IDs, never all label Strings).
public protocol ColumnLabelSearching: Sendable {
    var batchSize: Int { get }
    func matches(query: String, in candidates: [ColumnLabelCandidate], locale: Locale) -> [UInt32]
}
