import Contracts
import Foundation
import LessSheetKit
import Testing

private func parquetFixture(_ name: String) -> String {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("backend/tests/fixtures/parquet/\(name).parquet").path
}

@Test func parquetSessionSchemaAndProjectedWindows() async throws {
    let session = try await CoreSessionOpener().open(
        path: parquetFixture("snappy-v2"), forcing: .sniffAll)
    defer { session.close() }
    #expect(session.isParquet)
    #expect(session.columnCount == 8)
    #expect(session.rowCount() == RowCountInfo(count: 8, isExact: true))
    #expect(session.headerCells?[1] == "name")
    let window = session.setWindow(firstRow: 6, rowCount: 2, columns: 1..<2)
    #expect(window.firstColumn == 1)
    #expect(window.rows == [["東京"], ["last"]])
    #expect(!session.readFailed)
}

@Test func emptyParquetPreservesSchema() async throws {
    let session = try await CoreSessionOpener().open(
        path: parquetFixture("empty"), forcing: .sniffAll)
    defer { session.close() }
    #expect(session.isParquet)
    #expect(session.columnCount == 1)
    #expect(session.headerCells == ["x"])
    #expect(session.rowCount() == RowCountInfo(count: 0, isExact: true))
}

@Test func parquetFooterInspectionCopiesSchemaAndGroups() async throws {
    let session = try await CoreSessionOpener().open(
        path: parquetFixture("snappy-v2"), forcing: .sniffAll)
    let info = try #require(session.parquetFileInfo())
    #expect(info.rows == 8 && info.columns == 8 && info.rowGroups == 2)
    #expect(info.compression == "Snappy")
    #expect(info.writer.contains("parquet"))
    let column = try #require(session.parquetSchemaColumn(6))
    #expect(column.name == "amount")
    #expect(column.type == "FIXED_LEN_BYTE_ARRAY · Decimal(20, 4) · Nullable")
    let group = try #require(session.parquetRowGroup(1))
    #expect(group.firstRow == 4 && group.rows == 4)
    #expect(group.compressedBytes > 0 && group.uncompressedBytes > 0)
    #expect(session.parquetSchemaColumn(-1) == nil)
    #expect(session.parquetSchemaColumn(8) == nil)
    #expect(session.parquetRowGroup(.max) == nil)
    session.close()
    #expect(session.parquetFileInfo() == nil)
    #expect(column.name == "amount") // Copied strings survive close.
}
