// Frozen behavior tests — viewer-ui slice (planner-owned).
// The headless-gateable app criteria of ARCH-viewer-ui (contract conformance
// pins, ABI agreement, dialect state propagation, windowed session bridging,
// hidden-column model, jump/cancel view-model semantics, timing-marker rules)
// exercised against the REAL linked Zig core through the C ABI (no mocks).
//
// Determinism: every fixture is far below the core's head budget, so its
// index is complete — and the row count exact — from the moment the session
// exists (pinned in api/lesssheet.h). No polling loops are needed.
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

private func openFixture(
    _ name: String,
    forcing override: DialectOverride = .sniffAll
) async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: fixturePath(name), forcing: override)
}

// MARK: - Contract conformance pins (signature drift fails this build)

@Test func contractConformancePins() {
    let _: any DocumentSessionOpening = CoreSessionOpener()
    let _: any ColumnVisibilityManaging = ColumnVisibilityManager()
    let _: any JumpControlling = JumpControl()
    let _: any DialectComposing = DialectComposer()
}

// MARK: - ABI agreement: C header <-> Swift contract

@Test func abiStatusCodesAgreeWithTheSwiftMapping() {
    #expect(DocumentOpenError(abiCode: Int32(LS_OK.rawValue)) == nil)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_NOT_FOUND.rawValue)) == .notFound)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_PERMISSION_DENIED.rawValue)) == .permissionDenied)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_IO.rawValue)) == .io)
    #expect(DocumentOpenError(abiCode: Int32(LS_ERROR_INVALID_ARGUMENT.rawValue)) == .invalidArgument)
}

@Test func abiConstantsArePinned() {
    #expect(LS_SNIFF == -1)
    #expect(LS_QUOTE_NONE == -2)
    #expect(LS_HEADER_OFF == 0)
    #expect(LS_HEADER_ON == 1)
    #expect(LS_INDEX_AUTO == 0)
    #expect(LS_INDEX_MANUAL == 1)
    #expect(LS_OPEN_READY_MIN_ROWS == 512)
    #expect(LS_WINDOW_MAX_ROWS == 4096)
    #expect(LS_JUMP_IDLE.rawValue == 0)
    #expect(LS_JUMP_SCANNING.rawValue == 1)
    #expect(LS_JUMP_DONE.rawValue == 2)
}

@Test func dialectCandidateListsArePinned() {
    #expect(DialectCandidates.separators == [0x2C, 0x3B, 0x09, 0x7C]) // , ; TAB |
    #expect(DialectCandidates.quotes == [0x22, 0x27]) // " '
}

/// Calls the exported core symbol directly: proves the Zig static library is
/// really linked and the v2 3-argument open crosses into Swift.
@Test func rawABIRejectsAMissingPathWithNotFound() {
    var doc: OpaquePointer? = nil
    let status = ls_open("/definitely/not/here/missing.csv", nil, &doc)
    #expect(status.rawValue == LS_ERROR_NOT_FOUND.rawValue)
    #expect(doc == nil)
}

// MARK: - Windowed session: dialect report + header + exact windowed rows

@Test func sessionServesDialectHeaderAndWindowedRows() async throws {
    let session = try await openFixture("people")
    defer { session.close() }

    // Dialect state propagation: the sniffed comma/double-quote/header
    // report reaches the app exactly as the pills will render it.
    #expect(session.dialect == DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: true,
        separatorForced: false, quoteForced: false, headerForced: false
    ))
    #expect(session.columnCount == 3)
    #expect(session.headerCells == ["name", "age", "city"])

    // Tiny fixture: complete + exact immediately (pinned determinism).
    #expect(session.rowCount() == RowCountInfo(count: 2, isExact: true))
    let progress = session.indexProgress()
    #expect(progress.isComplete)
    #expect(progress.bytesTotal > 0)
    #expect(progress.bytesScanned == progress.bytesTotal)
    #expect(progress.fraction == 1)

    let window = session.setWindow(firstRow: 0, rowCount: 10)
    #expect(window.firstRow == 0)
    #expect(window.rows == [["Ada", "36", "London"], ["Bo, Jr.", "7", "São Paulo"]])

    // Beyond-EOF requests serve nothing (total, no error).
    let beyond = session.setWindow(firstRow: 100, rowCount: 10)
    #expect(beyond.rows.isEmpty)
}

