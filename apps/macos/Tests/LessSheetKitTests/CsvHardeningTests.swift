// Frozen behavior tests — csv-hardening slice (planner-owned).
// ARCH-csv-hardening app criteria 18-20 (the "Text encoding" picker view-model,
// the encoding re-open path, and the per-cell truncation indicator's data), plus
// the frontend-observable slices of the encoding + display-cap behavior verified
// against the REAL linked Zig core through the C ABI (no mocks). The core's own
// detection/transcode/cap semantics (criteria 1-17) are pinned in the backend
// suite; here we pin what the app sees: the reported encoding, the picker
// composition/surfacing, and the RowWindow truncation flag (with the full cell
// still searchable). Normative text: Sources/Contracts/{Dialect,DocumentSession,
// FindControl}.swift and api/lesssheet.h.
//
// Determinism: every fixture is far below the core's head budget, so its index
// is complete (row counts exact) and match scans finish in milliseconds; poll
// loops are bounded (10 s) and assert startSearch == true before polling.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers

/// Write exact bytes to a fresh temp .csv (encoding fixtures carry non-UTF-8
/// bytes, so they are generated rather than checked in) and return its path.
private func writeTempCSV(_ bytes: [UInt8]) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lesssheet-csvhard-\(UUID().uuidString).csv")
    try Data(bytes).write(to: url)
    return url.path(percentEncoded: false)
}

private func openBytes(
    _ bytes: [UInt8],
    forcing override: DialectOverride = .sniffAll
) async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: try writeTempCSV(bytes), forcing: override)
}

/// UTF-16 bytes of `s` in the given endianness, with an optional matching BOM.
private func utf16Bytes(_ s: String, littleEndian: Bool, bom: Bool) -> [UInt8] {
    var out: [UInt8] = []
    if bom { out += littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF] }
    for unit in s.utf16 {
        let hi = UInt8(unit >> 8)
        let lo = UInt8(unit & 0xFF)
        out += littleEndian ? [lo, hi] : [hi, lo]
    }
    return out
}

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Poll the session's search status until `predicate` holds (<= 10 s).
private func waitSearch(
    _ session: any DocumentSession,
    until predicate: (SearchSnapshot) -> Bool
) async throws -> SearchSnapshot {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if let snap = session.searchStatus(), predicate(snap) { return snap }
        try #require(clock.now - start < .seconds(10), "search poll timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Run `request` to completion and walk every match forward from the top.
private func matchedRows(_ session: any DocumentSession, _ request: SearchRequest) async throws -> Set<UInt64> {
    try #require(session.startSearch(request), "core rejected \(request)")
    _ = try await waitSearch(session) { $0.totalIsFinal }
    var rows: Set<UInt64> = []
    var anchor: UInt64 = 0
    for _ in 0..<64 {
        session.navigateSearch(SearchNav(anchor: anchor, direction: .forward))
        guard let snap = session.searchStatus() else { break }
        guard case let .found(match, _) = snap.nav else { break }
        rows.insert(match.row)
        anchor = match.row + 1
    }
    return rows
}

// MARK: - ABI agreement: C header <-> Swift contract (regression guard)

@Test func csvHardeningABIConstantsArePinned() {
    #expect(LS_ENCODING_AUTO == -1)
    #expect(LS_ENCODING_UTF8 == 0)
    #expect(LS_ENCODING_UTF16LE == 1)
    #expect(LS_ENCODING_UTF16BE == 2)
    #expect(LS_ENCODING_LATIN1 == 3)
    #expect(LS_ENCODING_WINDOWS1252 == 4)
    #expect(LS_CELL_MAX_BYTES == 4096)
    // The Swift TextEncoding rawValues mirror the concrete ABI encoding values.
    #expect(TextEncoding.utf8.rawValue == UInt8(LS_ENCODING_UTF8))
    #expect(TextEncoding.utf16LE.rawValue == UInt8(LS_ENCODING_UTF16LE))
    #expect(TextEncoding.utf16BE.rawValue == UInt8(LS_ENCODING_UTF16BE))
    #expect(TextEncoding.latin1.rawValue == UInt8(LS_ENCODING_LATIN1))
    #expect(TextEncoding.windows1252.rawValue == UInt8(LS_ENCODING_WINDOWS1252))
}

// MARK: - The encoding picker view-model (criterion 18) — pure

@Test func encodingPickerOptionsAndSurfacing() {
    // The picker offers Automatic + the five encodings, in order.
    #expect(EncodingPicker.options == [.automatic, .utf8, .utf16LE, .utf16BE, .latin1, .windows1252])
    #expect(EncodingOverride.allCases == [.automatic, .utf8, .utf16LE, .utf16BE, .latin1, .windows1252])
    #expect(TextEncoding.allCases == [.utf8, .utf16LE, .utf16BE, .latin1, .windows1252])

    // Automatic mode: the selection is .automatic; the detected value is surfaced.
    let detected = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: true,
        separatorForced: false, quoteForced: false, headerForced: false,
        encoding: .latin1, encodingForced: false
    )
    #expect(EncodingPicker.selection(for: detected) == .automatic)
    #expect(EncodingPicker.detected(in: detected) == .latin1)

    // Forced mode: the selection echoes the forced encoding.
    let forced = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: true,
        separatorForced: false, quoteForced: false, headerForced: false,
        encoding: .utf16BE, encodingForced: true
    )
    #expect(EncodingPicker.selection(for: forced) == .utf16BE)
    #expect(EncodingPicker.detected(in: forced) == .utf16BE)
    // EncodingOverride(TextEncoding) maps a resolved encoding to its forced option.
    #expect(EncodingOverride(.windows1252) == .windows1252)
}

