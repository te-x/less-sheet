// Frozen behavior test — thin-frontend-shared-core Phase 2 (planner-owned), the
// END-TO-END STREAMING-COPY WALL-CLOCK probe (GATING). The real-core half: it
// opens a real ~100k-row document and copies its WHOLE selection through the
// STREAMING path — DocumentSession.openCopy -> ls_copy_open / ls_copy_next /
// ls_copy_close, the SAME binding the product drives (ViewerModel.copySelection
// -> streamCopy -> openCopy), no mocks and NO TSVCopyBuilder / per-cell
// ls_cell_copy loop — and asserts it finishes under a deliberately GENEROUS
// ceiling. This gate-locks the ~80 s (per-cell, locate-from-scratch) -> O(rows)
// cursor win on the SHIPPING path.
//
// WHY DRIVE openCopy DIRECTLY + CROSS THE FRONTIER. This locks what the tiny
// StreamingCopyBridgeTests cannot: the wall-clock over a real 100k-row sweep AND
// the STALLED -> jump -> resume orchestration (their fixtures are fully indexed,
// so that branch never runs at runtime). We DELIBERATELY do NOT wait for the AUTO
// scan frontier to reach EOF before copying, so the whole-document selection
// extends PAST the lagging frontier: the stream returns .stalled, the drive
// advances the frontier (startJump(to:), awaiting the jump) and resumes,
// repeatedly, until .done. IDENTITY VIEW (no filter): step.stalledRow is both the
// view and the original row — the correct-as-written jump target — so this is
// unaffected by the filtered-stall implementation finding fixed separately. The
// streaming OUTCOME is asserted deterministically (every row emitted, not budget-
// capped, under the ceiling); the stall path is exercised whenever the frontier
// lags (which it does at open) rather than asserted, so a fast indexer that
// happens to outrun the sweep cannot false-fail the gate.
//
// The ceiling is 5 s — deliberately generous (ARCH: expected sub-second-to-low-
// seconds; ~28x headroom over the ~80 s per-cell path) so machine load cannot
// false-fail. A failFast wall-clock bound (2x the ceiling) breaks a hung or
// regressed drive cheaply instead of hanging the gate.
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

@Suite("stream-copy wall-clock (real core)", .serialized)
struct StreamCopyWallClockTests {

    @Test func fullSelectionStreamingCopyOfHundredKRowsIsUnderCeiling() async throws {
        let rows = 100_000
        let cols = 10
        let path = try makeWideTallCSV(rows: rows, cols: cols)
        let session = try await CoreSessionOpener().open(path: path, forcing: .sniffAll)
        defer { session.close() }
        #expect(session.columnCount == cols)

        let ceiling = Duration.seconds(5)     // GATING; generous (see file header)
        let failFast = Duration.seconds(10)   // bounds a hung / regressed iteration
        let rect = SelectionRect(top: 0, bottom: UInt64(rows - 1), left: 0, right: cols - 1)

        // Copy IMMEDIATELY — do NOT wait for AUTO indexing to reach EOF, so the
        // whole-document selection crosses the lagging scan frontier and the stream
        // must STALL, jump, and resume (identity view: stalledRow is the ORIGINAL
        // row, the correct-as-written jump target).
        let start = ContinuousClock.now
        let deadline = start + failFast

        let job = try #require(
            session.openCopy(rect),
            "openCopy returned nil — the streaming copy binding is not wired"
        )
        defer { job.close() }

        var payloadBytes = 0
        var rowsDone: UInt64 = 0
        var lastRowsDone: UInt64 = 0
        var budgetCapped = false
        var stalls = 0
        var finished = false
        var guardCount = 0

        drive: while ContinuousClock.now < deadline {
            guardCount += 1
            try #require(guardCount < 5_000_000, "streaming copy loop runaway")
            let step = job.next(maxChunkBytes: 1 << 16)
            #expect(step.rowsDone >= lastRowsDone, "rows_done regressed")
            lastRowsDone = step.rowsDone
            switch step.kind {
            case .more:
                payloadBytes += step.bytes.count
            case .done:
                payloadBytes += step.bytes.count
                rowsDone = step.rowsDone
                budgetCapped = step.budgetCapped
                finished = true
                break drive
            case .stalled:
                stalls += 1
                session.startJump(to: step.stalledRow)
                while true {
                    if case .done = session.jumpStatus() { break }
                    try #require(ContinuousClock.now < deadline, "frontier jump timed out")
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let elapsed = ContinuousClock.now - start

        // GREEN: the streaming path completes the WHOLE 100k-row selection —
        // crossing the frontier via jump/resume — well under the 5 s ceiling (the
        // O(rows) cursor win vs the ~80 s per-cell path). RED (regressed / hung):
        // failFast breaks the drive with finished == false, or elapsed blows it.
        #expect(
            finished,
            "streaming copy did not reach .done within \(failFast) — regressed or stalling drive (rowsDone \(rowsDone), stalls \(stalls))"
        )
        #expect(rowsDone == UInt64(rows), "streaming copy emitted \(rowsDone) of \(rows) rows")
        #expect(budgetCapped == false, "1M cells is well under the 10M LS_COPY_MAX_CELLS cap")
        #expect(payloadBytes > 0, "streaming copy produced no bytes")
        #expect(elapsed < ceiling, "100k x 10 full-selection streaming copy took \(elapsed); GATING ceiling \(ceiling)")
    }
}