@Test func sniffedSemicolonDialectIsReported() async throws {
    let session = try await openFixture("semicolon")
    defer { session.close() }
    #expect(session.dialect.separator == 0x3B) // ';'
    #expect(session.dialect.separatorForced == false)
    #expect(session.columnCount == 2)
    #expect(session.headerCells == ["name", "age"])
    #expect(session.setWindow(firstRow: 0, rowCount: 10).rows == [["Ada", "36"], ["Bo", "7"]])
}

@Test func forcedSeparatorBypassesTheSniffAndIsReportedForced() async throws {
    // Deliberately force ',' on the semicolon fixture: single column, and
    // the report carries the user-override state for the pill.
    let session = try await openFixture("semicolon", forcing: DialectOverride(separator: .forced(0x2C)))
    defer { session.close() }
    #expect(session.dialect.separator == 0x2C)
    #expect(session.dialect.separatorForced == true)
    #expect(session.columnCount == 1)
    #expect(session.headerCells == ["name;age"])
    #expect(session.setWindow(firstRow: 0, rowCount: 10).rows == [["Ada;36"], ["Bo;7"]])
}

@Test func forcedHeaderOffDemotesTheHeaderRecord() async throws {
    let session = try await openFixture("people", forcing: DialectOverride(header: .off))
    defer { session.close() }
    #expect(session.dialect.hasHeader == false)
    #expect(session.dialect.headerForced == true)
    #expect(session.headerCells == nil)
    #expect(session.rowCount() == RowCountInfo(count: 3, isExact: true))
    let window = session.setWindow(firstRow: 0, rowCount: 10)
    #expect(window.rows.first == ["name", "age", "city"])
}

@Test func allNumericFirstRecordSuggestsNoHeader() async throws {
    let session = try await openFixture("numbers")
    defer { session.close() }
    #expect(session.dialect.hasHeader == false)
    #expect(session.headerCells == nil)
    #expect(session.setWindow(firstRow: 0, rowCount: 10).rows == [["1", "2.5"], ["3", "4"]])
}

@Test func raggedRowsStayRectangularThroughTheFullStack() async throws {
    let session = try await openFixture("ragged")
    defer { session.close() }
    #expect(session.columnCount == 3)
    #expect(session.headerCells == ["a", "b", "c"])
    let rows = session.setWindow(firstRow: 0, rowCount: 10).rows
    #expect(rows == [["1", "2", ""], ["5", "6", "7"]])
    for row in rows {
        #expect(row.count == session.columnCount)
    }
}

@Test func wideDocumentsReportTheirFullColumnCount() async throws {
    let session = try await openFixture("wide28")
    defer { session.close() }
    #expect(session.columnCount == 28)
    #expect(session.headerCells == nil)
    #expect(session.setWindow(firstRow: 0, rowCount: 10).rows == [(1...28).map(String.init)])
}

@Test func invalidForcedCombinationThrowsTheDistinctUsageError() async throws {
    await #expect(throws: DocumentOpenError.invalidArgument) {
        _ = try await openFixture("people", forcing: DialectOverride(
            separator: .forced(0x3B), quote: .forced(0x3B) // forced collision
        ))
    }
}

@Test func jumpBridgeCompletesBehindTheFrontier() async throws {
    let session = try await openFixture("people")
    defer { session.close() }
    // Tiny fixture: the whole document is behind the frontier, so the jump
    // is done when startJump returns (pinned) — the bridge maps the status.
    session.startJump(to: 1)
    #expect(session.jumpStatus() == .done(landedRow: 1))
    session.cancelJump() // no-op after done
    #expect(session.jumpStatus() == .done(landedRow: 1))
}

// MARK: - Errors; empty file is not an error

@Test func abiErrorCodesMapToDistinctSwiftErrorsEndToEnd() async throws {
    let opener = CoreSessionOpener()

    await #expect(throws: DocumentOpenError.notFound) {
        _ = try await opener.open(path: "/definitely/not/here/missing.csv", forcing: .sniffAll)
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
        _ = try await opener.open(path: unreadable.path(percentEncoded: false), forcing: .sniffAll)
    }

    // A path that exists but is not a readable file (a directory) -> io.
    await #expect(throws: DocumentOpenError.io) {
        _ = try await opener.open(
            path: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            forcing: .sniffAll
        )
    }
}

@Test func emptyFileIsAnEmptySessionNotAnError() async throws {
    let session = try await openFixture("empty")
    defer { session.close() }
    #expect(session.columnCount == 0)
    #expect(session.headerCells == nil)
    #expect(session.rowCount() == RowCountInfo(count: 0, isExact: true))
    #expect(session.indexProgress().isComplete)
    #expect(session.setWindow(firstRow: 0, rowCount: 10).rows.isEmpty)
}

