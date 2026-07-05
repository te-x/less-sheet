import CLessSheet
import Contracts

/// Swift wrapper over the core C ABI (`api/lesssheet.h` via CLessSheet).
///
/// Opens through `ls_open`, copies the loaded head (dimensions, header
/// suggestion, borrowed cell text) into an immutable `HeadSnapshot`, then
/// `ls_close`s before returning — no core storage outlives the call. Invalid
/// UTF-8 bytes are replaced with U+FFFD at this boundary (`String(decoding:)`).
/// `ls_open` failures map through `DocumentOpenError(abiCode:)`.
///
/// `openHead` is `nonisolated async`: its body runs off the main actor, so the
/// main thread is never blocked (head-only reads make it near-instant anyway).
public struct CoreDocumentOpener: DocumentOpening {
    public init() {}

    public func openHead(path: String) async throws(DocumentOpenError) -> HeadSnapshot {
        try Self.load(path: path)
    }

    static func load(path: String) throws(DocumentOpenError) -> HeadSnapshot {
        var handle: OpaquePointer?
        let status = path.withCString { ls_open($0, &handle) }
        if let error = DocumentOpenError(abiCode: Int32(status.rawValue)) {
            throw error
        }
        // LS_OK. A successful open always yields a non-NULL handle; guard anyway.
        guard let doc = handle else { return .empty }
        defer { ls_close(doc) }

        let columnCount = Int(ls_column_count(doc))
        let dataRowCount = Int(ls_data_row_count(doc))

        var headerCells: [String]?
        if ls_header_suggested(doc) {
            var header = [String]()
            header.reserveCapacity(columnCount)
            for col in 0..<columnCount {
                header.append(Self.copyCell(ls_header_cell(doc, UInt32(col))))
            }
            headerCells = header
        }

        var rows = [[String]]()
        rows.reserveCapacity(dataRowCount)
        for row in 0..<dataRowCount {
            var cells = [String]()
            cells.reserveCapacity(columnCount)
            for col in 0..<columnCount {
                cells.append(Self.copyCell(ls_cell(doc, UInt32(row), UInt32(col))))
            }
            rows.append(cells)
        }

        return HeadSnapshot(headerCells: headerCells, rows: rows, columnCount: columnCount)
    }

    /// Copies borrowed UTF-8 bytes into an owned String, replacing invalid
    /// sequences with U+FFFD. The empty borrow (`len == 0`) copies to "".
    private static func copyCell(_ str: ls_str) -> String {
        guard str.len > 0, let ptr = str.ptr else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: str.len), as: UTF8.self)
    }
}
