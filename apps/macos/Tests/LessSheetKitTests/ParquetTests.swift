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
