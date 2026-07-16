// Frozen behavior test — thin-frontend-shared-core Phase 2 (planner-owned).
// ARCH-thin-frontend-shared-core Phase 2 AC1: the core's streaming-copy path
// (surfaced by `DocumentSession.openCopy` -> `ls_copy_open`/`next`/`close`)
// produces TSV BYTE-FOR-BYTE identical to the CURRENT `TSVCopyBuilder`
// (apps/macos/Sources/LessSheetKit/SelectCopyLogic.swift) — the per-cell FFI loop
// Phase 2 replaces.
//
// The `golden*` literals below are captured from the TSVCopyBuilder framing rules
// (TAB field separator, LF row separator, NO trailing separator, spreadsheet
// quoting — quote a cell containing TAB/CR/LF/quote with interior quotes doubled,
// single-cell RAW, lossless cells) applied to the find.csv / copyquote.csv fixture
// cells. They are captured NOW, so this test does NOT reference `TSVCopyBuilder` /
// `CopyBuilding` — which lets it stay green after a later change-request deletes
// them, and is exactly what makes "byte-identical to the deleted builder"
// gate-lockable. The backend `cp*` suite (backend/tests/all_tests.zig) pins the
// SAME framing against the core directly; this pins the binding + the frontend
// drive loop (chunk concat + STALLED-via-jump + progress).
//
// RED at freeze: `CoreDocumentSession` does NOT yet override `openCopy`, so the
// protocol's RED default (returns nil) answers every call — `#require(openCopy)`
// fails on nil (a BEHAVIOR red). The implementer flips it GREEN by overriding
// `openCopy` to open an `ls_copy_open` job wrapped as a `CopyStreaming`.
//
// Semantics are normative in api/lesssheet.h "STREAMING COPY EXTENSION" and
// mirrored in Sources/Contracts/StreamingCopy.swift + DocumentSession.swift.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Fixtures + driver

private func fixturePath(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture \(name).csv"
    )
    return url.path(percentEncoded: false)
}

/// Drive a WHOLE streaming copy of `rect` through the new binding: pull chunks,
/// append `bytes`, advance the frontier on `.stalled` (the fixtures here are tiny
/// / fully indexed, so this branch is never taken), until `.done`. Returns the
/// concatenated TSV bytes. `#require(openCopy)` is the RED gate at freeze.
private func streamCopyBytes(
    _ session: any DocumentSession,
    _ rect: SelectionRect,
    maxChunkBytes: Int = 1 << 16
) async throws -> [UInt8] {
    let job = try #require(
        session.openCopy(rect),
        "openCopy returned nil — RED seed (CoreDocumentSession has not wired ls_copy_* yet)"
    )
    defer { job.close() }
    var out: [UInt8] = []
    var lastRowsDone: UInt64 = 0
    var guardCount = 0
    while true {
        guardCount += 1
        try #require(guardCount < 5_000_000, "streaming copy loop runaway")
        let step = job.next(maxChunkBytes: maxChunkBytes)
        #expect(step.rowsDone >= lastRowsDone, "rows_done regressed")
        lastRowsDone = step.rowsDone
        switch step.kind {
        case .more:
            out.append(contentsOf: step.bytes)
        case .done:
            out.append(contentsOf: step.bytes)
            return out
        case .stalled:
            session.startJump(to: step.stalledRow)
            let clock = ContinuousClock()
            let start = clock.now
            while true {
                if case .done = session.jumpStatus() { break }
                try #require(clock.now - start < .seconds(10), "frontier jump timed out")
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}

// find.csv data rows (0-based), header `name,qty,note` ON — identical to the
// backend fv_fixture:
//   0: Widget | 2   | alpha needle      4: Gizmo | 1e2 | delta
//   1: NEEDLE | 10  | beta              5: café  | 0.5 | CAFÉ
//   2: needle | 2.0 | gamma             6:       | 5.  | needleneedle
//   3: gadget | -3  | Needle point      7: plain | abc | end needle
private let goldenFindFull =
    "Widget\t2\talpha needle\n" +
    "NEEDLE\t10\tbeta\n" +
    "needle\t2.0\tgamma\n" +
    "gadget\t-3\tNeedle point\n" +
    "Gizmo\t1e2\tdelta\n" +
    "café\t0.5\tCAFÉ\n" +
    "\t5.\tneedleneedle\n" +
    "plain\tabc\tend needle"

// copyquote.csv: header c1,c2 ON; row 0 col0 has a literal TAB, col1 a literal
// quote; row 1 col0 a quoted field with an embedded LF. Each special cell is
// spreadsheet-quoted on copy (interior quote doubled); the plain cell is raw.
private let goldenQuoteFull = "\"a\tb\"\t\"x\"\"y\"\n\"p\nq\"\tplain"

// MARK: - Tests

@Test func streamingCopyOfFindFixtureIsByteIdenticalToTheBuilder() async throws {
    let session = try await CoreSessionOpener().open(path: fixturePath("find"), forcing: .sniffAll)
    defer { session.close() }
    try #require(session.columnCount == 3, "find.csv has 3 columns")

    // Full 8x3 selection: byte-identical to the former TSVCopyBuilder output.
    let full = try await streamCopyBytes(session, SelectionRect(top: 0, bottom: 7, left: 0, right: 2))
    #expect(full == Array(goldenFindFull.utf8))

    // Single cell (row 3, col 2) -> RAW value, no trailing newline.
    let single = try await streamCopyBytes(session, SelectionRect(top: 3, bottom: 3, left: 2, right: 2))
    #expect(single == Array("Needle point".utf8))

    // The empty name cell inside a multi-cell row is a leading empty field.
    let emptyRow = try await streamCopyBytes(session, SelectionRect(top: 6, bottom: 6, left: 0, right: 2))
    #expect(emptyRow == Array("\t5.\tneedleneedle".utf8))

    // Column sub-window: qty column (col 1), rows 0..2 -> multi-row single column.
    let subCol = try await streamCopyBytes(session, SelectionRect(top: 0, bottom: 2, left: 1, right: 1))
    #expect(subCol == Array("2\n10\n2.0".utf8))
}

@Test func streamingCopyReproducesTheBuildersSpreadsheetQuoting() async throws {
    let session = try await CoreSessionOpener().open(path: fixturePath("copyquote"), forcing: .sniffAll)
    defer { session.close() }
    try #require(session.columnCount == 2, "copyquote.csv has 2 columns")

    // Full 2x2: each special cell quoted (interior quote doubled), plain raw.
    let full = try await streamCopyBytes(session, SelectionRect(top: 0, bottom: 1, left: 0, right: 1))
    #expect(full == Array(goldenQuoteFull.utf8))

    // The SAME tab-containing cell as a SINGLE-cell copy is RAW (never quoted).
    let single = try await streamCopyBytes(session, SelectionRect(top: 0, bottom: 0, left: 0, right: 0))
    #expect(single == Array("a\tb".utf8))
}

@Test func streamingCopyTinyChunksConcatenateToTheSameBytes() async throws {
    // AC3: a small chunk budget forces many `next` pulls whose `bytes` still
    // concatenate byte-identically to the whole payload (boundary-cut framing).
    let session = try await CoreSessionOpener().open(path: fixturePath("find"), forcing: .sniffAll)
    defer { session.close() }
    let rect = SelectionRect(top: 0, bottom: 7, left: 0, right: 2)
    let tiny = try await streamCopyBytes(session, rect, maxChunkBytes: 8)
    #expect(tiny == Array(goldenFindFull.utf8))
}