// MARK: - The encoding re-open composition (criterion 19) — pure

@Test func composerRoutesEncodingLikeADialectChange() {
    let c = DialectComposer()
    let sniffed = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: true,
        separatorForced: false, quoteForced: false, headerForced: false,
        encoding: .utf8, encodingForced: false
    )
    // Choosing an encoding forces it; the sniffed dialect params stay .sniff.
    #expect(c.compose(from: sniffed, changing: .encoding(.latin1))
        == DialectOverride(separator: .sniff, quote: .sniff, header: .sniff, encoding: .latin1))

    let forcedLatin = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: true,
        separatorForced: false, quoteForced: false, headerForced: false,
        encoding: .latin1, encodingForced: true
    )
    // Choosing Automatic re-detects on the re-open.
    #expect(c.compose(from: forcedLatin, changing: .encoding(.automatic))
        == DialectOverride(separator: .sniff, quote: .sniff, header: .sniff, encoding: .automatic))
    // A dialect-parameter change carries the forced encoding FORWARD.
    #expect(c.compose(from: forcedLatin, changing: .separator(0x3B))
        == DialectOverride(separator: .forced(0x3B), quote: .sniff, header: .sniff, encoding: .latin1))

    // Forced dialect params carry forward under an encoding change (criterion 19).
    let forcedSep = DialectReport(
        separator: 0x3B, quote: 0x22, hasHeader: true,
        separatorForced: true, quoteForced: false, headerForced: true,
        encoding: .utf8, encodingForced: false
    )
    #expect(c.compose(from: forcedSep, changing: .encoding(.windows1252))
        == DialectOverride(separator: .forced(0x3B), quote: .sniff, header: .forcedOn, encoding: .windows1252))
}

// MARK: - Bridge: the reported encoding + picker surfacing (criteria 1-4, 18)

@Test func bridgeReportsAndSurfacesTheDetectedEncoding() async throws {
    // UTF-16LE with BOM: cells transcode to UTF-8, BOM absent, report UTF-16 LE.
    let le = try await openBytes(utf16Bytes("name,city\nJosé,42\n", littleEndian: true, bom: true))
    defer { le.close() }
    #expect(le.dialect.encoding == .utf16LE)
    #expect(le.dialect.encodingForced == false)
    #expect(le.headerCells == ["name", "city"])
    #expect(le.setWindow(firstRow: 0, rowCount: 10).rows == [["José", "42"]])
    #expect(EncodingPicker.selection(for: le.dialect) == .automatic) // Automatic mode
    #expect(EncodingPicker.detected(in: le.dialect) == .utf16LE)     // surfaced value

    // UTF-16BE with BOM.
    let be = try await openBytes(utf16Bytes("name,city\nJosé,42\n", littleEndian: false, bom: true))
    defer { be.close() }
    #expect(be.dialect.encoding == .utf16BE)
    #expect(be.setWindow(firstRow: 0, rowCount: 10).rows == [["José", "42"]])

    // BOM-less UTF-16LE (ASCII) via the NUL-ratio heuristic.
    let bomless = try await openBytes(utf16Bytes("id,name\n1,Ada\n2,Bo\n", littleEndian: true, bom: false))
    defer { bomless.close() }
    #expect(bomless.dialect.encoding == .utf16LE)
    #expect(bomless.setWindow(firstRow: 0, rowCount: 10).rows == [["1", "Ada"], ["2", "Bo"]])

    // Latin-1 auto-detected.
    let latin = try await openBytes(bytes("name,note\nAda,caf") + [0xE9] + bytes("\n"))
    defer { latin.close() }
    #expect(latin.dialect.encoding == .latin1)
    #expect(latin.dialect.encodingForced == false)
    #expect(latin.setWindow(firstRow: 0, rowCount: 10).rows == [["Ada", "café"]])

    // UTF-8 pass-through.
    let u8 = try await openBytes(bytes("name,city\nJosé,42\n"))
    defer { u8.close() }
    #expect(u8.dialect.encoding == .utf8)
    #expect(u8.dialect.encodingForced == false)
}

