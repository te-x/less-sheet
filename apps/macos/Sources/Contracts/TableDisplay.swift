/// What the table renders: sticky-header column names plus data rows. The
/// header is never a normal scrolling row — it only ever appears in
/// `columnNames`.
///
/// Invariant: every row has exactly `columnNames.count` cells (the display
/// inherits the snapshot's truncate/pad rectangularity; derivation preserves
/// it in every mode).
public struct DisplayTable: Equatable, Sendable {
    public let columnNames: [String]
    public let rows: [[String]]

    public init(columnNames: [String], rows: [[String]]) {
        self.columnNames = columnNames
        self.rows = rows
    }

    public static let empty = DisplayTable(columnNames: [], rows: [])
}

/// Pure display derivation for the document view model: (snapshot, header
/// override) -> `DisplayTable`. This is the seam behind the MANDATORY,
/// checkable "First Row Is Header" menu item: the UI stores the toggle as
/// presentation state (initialized to `snapshot.headerSuggested`) and calls
/// `derive` again whenever it flips — re-deriving the display immediately,
/// WITHOUT reopening the document or touching the core.
///
/// Pinned semantics of `derive(from:firstRowIsHeader:)`:
/// - Empty snapshot (`.empty`) -> `.empty`, for either toggle state.
/// - `headerCells != nil`, toggle ON  -> `columnNames = headerCells`,
///   `rows = snapshot.rows`.
/// - `headerCells != nil`, toggle OFF -> generic column names;
///   `rows = [headerCells] + snapshot.rows` (the file's header record is
///   demoted to the first data row).
/// - `headerCells == nil`, toggle OFF -> generic column names,
///   `rows = snapshot.rows`.
/// - `headerCells == nil`, toggle ON  -> `columnNames = snapshot.rows[0]`
///   (the user promotes data row 1 to header), `rows = remaining rows`.
///   With zero rows this is `.empty`.
/// - Generic column names are spreadsheet-style, 0-based:
///   "A"…"Z", "AA", "AB", … (bijective base-26 over A–Z), one per column
///   (`snapshot.columnCount` of them).
public protocol TableDisplayDeriving: Sendable {
    func derive(from snapshot: HeadSnapshot, firstRowIsHeader: Bool) -> DisplayTable
}
