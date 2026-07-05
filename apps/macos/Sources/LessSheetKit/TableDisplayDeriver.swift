import Contracts

/// Pure view-model derivation: (snapshot, header override) -> DisplayTable.
///
/// Implements the semantics pinned on `TableDisplayDeriving` (see
/// Sources/Contracts/TableDisplay.swift): header application, toggle
/// re-derivation without reopening, generic spreadsheet column names, and
/// rectangularity preserved in every mode.
public struct TableDisplayDeriver: TableDisplayDeriving {
    public init() {}

    public func derive(from snapshot: HeadSnapshot, firstRowIsHeader: Bool) -> DisplayTable {
        // The empty document (0 columns) is always the empty display.
        guard snapshot.columnCount > 0 else { return .empty }

        if let header = snapshot.headerCells {
            // Core suggested a header (record 1 is not all-numeric).
            if firstRowIsHeader {
                return DisplayTable(columnNames: header, rows: snapshot.rows)
            }
            // Toggle OFF: demote the file's header record to the first data row.
            return DisplayTable(
                columnNames: Self.genericNames(snapshot.columnCount),
                rows: [header] + snapshot.rows
            )
        }

        // Core suggested no header (record 1 all-numeric -> it is data row 0).
        if firstRowIsHeader {
            // User promotes data row 0 to the header.
            guard let promoted = snapshot.rows.first else { return .empty }
            return DisplayTable(columnNames: promoted, rows: Array(snapshot.rows.dropFirst()))
        }
        return DisplayTable(
            columnNames: Self.genericNames(snapshot.columnCount),
            rows: snapshot.rows
        )
    }

    /// Spreadsheet-style, 0-based bijective base-26 names: A…Z, AA, AB, …
    static func genericNames(_ count: Int) -> [String] {
        (0..<count).map(genericName)
    }

    static func genericName(_ index: Int) -> String {
        var n = index
        var scalars: [Unicode.Scalar] = []
        while true {
            let r = n % 26
            scalars.append(Unicode.Scalar(UInt8(65 + r)))
            n = n / 26 - 1
            if n < 0 { break }
        }
        return String(String.UnicodeScalarView(scalars.reversed()))
    }
}
