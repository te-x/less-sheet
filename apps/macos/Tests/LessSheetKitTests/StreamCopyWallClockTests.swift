// Frozen behavior test — stream-copy slice (planner-owned), the END-TO-END COPY
// WALL-CLOCK probe (ARCH-stream-copy AC7, GATING). The real-core half: it opens
// a real document and copies its WHOLE selection through the REAL
// TSVCopyBuilder + copyCell + ls_cell_copy (no mocks), exactly like
// CellCopyBridgeTests, and asserts the copy finishes under a deliberately
// GENEROUS ceiling.
//
// EXPECTED RED IN THIS CELL UNTIL THE BACKEND CURSOR LANDS. This links the real
// core, and today ls_cell_copy locates every cell FROM SCRATCH — a full 100k x
// 10 (1,000,000-cell) copy is ~140 s. So this is RED in the frontend cell and
// goes GREEN only once the backend COPY CURSOR (the sibling backend cell — the
// backend∥frontend split, ARCH "Isolation note") makes ls_cell_copy O(rows).
// It is LISTED, not chased, pre-integration. A fail-fast deadline (2x the
// ceiling) inside the fetch keeps a RED gate iteration cheap (~10 s, not ~140 s)
// by stopping the build at a row boundary; the GREEN cursor path finishes far
// under the ceiling and never trips it.
//
// The ceiling is 5 s — deliberately generous (ARCH: expected sub-second-to-low-
// seconds; ~28x headroom over the ~140 s today) so machine load cannot false-
// fail. On GREEN the assembled .app is reassembled so select-copy finally SHIPS
// (ARCH AC7) — that + the release-mode measure on a bigger selection are the
// reviewer's run; this gate pins the same bound in debug on a generated fixture.
//
// Determinism: the ~8 MB fixture is generated per run into the temp dir (like
// CellCopyBridgeTests); AUTO indexing advances the frontier to EOF and the test
// waits for the exact row count before copying, so no row is `.pending` except
// via the fail-fast deadline.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

private func makeWideTallCSV(rows: Int, cols: Int) throws -> String {
    var s = ""
    s.reserveCapacity(rows * cols * 8 + 64)
    s += (0..<cols).map { "c\($0)" }.joined(separator: ",")   // texty header -> `rows` DATA rows
    s += "\n"
    for r in 0..<rows {
        for c in 0..<cols {
            if c > 0 { s += "," }
            s += "\(r)_\(c)"
        }
        s += "\n"
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lesssheet-streamcopy-\(UUID().uuidString).csv")
    try Data(s.utf8).write(to: url)
    return url.path(percentEncoded: false)
}

private func waitForExactRowCount(_ session: any DocumentSession, timeout: Duration) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if session.rowCount().isExact { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("stream-copy wall-clock (real core)", .serialized)
struct StreamCopyWallClockTests {

    @Test func fullSelectionCopyOfHundredKRowsIsUnderCeiling() async throws {
        let rows = 100_000
        let cols = 10
        let path = try makeWideTallCSV(rows: rows, cols: cols)
        let session = try await CoreSessionOpener().open(path: path, forcing: .sniffAll)
        defer { session.close() }
        #expect(session.columnCount == cols)

        // Cover the whole document so every selected row is servable (AUTO
        // indexes to EOF); only the fail-fast deadline may then yield `.pending`.
        try await waitForExactRowCount(session, timeout: .seconds(30))
        let rc = session.rowCount()
        #expect(rc.isExact)
        #expect(rc.count == UInt64(rows))

        let ceiling = Duration.seconds(5)    // GATING; generous (see file header)
        let failFast = Duration.seconds(10)  // bounds a RED (from-scratch) iteration
        let budget = CopyBudget.standard
        let rect = SelectionRect(top: 0, bottom: UInt64(rows - 1), left: 0, right: cols - 1)

        let start = ContinuousClock.now
        let deadline = start + failFast
        // REAL end-to-end fetch: TSVCopyBuilder -> this closure -> copyCell ->
        // ls_cell_copy. The ONLY wrapper is the fail-fast deadline (returns
        // `.pending`, stopping the build at a row boundary) so a RED gate does not
        // sit for the ~140 s a from-scratch copy of 1,000,000 cells takes today.
        let fetch: CopyCellFetch = { row, col in
            if ContinuousClock.now >= deadline {
                return CopiedCell(status: .pending, text: "", truncated: false)
            }
            return session.copyCell(row: row, column: col, maxBytes: budget.perCellMaxBytes)
        }
        let report = await Task.detached { TSVCopyBuilder().build(rect, budget: budget, fetch: fetch) }.value
        let elapsed = ContinuousClock.now - start

        // GREEN once the backend cursor makes ls_cell_copy O(rows): the whole rect
        // completes well under the 5 s ceiling. RED today (from-scratch): the
        // deadline trips (outcome != .complete) and elapsed blows the ceiling.
        #expect(
            report.outcome == .complete,
            "copy did not finish within \(failFast) — likely the from-scratch (pre-cursor) path; outcome \(report.outcome), rows \(report.rowCount)"
        )
        #expect(elapsed < ceiling, "100k x 10 full-selection copy took \(elapsed); GATING ceiling \(ceiling)")
    }
}
