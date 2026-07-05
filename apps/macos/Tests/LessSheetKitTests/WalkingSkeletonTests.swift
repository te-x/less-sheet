// Frozen behavior tests — walking-skeleton slice (planner-owned).
// Criteria 12–15 of ARCH-walking-skeleton, exercised against the REAL linked
// Zig core through the C ABI (no mocks), plus the contract conformance pins.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers

private func fixturePath(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture \(name).csv"
    )
    return url.path(percentEncoded: false)
}

// MARK: - Contract conformance pins (signature drift fails this build)

@Test func contractConformancePins() {
    let _: any DocumentOpening = CoreDocumentOpener()
    let _: any TableDisplayDeriving = TableDisplayDeriver()
}

// MARK: - ABI agreement: C header <-> Swift contract

@Test func abiStatusCodesAgreeWithTheSwiftMapping() {
    #expect(DocumentOpenError(abiCode: Int32(LS_OK.rawValue)) == nil)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_NOT_FOUND.rawValue)) == .notFound)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_PERMISSION_DENIED.rawValue)) == .permissionDenied)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_IO.rawValue)) == .io)
    #expect(LS_HEAD_MAX_DATA_ROWS == 200)
}

/// Calls the exported core symbol directly: proves the Zig static library is
/// really linked and the C calling convention crosses into Swift.
@Test func rawABIRejectsAMissingPathWithNotFound() {
    var doc: OpaquePointer? = nil
    let status = ls_open("/definitely/not/here/missing.csv", &doc)
    #expect(status.rawValue == LS_ERROR_NOT_FOUND.rawValue)
    #expect(doc == nil)
}

// MARK: - Criterion 12: header + first rows, cell-exact

@Test func openingAFixtureYieldsHeaderAndFirstRowsExactly() async throws {
    let snap = try await CoreDocumentOpener().openHead(path: fixturePath("people"))
    #expect(snap.headerSuggested)
    #expect(snap.headerCells == ["name", "age", "city"])
    #expect(snap.columnCount == 3)
    #expect(snap.rows == [["Ada", "36", "London"], ["Bo, Jr.", "7", "São Paulo"]])
}

// MARK: - Criterion 13: header toggle re-derives without reopening

@Test func headerToggleRederivesFromTheSameSnapshotWithoutReopen() async throws {
    let snap = try await CoreDocumentOpener().openHead(path: fixturePath("numbers"))
    // all-numeric row 1 -> the core suggests "no header"
    #expect(snap.headerSuggested == false)
    #expect(snap.headerCells == nil)

    let deriver = TableDisplayDeriver()
    let suggested = deriver.derive(from: snap, firstRowIsHeader: false)
    #expect(suggested.columnNames == ["A", "B"])
    #expect(suggested.rows == [["1", "2.5"], ["3", "4"]])

    // Forcing the toggle ON re-derives columns from row 1 out of the SAME
    // snapshot — view-model state only, no reopen.
    let forced = deriver.derive(from: snap, firstRowIsHeader: true)
    #expect(forced.columnNames == ["1", "2.5"])
    #expect(forced.rows == [["3", "4"]])
}

// MARK: - Criterion 14: generic column names A…Z, AA, AB

@Test func genericColumnNamesFollowSpreadsheetOrder() async throws {
    let snap = try await CoreDocumentOpener().openHead(path: fixturePath("wide28"))
    #expect(snap.headerSuggested == false)
    #expect(snap.columnCount == 28)
    let display = TableDisplayDeriver().derive(from: snap, firstRowIsHeader: false)
    let expected = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
        "AA", "AB",
    ]
    #expect(display.columnNames == expected)
    #expect(display.rows == [(1...28).map(String.init)])
}

// MARK: - Criterion 15: distinct errors; empty file is not an error

@Test func abiErrorCodesMapToDistinctSwiftErrorsEndToEnd() async throws {
    let opener = CoreDocumentOpener()

    await #expect(throws: DocumentOpenError.notFound) {
        _ = try await opener.openHead(path: "/definitely/not/here/missing.csv")
    }

    // An existing file this process may not read -> permissionDenied.
    let unreadable = FileManager.default.temporaryDirectory
        .appendingPathComponent("lesssheet-unreadable-\(UUID().uuidString).csv")
    let created = FileManager.default.createFile(
        atPath: unreadable.path(percentEncoded: false),
        contents: Data("secret\n".utf8),
        attributes: [.posixPermissions: 0o000]
    )
    #expect(created)
    defer { try? FileManager.default.removeItem(at: unreadable) }
    await #expect(throws: DocumentOpenError.permissionDenied) {
        _ = try await opener.openHead(path: unreadable.path(percentEncoded: false))
    }

    // A path that exists but is not a readable file (a directory) -> io.
    await #expect(throws: DocumentOpenError.io) {
        _ = try await opener.openHead(path: FileManager.default.temporaryDirectory.path(percentEncoded: false))
    }
}

@Test func emptyFileIsAnEmptyTableStateNotAnError() async throws {
    let snap = try await CoreDocumentOpener().openHead(path: fixturePath("empty"))
    #expect(snap == .empty)
    #expect(snap.headerCells == nil)
    #expect(snap.rows.isEmpty)
    #expect(snap.columnCount == 0)
}

// MARK: - Truncate/pad display rule + toggle edge cases

@Test func raggedRowsStayRectangularThroughTheFullStack() async throws {
    let snap = try await CoreDocumentOpener().openHead(path: fixturePath("ragged"))
    #expect(snap.headerCells == ["a", "b", "c"])
    #expect(snap.columnCount == 3)
    #expect(snap.rows == [["1", "2", ""], ["5", "6", "7"]])

    let deriver = TableDisplayDeriver()
    // Toggle ON (the suggestion): header in the sticky slot, rows unchanged.
    let on = deriver.derive(from: snap, firstRowIsHeader: true)
    #expect(on.columnNames == ["a", "b", "c"])
    #expect(on.rows == snap.rows)
    // Toggle OFF: the file's header record is demoted to data row 0 and
    // generic names take the sticky slot; everything stays 3 cells wide.
    let off = deriver.derive(from: snap, firstRowIsHeader: false)
    #expect(off.columnNames == ["A", "B", "C"])
    #expect(off.rows == [["a", "b", "c"], ["1", "2", ""], ["5", "6", "7"]])
    for row in on.rows + off.rows {
        #expect(row.count == 3)
    }
    // The empty snapshot derives the empty display for either toggle state.
    #expect(deriver.derive(from: .empty, firstRowIsHeader: true) == .empty)
    #expect(deriver.derive(from: .empty, firstRowIsHeader: false) == .empty)
}

// MARK: - Timing marker (functional req. 7 — format pinned in the contract)

@Test func timingMarkerFormatIsPinned() {
    #expect(TimingMarker.firstRowsVisiblePrefix == "lesssheet.first_rows_visible_ms=")
    #expect(TimingMarker.line(milliseconds: 123) == "lesssheet.first_rows_visible_ms=123")
    #expect(TimingMarker.line(milliseconds: 0) == "lesssheet.first_rows_visible_ms=0")
}
