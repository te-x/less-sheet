import AppKit
import Foundation

// Verification-only instrumentation for the jump-to-row path — INERT unless the
// matching environment variable is set, so it costs nothing in normal use and
// can never touch the < 500 ms cold-start measurement (it starts only after the
// first data-bearing frame).
//
//   LESSSHEET_JUMP=<1-based row>   Drive the REAL UI jump path (identical to
//     typing the row + Enter in the popup) once, right after first paint, then:
//       - log a timestamp at submit and when the scanning state reaches the view
//         (proves progress renders promptly),
//       - run a 250 ms MAIN-ACTOR heartbeat whose inter-tick gap is logged every
//         tick (any gap > 500 ms means the main thread stalled — the fix failed),
//       - log jump-scan progress as it folds,
//       - on landing, log the landed row, render an arrival frame dump (if
//         LESSSHEET_DUMP_FRAME is set) showing the target row, and — when
//         LESSSHEET_DUMP_EXIT is set — quit the headless instance.
//
//   LESSSHEET_LOG_OFFSET           Log the grid's scroll content offset whenever
//     it changes (used to prove the grid opens at exactly (0,0) — item 2).

@MainActor
enum JumpProbe {
    private static let env = ProcessInfo.processInfo.environment
    private static let rowText: String? = env["LESSSHEET_JUMP"]

    /// True when the hook is armed with a parseable 1-based row number.
    static let active: Bool = (rowText.flatMap { UInt64($0) }) != nil

    private static var t0 = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var landed = false
    private static var scanningLogged = false
    private static var maxGapMs = 0

    private static func ms(since: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- since.uptimeNanoseconds) / 1_000_000)
    }
    private static func elapsedMs() -> Int { ms(since: t0) }

    /// Called from the first data-bearing frame's task (after the cold-start
    /// marker): start the heartbeat and submit the jump on the real UI path.
    static func run(model: DocumentModel) {
        guard active, let raw = rowText else { return }
        t0 = DispatchTime.now()
        lastTick = t0
        landed = false
        scanningLogged = false
        maxGapMs = 0
        log("lesssheet.jump.submit_ms=\(elapsedMs()) target_1based=\(raw)")
        startHeartbeat()
        // Identical to the popup's submit() → model.submitJump(text).
        _ = model.submitJump(raw)
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
                let flag = gap > 500 ? " STALL" : ""
                log("lesssheet.heartbeat.gap_ms=\(gap) at_ms=\(elapsedMs())\(flag)")
                if elapsedMs() > 60_000 {   // never leave a headless run hanging
                    log("lesssheet.jump.timeout_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    quit()
                    return
                }
            }
        }
    }

    /// Folded scan progress (0…1); logged as it advances.
    static func noteProgress(_ progress: Double) {
        guard active, !landed else { return }
        let pct = Int((max(0, min(1, progress)) * 100).rounded())
        log("lesssheet.jump.progress=\(pct) at_ms=\(elapsedMs())")
    }

    /// The scanning popup state reached the view layer (main-actor render proof).
    static func noteScanningShown() {
        guard active, !scanningLogged else { return }
        scanningLogged = true
        log("lesssheet.jump.scanning_shown_ms=\(elapsedMs())")
    }

    /// The jump landed: log it, dump the arrival frame, then stop/quit.
    static func arrived(model: DocumentModel, landed row: UInt64) {
        guard active, !landed else { return }
        landed = true
        log("lesssheet.jump.landed_ms=\(elapsedMs()) landed_row_0based=\(row) gutter_1based=\(row &+ 1) max_gap_ms=\(maxGapMs)")
        FrameDump.dumpArrival(for: model)
        heartbeat?.cancel()
        heartbeat = nil
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
    private static var last: CGPoint?

    static func note(_ offset: CGPoint) {
        guard enabled else { return }
        if let l = last, abs(l.x - offset.x) < 0.5, abs(l.y - offset.y) < 0.5 { return }
        last = offset
        FileHandle.standardError.write(
            Data(String(format: "lesssheet.scroll.offset x=%.1f y=%.1f\n", offset.x, offset.y).utf8)
        )
    }
}
