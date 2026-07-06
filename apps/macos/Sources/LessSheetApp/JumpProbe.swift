import AppKit
import Foundation

// Verification-only instrumentation for the jump-to-row path — INERT unless the
// matching environment variable is set, so it costs nothing in normal use and
// can never touch the < 500 ms cold-start measurement (it starts only after the
// first data-bearing frame).
//
//   LESSSHEET_JUMP=<row>[,<row>…]  Drive the REAL UI jump path (identical to
//     typing the row + Enter in the popup) once per target, in sequence, right
//     after first paint. For each target it logs submit / scanning-shown /
//     progress, and its terminal state — LANDED (exact) or REJECTED (target
//     past the last row, or invalid). A 250 ms MAIN-ACTOR heartbeat logs its
//     inter-tick gap every tick (any gap > 500 ms = the main thread stalled).
//     After a REJECT it advances to the next target (proving the UI still works
//     — a follow-up jump lands); the LAST target's terminal state is dumped
//     (arrival grid, or the red rejected field) and, under LESSSHEET_DUMP_EXIT,
//     the headless instance quits.
//
//   LESSSHEET_LOG_OFFSET           Log the grid's scroll content offset / top
//     content inset when they change (proves (0,0) open + row-1-below-titlebar).

@MainActor
enum JumpProbe {
    private static let env = ProcessInfo.processInfo.environment
    private static let targets: [String] =
        (env["LESSSHEET_JUMP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

    /// True when the hook is armed with at least one target.
    static let active: Bool = !targets.isEmpty

    private static var index = 0
    private static var model: DocumentModel?
    private static var t0 = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var scanningLogged = false
    private static var lastPct = -1
    private static var maxGapMs = 0

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000)
    }

    /// Called from the first data-bearing frame's task (after the cold-start
    /// marker): start the heartbeat and submit the first target.
    static func run(model: DocumentModel) {
        guard active else { return }
        self.model = model
        t0 = DispatchTime.now()
        lastTick = t0
        index = 0
        maxGapMs = 0
        startHeartbeat()
        submitCurrent()
    }

    private static func submitCurrent() {
        guard let model, index < targets.count else { return }
        scanningLogged = false
        lastPct = -1
        log("lesssheet.jump.submit seq=\(index) target_1based=\(targets[index]) at_ms=\(elapsedMs())"
            + " known_total=\(model.rowCountInfo.count) exact=\(model.rowCountInfo.isExact)")
        _ = model.submitJump(targets[index])   // identical to typing <target> + Enter
    }

    private static func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                let now = DispatchTime.now()
                let gap = Int((now.uptimeNanoseconds &- lastTick.uptimeNanoseconds) / 1_000_000)
                lastTick = now
                maxGapMs = max(maxGapMs, gap)
                log("lesssheet.heartbeat.gap_ms=\(gap) at_ms=\(elapsedMs())\(gap > 500 ? " STALL" : "")")
                if elapsedMs() > 90_000 {   // never leave a headless run hanging
                    log("lesssheet.jump.timeout_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    quit(); return
                }
            }
        }
    }

    /// Folded scan progress (0…1); logged only when the integer percent changes.
    static func noteProgress(_ progress: Double) {
        guard active else { return }
        let pct = Int((max(0, min(1, progress)) * 100).rounded())
        guard pct != lastPct else { return }
        lastPct = pct
        log("lesssheet.jump.progress=\(pct) at_ms=\(elapsedMs())")
    }

    /// The scanning popup state reached the view layer (main-actor render proof).
    static func noteScanningShown() {
        guard active, !scanningLogged else { return }
        scanningLogged = true
        log("lesssheet.jump.scanning_shown_ms=\(elapsedMs())")
    }

    /// The rejected field rendered (main-actor render proof).
    static func noteRejectionShown() {
        guard active else { return }
        log("lesssheet.jump.rejected_shown_ms=\(elapsedMs())")
    }

    /// Terminal state: the jump landed exactly on the requested row.
    static func arrived(model: DocumentModel, landed row: UInt64) {
        guard active, index < targets.count else { return }
        log("lesssheet.jump.landed seq=\(index) landed_row_0based=\(row) gutter_1based=\(row &+ 1)"
            + " at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        advance(finalDump: .arrival)
    }

    /// Terminal state: the jump was rejected (past the last row, or invalid).
    static func rejected(model: DocumentModel, scanned: Bool, restoredTo: UInt64?) {
        guard active, index < targets.count else { return }
        let restore = restoredTo.map { String($0) } ?? "unchanged"
        log("lesssheet.jump.rejected seq=\(index) scanned=\(scanned) viewport_restored_to_firstRow=\(restore)"
            + " exact_total=\(model.rowCountInfo.count) exact=\(model.rowCountInfo.isExact)"
            + " at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        advance(finalDump: .reject)
    }

    private enum FinalDump { case arrival, reject }

    private static func advance(finalDump: FinalDump) {
        index += 1
        if index < targets.count {
            // Prove the UI is still functional after a reject/land: submit the
            // next target on a later tick (lets the current update settle).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { submitCurrent() }
            return
        }
        if let model {
            switch finalDump {
            case .arrival: FrameDump.dumpArrival(for: model)
            case .reject: FrameDump.dumpReject(for: model)
            }
        }
        heartbeat?.cancel(); heartbeat = nil
        if env["LESSSHEET_DUMP_EXIT"] != nil { quit() }
    }

    private static func quit() {
        // Let stderr / the PNG flush before terminating the headless instance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

// Diagnostic: report the grid's scroll content offset when it changes. Inert
// unless LESSSHEET_LOG_OFFSET is set. Used to verify the grid opens at (0,0)
// (item 2) without any screen capture.
@MainActor
enum ScrollProbe {
    static let enabled = ProcessInfo.processInfo.environment["LESSSHEET_LOG_OFFSET"] != nil
    /// Live window-space frame logging for the pinned header / row 1 / scroll
    /// view (item 1 overlap diagnosis). Inert unless LESSSHEET_LOG_LAYOUT is set.
    static let layoutEnabled = ProcessInfo.processInfo.environment["LESSSHEET_LOG_LAYOUT"] != nil
    private static var last: CGPoint?
    private static let start = DispatchTime.now()

    static func noteFrame(_ label: String, _ r: CGRect) {
        guard layoutEnabled else { return }
        let ms = Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
        FileHandle.standardError.write(Data(String(
            format: "lesssheet.layout.\(label) minY=%.1f maxY=%.1f minX=%.1f height=%.1f at_ms=%d\n",
            r.minY, r.maxY, r.minX, r.height, ms).utf8))
    }

    static func note(_ offset: CGPoint) {
        guard enabled else { return }
        if let l = last, abs(l.x - offset.x) < 0.5, abs(l.y - offset.y) < 0.5 { return }
        last = offset
        FileHandle.standardError.write(
            Data(String(format: "lesssheet.scroll.offset x=%.1f y=%.1f\n", offset.x, offset.y).utf8)
        )
    }

    static func noteInsets(top: CGFloat, label: String) {
        guard enabled else { return }
        FileHandle.standardError.write(
            Data(String(format: "lesssheet.\(label).top=%.1f\n", top).utf8)
        )
    }
}
