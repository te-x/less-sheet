/// Immutable copy of a document's loaded head window, taken at the ABI
/// boundary. All strings own their storage (the core's borrowed pointers are
/// never retained past the copy); invalid UTF-8 byte sequences have already
/// been replaced with U+FFFD at this boundary.
///
/// Invariants (established by the opener, relied on by display derivation):
/// - `headerCells` is non-nil exactly when the core suggested a header
///   (`ls_header_suggested`); when non-nil it has exactly `columnCount` cells.
/// - Every row in `rows` has exactly `columnCount` cells (the core's
///   truncate/pad rule is already applied).
/// - `rows` holds at most LS_HEAD_MAX_DATA_ROWS (200) data rows, in view
///   order (today: the identity view — file order).
/// - The empty document (empty file) is `HeadSnapshot.empty`: no header,
///   no rows, zero columns.
public struct HeadSnapshot: Equatable, Sendable {
    /// The suggested header record's cells, or nil when the core suggests
    /// "no header" (row 1 all numeric) — including for the empty document.
    public let headerCells: [String]?
    /// The loaded data rows (header excluded), each exactly `columnCount` wide.
    public let rows: [[String]]
    /// The document's column count (field count of record 1; 0 when empty).
    public let columnCount: Int

    /// The core's header suggestion, as a fact about this snapshot.
    public var headerSuggested: Bool { headerCells != nil }

    public init(headerCells: [String]?, rows: [[String]], columnCount: Int) {
        self.headerCells = headerCells
        self.rows = rows
        self.columnCount = columnCount
    }

    /// The snapshot of an empty (0-byte or BOM-only) document.
    public static let empty = HeadSnapshot(headerCells: nil, rows: [], columnCount: 0)
}