// MARK: - Bridge: forced encoding bypasses detection (criteria 6, 10)

@Test func bridgeForcedEncodingBypassesDetection() async throws {
    // Windows-1252 forced: 0x93/0x94 render as curly quotes; reported forced.
    let w1252 = try await openBytes(
        bytes("a,b\n") + [0x93] + bytes("q") + [0x94] + bytes(",x\n"),
        forcing: DialectOverride(encoding: .windows1252)
    )
    defer { w1252.close() }
    #expect(w1252.dialect.encoding == .windows1252)
    #expect(w1252.dialect.encodingForced == true)
    #expect(w1252.setWindow(firstRow: 0, rowCount: 10).rows.first?.first == "\u{201C}q\u{201D}")

    // Forced UTF-16 LE WITHOUT a BOM decodes correctly (criterion 10).
    let noBom = try await openBytes(
        utf16Bytes("a,b\nJosé,x\n", littleEndian: true, bom: false),
        forcing: DialectOverride(encoding: .utf16LE)
    )
    defer { noBom.close() }
    #expect(noBom.dialect.encoding == .utf16LE)
    #expect(noBom.dialect.encodingForced == true)
    #expect(noBom.setWindow(firstRow: 0, rowCount: 10).rows == [["José", "x"]])
    #expect(EncodingPicker.selection(for: noBom.dialect) == .utf16LE)
}

// MARK: - Bridge: the per-cell truncation flag (criteria 13, 20)

@Test func bridgeSurfacesPerCellTruncationFlag() async throws {
    var fixture = bytes("h\n")
    fixture += Array(repeating: UInt8(ascii: "a"), count: 5000) // one > 4 KiB cell
    fixture += bytes("\nsmall\n")
    let session = try await openBytes(fixture)
    defer { session.close() }
    let window = session.setWindow(firstRow: 0, rowCount: 10)
    #expect(window.rows.count == 2)
    #expect(window.truncated.count == window.rows.count)           // parallel shape
    #expect(window.truncated[0].count == window.rows[0].count)
    // The oversized cell is display-capped and flagged.
    #expect(window.rows[0][0].utf8.count <= Int(LS_CELL_MAX_BYTES))
    #expect(window.truncated[0][0] == true)
    // The small cell is served whole and unflagged.
    #expect(window.rows[1][0] == "small")
    #expect(window.truncated[1][0] == false)
}

// MARK: - Bridge: the display cap is display-only — the full cell is searchable
// (criteria 15, 20: the hidden tail remains searchable)

@Test func bridgeSearchesTheFullCellPastTheDisplayCap() async throws {
    var fixture = bytes("h\n")
    fixture += Array(repeating: UInt8(ascii: "a"), count: 5000)
    fixture += bytes("NEEDLE\n") // the only match, past the 4 KiB display cap
    let session = try await openBytes(fixture)
    defer { session.close() }
    // The match is found even though it lives past the served display bytes.
    #expect(try await matchedRows(session, .text(query: "NEEDLE", scope: nil, caseSensitive: false)) == [0])
    // ...and that served cell is capped + flagged (display-only).
    let window = session.setWindow(firstRow: 0, rowCount: 10)
    #expect(window.rows[0][0].utf8.count <= Int(LS_CELL_MAX_BYTES))
    #expect(window.truncated[0][0] == true)
}
