import AppKit
import Contracts
import Foundation
import SwiftUI

// MARK: - Landing-stall verification hook (LESSSHEET_LANDING_STALL)

// Verification-only: drives 5 consecutive FAR landings alternating find/jump on
// the loaded document and reports the worst MAIN-THREAD gap through a fast
// (~16 ms) heartbeat — the < 100 ms no-stall proof for the bounded scroll
// metric. INERT unless the env var is set. Seeds a Text search first so the
// find-steps have matches to navigate; steps are spaced so each landing settles.
@MainActor
enum LandingStallProbe {
    private static let env = ProcessInfo.processInfo.environment
    static var active: Bool { env["LESSSHEET_LANDING_STALL"] != nil }
    /// Comma-separated 1-based far rows for the jump landings; find-steps use the
    /// seeded query's matches. Defaults suit the big verification fixture.
    private static var jumpTargets: [String] {
        (env["LESSSHEET_LANDING_STALL"] ?? "").split(separator: ",").map(String.init)
            .filter { !$0.isEmpty }
    }
    private static var query: String { env["LESSSHEET_FIND"] ?? "ZQZmark" }

    private static var model: DocumentModel?
    private static var startTime = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var maxGapMs = 0        // reset per landing (isolated block)
    private static var worstGapMs = 0      // worst across all landings
    private static var step = 0
    private static var targets: [String] = []
    private static let kinds = ["jump", "find", "jump", "find", "find"]

    static func run(model: DocumentModel) {
        guard active else { return }
        self.model = model
        let parsed = jumpTargets
        targets = parsed.count >= 2 ? parsed : ["1500001", "2100001"]
        startTime = DispatchTime.now(); lastTick = startTime; maxGapMs = 0; worstGapMs = 0; step = 0
        startHeartbeat()
        log("lesssheet.landing.begin query=\(query) jumps=\(targets.joined(separator: ",")) at_ms=0")
        model.submitFindQuery(query)                 // seed a search (lands match 1)
        // Let the initial scan/index settle so each landing is measured in
        // isolation (a clean single far ⌘G/Enter, not a rapid burst).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { doStep() }
    }

    private static func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let now = DispatchTime.now()
                let gap = Int((now.uptimeNanoseconds &- lastTick.uptimeNanoseconds) / 1_000_000)
                lastTick = now
                maxGapMs = max(maxGapMs, gap)
            }
        }
    }

    private static func doStep() {
        guard let model else { return }
        // Report the PREVIOUS landing's isolated max gap (measured across its
        // settle window), then open a fresh window for this landing.
        if step >= 1 {
            worstGapMs = max(worstGapMs, maxGapMs)
            log("lesssheet.landing.result step=\(step) kind=\(kinds[step - 1]) max_gap_ms=\(maxGapMs)"
                + (maxGapMs > 100 ? " OVER" : " OK") + " at_ms=\(elapsedMs())")
        }
        guard step < kinds.count else {
            log("lesssheet.landing.worst_max_gap_ms=\(worstGapMs) landings=\(kinds.count) at_ms=\(elapsedMs())"
                + (worstGapMs > 100 ? " OVER_BUDGET" : " OK"))
            heartbeat?.cancel(); heartbeat = nil
            if env["LESSSHEET_DUMP_EXIT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
            return
        }
        maxGapMs = 0; lastTick = DispatchTime.now()   // fresh isolated window
        switch kinds[step] {
        case "jump": _ = model.submitJump(targets[step == 0 ? 0 : 1])
        default: model.stepFind(.forward)
        }
        step += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { doStep() }
    }

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