// MARK: - Generic column names (pinned policy in Contracts)

@Test func genericColumnNamesFollowSpreadsheetOrder() {
    #expect(GenericColumnName.name(at: 0) == "A")
    #expect(GenericColumnName.name(at: 25) == "Z")
    #expect(GenericColumnName.name(at: 26) == "AA")
    #expect(GenericColumnName.name(at: 27) == "AB")
    #expect(GenericColumnName.name(at: 51) == "AZ")
    #expect(GenericColumnName.name(at: 52) == "BA")
    #expect(GenericColumnName.name(at: 701) == "ZZ")
    #expect(GenericColumnName.name(at: 702) == "AAA")
    #expect(GenericColumnName.names(count: 3) == ["A", "B", "C"])
    #expect(GenericColumnName.names(count: 0) == [])
}

// MARK: - Hidden-column model (last-visible rule; reset on count change)

@Test func columnVisibilityFollowsThePinnedSemantics() {
    let m = ColumnVisibilityManager()

    let fresh = m.allVisible(columnCount: 3)
    #expect(fresh == ColumnVisibility(columnCount: 3, hiddenColumns: []))
    #expect(m.visibleColumns(fresh) == [0, 1, 2])
    #expect(m.canHide(fresh, column: 1))

    let one = m.toggling(fresh, column: 1) // hide 1
    #expect(one == ColumnVisibility(columnCount: 3, hiddenColumns: [1]))
    #expect(one.isHidden(1))
    #expect(m.visibleColumns(one) == [0, 2])

    let back = m.toggling(one, column: 1) // toggling a hidden column unhides
    #expect(back == fresh)

    let two = m.toggling(m.toggling(fresh, column: 0), column: 1)
    #expect(two.hiddenColumns == [0, 1])
    // Last visible column: checkbox disabled, toggle is a no-op.
    #expect(m.canHide(two, column: 2) == false)
    #expect(m.toggling(two, column: 2) == two)
    // ...but the hidden ones can still be brought back.
    #expect(m.toggling(two, column: 0).hiddenColumns == [1])

    // Out-of-range columns: no-ops.
    #expect(m.canHide(fresh, column: 5) == false)
    #expect(m.toggling(fresh, column: 5) == fresh)
    #expect(m.canHide(fresh, column: -1) == false)
    #expect(m.toggling(fresh, column: -1) == fresh)

    // Re-open survival: same column count keeps choices; a different count
    // resets to all-visible (ARCH req. 10).
    #expect(m.carriedOver(two, toColumnCount: 3) == two)
    #expect(m.carriedOver(two, toColumnCount: 4) == m.allVisible(columnCount: 4))
}

// MARK: - Jump view-model (1-based parse; cancel restores pre-jump position)

@Test func jumpTargetParsingIsOneBasedDigitsOnly64Bit() {
    let j = JumpControl()
    #expect(j.parseTarget("1") == 0)
    #expect(j.parseTarget("12") == 11)
    #expect(j.parseTarget("007") == 6) // leading zeros are digits
    #expect(j.parseTarget("18446744073709551615") == UInt64.max - 1)
    #expect(j.parseTarget("") == nil)
    #expect(j.parseTarget("0") == nil) // rows are 1-based in UI copy
    #expect(j.parseTarget("00") == nil)
    #expect(j.parseTarget("12a") == nil)
    #expect(j.parseTarget("-3") == nil)
    #expect(j.parseTarget(" 5") == nil)
    #expect(j.parseTarget("1.5") == nil)
    #expect(j.parseTarget("18446744073709551616") == nil) // > UInt64.max
}

@Test func jumpFlowScansLandsAndCancelsToThePreJumpPosition() {
    let j = JumpControl()

    let begun = j.begin(target: 100, preJumpFirstRow: 5)
    #expect(begun == .scanning(target: 100, preJumpFirstRow: 5, progress: 0))

    // Progress folds in monotonically (display never regresses).
    let p1 = j.resolve(begun, with: .scanning(progress: 0.5))
    #expect(p1 == .scanning(target: 100, preJumpFirstRow: 5, progress: 0.5))
    #expect(j.resolve(p1, with: .scanning(progress: 0.4)) == p1)

    // Completion lands on the core's (clamped) row.
    #expect(j.resolve(p1, with: .done(landedRow: 100)) == .landed(row: 100))

    // Cancel returns the viewport to the pre-jump position.
    #expect(j.cancelled(p1) == .cancelled(restoreToFirstRow: 5))

    // Non-scanning flows are stable under resolve/cancel.
    #expect(j.resolve(.idle, with: .done(landedRow: 9)) == .idle)
    #expect(j.resolve(.landed(row: 7), with: .scanning(progress: 0.2)) == .landed(row: 7))
    #expect(j.resolve(p1, with: .idle) == p1)
    #expect(j.cancelled(.idle) == .idle)
    #expect(j.cancelled(.landed(row: 3)) == .landed(row: 3))
}

