import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the STREAMING-COPY DRIVE OUTCOMES
// — INERT unless
// LESSSHEET_STREAM_COPY_OUTCOME is set, so it costs nothing in normal use.
//
// It drives `DocumentModel.streamCopy` (the OFF-main streaming drive behind
// ViewerModel.copySelection) DIRECTLY, with a FAKE `DocumentSession` / `CopyStreaming`,
// and asserts the frontend-owned outcomes the gated tests can't see:
// StreamingCopyBridgeTests + the re-pointed StreamCopyWallClockTests drive the
// core `openCopy` binding, but NOT `streamCopy`'s OWN byte-budget cut, cell-cap
// mapping, or FILTERED-stall handling. A fake session makes those deterministic +
// headless — a real AUTO core would self-heal a filtered stall via its background
// scan, hiding the finding-1 busy-spin this locks.
//
//   LESSSHEET_STREAM_COPY_OUTCOME=1  After first paint, run the four cases below
//     once, emit one `lesssheet.streamcopyoutcome.case name=<> outcome=<> … pass=<bool>`
//     line each, then (under LESSSHEET_DUMP_EXIT) quit. Cases:
//       byte_budget     — MORE chunks exceeding a small maxTotalBytes stop at
//                         `.stoppedAtBudget` (bounded blob), and the job is closed.
//       filtered_stall  — a STALLED that recurs on the SAME view
//                         row after a jump that returned DONE without advancing (the
//                         filtered mis-target) stops CLEANLY at `.stoppedAtFrontier`
//                         with NO busy-spin — asserted by a tiny bounded next()/jump
//                         count + sub-second wall-clock (a broken guard blows both).
//       cell_cap        — a DONE with budgetCapped maps to `.stoppedAtCellCap`.
//       complete        — a plain DONE maps to `.complete` (sanity).
@MainActor
enum StreamCopyOutcomeProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_STREAM_COPY_OUTCOME"] != nil
    private static var started = false
    private static var startTime = DispatchTime.now()

    static func run() {
        guard active, !started else { return }
        started = true
        startTime = DispatchTime.now()
        Task { await runCases(); finish() }
    }

    private static func runCases() async {
        // Rect shape is irrelevant to a fake session — it never reads it.
        let rect = SelectionRect(top: 0, bottom: 100, left: 0, right: 2)

        // (a) byte_budget: MORE chunks accumulate past a small maxTotalBytes ->
        // streamCopy stops pulling at .stoppedAtBudget (blob bounded to
        // budget + one chunk), and closes the job.
        do {
            let chunk = [UInt8](repeating: UInt8(ascii: "A"), count: 1024)
            let stream = FakeCopyStream(.moreForever(chunk: chunk))
            let session = FakeCopySession(stream)
            let budget = CopyBudget(maxTotalBytes: 4096, maxCells: 10_000_000, perCellMaxBytes: 1 << 20)
            let report = await DocumentModel.streamCopy(session: session, rect: rect, budget: budget)
            let pass = report.outcome == .stoppedAtBudget
                && report.byteCount >= budget.maxTotalBytes
                && report.byteCount <= budget.maxTotalBytes + chunk.count
                && stream.closed
            emit("byte_budget", report.outcome,
                 "bytes=\(report.byteCount) closed=\(stream.closed)", pass)
        }

        // (b) filtered_stall (FINDING 1): a fake session that STALLS on the same
        // view row every pull, with startJump()->DONE that never advances the
        // frontier (mimicking startJump(originalRow) when stalledRow is a FILTERED
        // index). streamCopy MUST stop at .stoppedAtFrontier after ONE wasted jump
        // (next() twice, jump once), in well under a second — no busy-spin.
        do {
            let stream = FakeCopyStream(.alwaysStalled(row: 7))
            let session = FakeCopySession(stream)
            let start = ContinuousClock.now
            let report = await DocumentModel.streamCopy(session: session, rect: rect, budget: .standard)
            let elapsed = ContinuousClock.now - start
            let pass = report.outcome == .stoppedAtFrontier
                && stream.nextCalls <= 3        // 2 with the fix; a broken guard blows this
                && session.jumpCalls <= 1
                && elapsed < .seconds(1)         // no spin: a single back-off sleep, not a loop
                && stream.closed
            emit("filtered_stall", report.outcome,
                 "next_calls=\(stream.nextCalls) jumps=\(session.jumpCalls) elapsed=\(elapsed) closed=\(stream.closed)",
                 pass)
        }

        // (c) cell_cap: DONE with budgetCapped -> .stoppedAtCellCap.
        do {
            let stream = FakeCopyStream(.doneCapped)
            let session = FakeCopySession(stream)
            let report = await DocumentModel.streamCopy(session: session, rect: rect, budget: .standard)
            emit("cell_cap", report.outcome, "closed=\(stream.closed)",
                 report.outcome == .stoppedAtCellCap && stream.closed)
        }

        // (d) complete: a plain DONE -> .complete (sanity that the happy path maps).
        do {
            let stream = FakeCopyStream(.doneComplete(bytes: Array("ok".utf8)))
            let session = FakeCopySession(stream)
            let report = await DocumentModel.streamCopy(session: session, rect: rect, budget: .standard)
            emit("complete", report.outcome, "bytes=\(report.byteCount)",
                 report.outcome == .complete && report.byteCount == 2 && stream.closed)
        }
    }

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    private static func emit(_ name: String, _ outcome: CopyOutcome, _ extra: String, _ pass: Bool) {
        log("lesssheet.streamcopyoutcome.case name=\(name) outcome=\(outcome) " +
            "\(extra) pass=\(pass) at_ms=\(elapsedMs())")
    }

    private static func finish() {
        log("lesssheet.streamcopyoutcome.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

// MARK: - Fakes (probe-only; deterministic doubles for the streaming drive)

/// A scripted `CopyStreaming` — returns a fixed step shape each pull so
/// `DocumentModel.streamCopy`'s outcome mapping is exercised deterministically.
private final class FakeCopyStream: CopyStreaming, @unchecked Sendable {
    enum Mode {
        case moreForever(chunk: [UInt8])   // byte-budget: emit `chunk` on every next()
        case alwaysStalled(row: UInt64)    // filtered-stall: STALLED the same row (bounded)
        case doneCapped                    // cell-cap: DONE, budgetCapped == true, 0 bytes
        case doneComplete(bytes: [UInt8])  // sanity: DONE, not capped
    }
    private let mode: Mode
    private(set) var nextCalls = 0
    private(set) var closed = false

    init(_ mode: Mode) { self.mode = mode }

    func next(maxChunkBytes: Int) -> CopyStep {
        nextCalls += 1
        switch mode {
        case let .moreForever(chunk):
            return CopyStep(kind: .more, bytes: chunk, rowsDone: UInt64(nextCalls), stalledRow: 0, budgetCapped: false)
        case let .alwaysStalled(row):
            // Self-bound so a REGRESSED guard fails cleanly (outcome != frontier,
            // next_calls >> 3) instead of hanging the probe run.
            if nextCalls > 200 {
                return CopyStep(kind: .done, bytes: [], rowsDone: 0, stalledRow: 0, budgetCapped: false)
            }
            return CopyStep(kind: .stalled, bytes: [], rowsDone: 0, stalledRow: row, budgetCapped: false)
        case .doneCapped:
            return CopyStep(kind: .done, bytes: [], rowsDone: 0, stalledRow: 0, budgetCapped: true)
        case let .doneComplete(bytes):
            return CopyStep(kind: .done, bytes: bytes, rowsDone: 1, stalledRow: 0, budgetCapped: false)
        }
    }

    func close() { closed = true }
}

/// A minimal `DocumentSession` double: only `openCopy` / `startJump` / `jumpStatus`
/// (the members `streamCopy` calls) do real work. `startJump` is a no-op and
/// `jumpStatus` reports `.done` immediately WITHOUT advancing any frontier — exactly
/// the filtered mis-target. Every other member is unreachable from
/// `streamCopy`.
private final class FakeCopySession: DocumentSession, @unchecked Sendable {
    private let stream: FakeCopyStream
    private(set) var jumpCalls = 0

    init(_ stream: FakeCopyStream) { self.stream = stream }

    func openCopy(_ rect: SelectionRect) -> (any CopyStreaming)? { stream }
    func startJump(to targetRow: UInt64) { jumpCalls += 1 }
    func jumpStatus() -> JumpStatus { .done(landedRow: 0) }

    // Unreachable from `streamCopy` (it uses only the three members above).
    var columnCount: Int { 0 }
    var dialect: DialectReport { fatalError("StreamCopyOutcomeProbe: dialect is never read by streamCopy") }
    var headerCells: [String]? { nil }
    func rowCount() -> RowCountInfo { RowCountInfo(count: 0, isExact: true) }
    func indexProgress() -> ScanProgress { ScanProgress(bytesScanned: 0, bytesTotal: 0, isComplete: true) }
    func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow { RowWindow(firstRow: 0, rows: []) }
    func cancelJump() {}
    func startSearch(_ request: SearchRequest) -> Bool { false }
    func navigateSearch(_ nav: SearchNav) {}
    func cancelSearch() {}
    func searchStatus() -> SearchSnapshot? { nil }
    func setFilter(_ request: SearchRequest) -> Bool { false }
    func clearFilter() {}
    func filterStatus() -> FilterSnapshot? { nil }
    func sourceRow(_ viewRow: UInt64) -> UInt64? { nil }
    func close() {}
}