// MARK: - Dialect composer (pill selection -> next open's override)

private let sniffedReport = DialectReport(
    separator: 0x2C, quote: 0x22, hasHeader: true,
    separatorForced: false, quoteForced: false, headerForced: false
)

@Test func composerForcesOnlyTheChangedParameterOnASniffedReport() {
    let c = DialectComposer()
    #expect(c.compose(from: sniffedReport, changing: .separator(0x3B))
        == DialectOverride(separator: .forced(0x3B), quote: .sniff, header: .sniff))
    #expect(c.compose(from: sniffedReport, changing: .quote(0x27))
        == DialectOverride(separator: .sniff, quote: .forced(0x27), header: .sniff))
    #expect(c.compose(from: sniffedReport, changing: .quote(nil))
        == DialectOverride(separator: .sniff, quote: .none, header: .sniff))
    #expect(c.compose(from: sniffedReport, changing: .header(false))
        == DialectOverride(separator: .sniff, quote: .sniff, header: .off))
    #expect(c.compose(from: sniffedReport, changing: .header(true))
        == DialectOverride(separator: .sniff, quote: .sniff, header: .on))
}

@Test func composerCarriesPreviouslyForcedParametersForward() {
    let c = DialectComposer()
    let carried = DialectReport(
        separator: 0x3B, quote: 0x22, hasHeader: true,
        separatorForced: true, quoteForced: false, headerForced: true
    )
    #expect(c.compose(from: carried, changing: .quote(0x27))
        == DialectOverride(separator: .forced(0x3B), quote: .forced(0x27), header: .on))

    let noneQuote = DialectReport(
        separator: 0x2C, quote: nil, hasHeader: false,
        separatorForced: false, quoteForced: true, headerForced: false
    )
    #expect(c.compose(from: noneQuote, changing: .separator(0x7C))
        == DialectOverride(separator: .forced(0x7C), quote: .none, header: .sniff))
}

@Test func composerRejectsInvalidCustomBytesAndForcedConflicts() {
    let c = DialectComposer()
    // CR/LF/NUL/non-ASCII bytes are out of domain for either parameter.
    #expect(c.compose(from: sniffedReport, changing: .separator(0x0A)) == nil)
    #expect(c.compose(from: sniffedReport, changing: .separator(0x0D)) == nil)
    #expect(c.compose(from: sniffedReport, changing: .separator(0x00)) == nil)
    #expect(c.compose(from: sniffedReport, changing: .separator(0x80)) == nil)
    #expect(c.compose(from: sniffedReport, changing: .quote(0x0A)) == nil)
    #expect(c.compose(from: sniffedReport, changing: .quote(0x00)) == nil)
    #expect(c.compose(from: sniffedReport, changing: .quote(0xFF)) == nil)

    // A byte colliding with a CARRIED FORCED value of the other parameter.
    let forcedQuote = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: true,
        separatorForced: false, quoteForced: true, headerForced: false
    )
    #expect(c.compose(from: forcedQuote, changing: .separator(0x22)) == nil)
    let forcedSep = DialectReport(
        separator: 0x3B, quote: 0x22, hasHeader: true,
        separatorForced: true, quoteForced: false, headerForced: false
    )
    #expect(c.compose(from: forcedSep, changing: .quote(0x3B)) == nil)

    // Colliding with a merely SNIFFED value is fine: the re-open re-sniffs
    // the other parameter with the forced byte excluded.
    #expect(c.compose(from: sniffedReport, changing: .separator(0x22))
        == DialectOverride(separator: .forced(0x22), quote: .sniff, header: .sniff))
}

// MARK: - Timing marker (format pinned; UNCHANGED from the walking skeleton)

@Test func timingMarkerFormatIsPinned() {
    #expect(TimingMarker.firstRowsVisiblePrefix == "lesssheet.first_rows_visible_ms=")
    #expect(TimingMarker.line(milliseconds: 123) == "lesssheet.first_rows_visible_ms=123")
    #expect(TimingMarker.line(milliseconds: 0) == "lesssheet.first_rows_visible_ms=0")
}
