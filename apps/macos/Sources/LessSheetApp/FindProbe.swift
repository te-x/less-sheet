import AppKit
import Contracts
import Foundation
import SwiftUI

// MARK: - Verification hook (LESSSHEET_FIND)

// Verification-only instrumentation for the find path — INERT unless the env var
// is set, so it costs nothing in normal use and never touches the < 500 ms
// cold-start measurement (it starts only after the first data-bearing frame).
//
//   LESSSHEET_FIND=<query>   Drive the REAL UI find path (identical to typing
//     <query> in the Text field + Enter) once, right after first paint. Logs
//     submit / scanning-shown / progress / the terminal state — the first
//     landing (match n of m) and the final count, or "no matches", or a
//     rejection. A 250 ms MAIN-ACTOR heartbeat logs its inter-tick gap every
//     tick (any gap > 500 ms = the main thread stalled) — the no-stall proof
//     for a full-file search on the big fixture. The terminal state is dumped
//     and, under LESSSHEET_DUMP_EXIT, the headless instance quits.
@MainActor
enum FindProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let query: String? = {
        guard let raw = env["LESSSHEET_FIND"], !raw.isEmpty else { return nil }
        return raw
    }()

    /// True when the hook is armed.
    static var active: Bool { query != nil }

    /// Opt-in: after the initial search resolves, trigger a wrap (Previous
    /// before the first match) and trace the notice's visible lifetime, proving
    /// the wrap notice is held for the readable latch before it clears.
    static let wrapMode: Bool = env["LESSSHEET_FIND_WRAP"] != nil

    /// Opt-in: drive submit + step-during-scan ×2 + step-after-done ×1, logging
    /// every fold so each landing can be checked against the true match rows.
    static let stepSeqMode: Bool = env["LESSSHEET_FIND_STEP_SEQ"] != nil

    /// Opt-in AC21 regression: once a completed search leaves its popup open,
    /// drive a wheel event through the shipping click-away scrim and verify
    /// that the viewport moves without closing or clearing the search.
    static let scrollWhileActiveMode: Bool = env["LESSSHEET_FIND_SCROLL_ACTIVE"] != nil

    private static var model: DocumentModel?
    private static var startTime = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var scanningLogged = false
    private static var landedLogged = false
    private static var finalLogged = false
    private static var lastPct = -1
    private static var maxGapMs = 0
    private static var finished = false
    private static var lastNotice = "none"
    private static var wrapTriggered = false
    private static var wrapNoticeSeen = false
    private static var lastLandedRow: UInt64?
    private static var landings = 0
    private static var wantDoneStep = false
    private static var doneStepIssued = false
    private static var scrollProbeStarted = false

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    /// Called from the first data-bearing frame's task: start the heartbeat and
    /// submit the query through the real popup path.
    static func run(model: DocumentModel) {
        guard active, let query else { return }
        self.model = model
        startTime = DispatchTime.now()
        lastTick = startTime
        maxGapMs = 0
        finished = false
        scanningLogged = false
        landedLogged = false
        finalLogged = false
        lastPct = -1
        scrollProbeStarted = false
        startHeartbeat()
        log("lesssheet.find.submit query=\(query) at_ms=\(elapsedMs())"
            + " known_total=\(model.rowCountInfo.count) exact=\(model.rowCountInfo.isExact)")
        model.submitFindQuery(query)     // identical to typing <query> + Enter
        checkTerminal()
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
                // Include the current notice each tick so a wrap latch shows as a
                // run of identical-notice ticks before it clears.
                let notice = model.map { noticeName($0.findSession.display.notice) } ?? "none"
                log("lesssheet.heartbeat.gap_ms=\(gap) notice=\(notice)"
                    + " at_ms=\(elapsedMs())\(gap > 500 ? " STALL" : "")")
                if elapsedMs() > 90_000 {     // never leave a headless run hanging
                    log("lesssheet.find.timeout_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    finish(); return
                }
            }
        }
    }

    /// The scanning progress state reached the view layer (main-actor render proof).
    static func noteScanningShown() {
        guard active, !scanningLogged else { return }
        scanningLogged = true
        log("lesssheet.find.scanning_shown_ms=\(elapsedMs())")
    }

    /// Fold hook: called from the model after each search poll fold.
    static func note(model: DocumentModel, snapshot: SearchSnapshot?, scrolledTo: UInt64?) {
        guard active, !finished else { return }
        let display = model.findSession.display

        // Per-fold trace: the raw core snapshot (state, nav, its found row/pos),
        // the resolved display (current landing / position / notice), and the
        // frontend's landing decision (the ONLY viewport move). This is the
        // decisive evidence — every scroll must be an exact FOUND landing.
        log("lesssheet.find.fold " + snapshotTrace(snapshot)
            + " total=\(snapshot?.total ?? 0) final=\(snapshot?.totalIsFinal ?? false)"
            + " dispCur=\(display.current.map { "\($0.row)" } ?? "-")"
            + " dispPos=\(display.position.map(String.init) ?? "-")"
            + " notice=\(noticeName(display.notice))"
            + " scrolledTo=\(scrolledTo.map(String.init) ?? "-") at_ms=\(elapsedMs())")

        let noticeNow = noticeName(display.notice)
        if noticeNow != lastNotice {
            lastNotice = noticeNow
            log("lesssheet.find.notice=\(noticeNow) at_ms=\(elapsedMs())")
        }
        logProgress(display)
        logLandedAndFinal(display)

        // A distinct new landing (the current match row changed).
        if let row = display.current?.row, row != lastLandedRow {
            lastLandedRow = row
            landings += 1
            log("lesssheet.find.landing n=\(landings) row_0based=\(row) pos=\(display.position ?? 0)"
                + " total=\(display.total) final=\(display.totalIsFinal) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
            if stepSeqMode { driveSequence(model, isFinal: display.totalIsFinal) }
        }

        // The after-done step of the sequence (issued only once the scan is final),
        // paced on the previous match's observed scroll like every other step.
        if stepSeqMode, wantDoneStep, !doneStepIssued, display.totalIsFinal {
            doneStepIssued = true
            queueStep(seq: 3, kind: "after-done")
        }

        if !stepSeqMode { checkTerminal() }
    }

    /// The raw core snapshot rendered for the per-fold trace.
    private static func snapshotTrace(_ snapshot: SearchSnapshot?) -> String {
        var snapNav = "nil", snapState = "nil", snapFoundRow = "-", snapPos = "-"
        if let snapshot {
            snapState = phaseName(snapshot.phase)
            snapNav = navName(snapshot.nav)
            if case let .found(match, pos) = snapshot.nav {
                snapFoundRow = "\(match.row)"
                snapPos = "\(pos)"
            }
        }
        return "state=\(snapState) nav=\(snapNav) snapFound=\(snapFoundRow) snapPos=\(snapPos)"
    }

    /// Log a progress-percent change (deduplicated to whole-percent steps).
    private static func logProgress(_ display: FindDisplay) {
        guard let progress = display.progress else { return }
        let pct = Int((max(0, min(1, progress)) * 100).rounded())
        if pct != lastPct {
            lastPct = pct
            log("lesssheet.find.progress=\(pct) at_ms=\(elapsedMs())")
        }
    }

    /// Log the first landing and the final-count milestone, once each.
    private static func logLandedAndFinal(_ display: FindDisplay) {
        if let current = display.current, !landedLogged {
            landedLogged = true
            log("lesssheet.find.landed pos=\(display.position ?? 0) total=\(display.total)"
                + " row_0based=\(current.row) col=\(current.column) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        }
        if display.totalIsFinal, !finalLogged {
            finalLogged = true
            log("lesssheet.find.count_final total=\(display.total) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        }
    }

    /// Drive the submit + step-during-scan ×2 + step-after-done ×1 sequence off
    /// the observed landings (each `stepFind` is exactly what ⌘G does).
    private static func driveSequence(_ model: DocumentModel, isFinal: Bool) {
        switch landings {
        case 1:  // first match (fromTop) landed; the scan is still counting.
            queueStep(seq: 1, kind: "during-scan")
        case 2:  // step #1's match landed; still scanning.
            queueStep(seq: 2, kind: "during-scan")
        case 3:  // step #2's match landed; hold until the scan completes.
            wantDoneStep = true
            log("lesssheet.find.await_done at_ms=\(elapsedMs())")
            // The scan can already be final in this very fold, in which case the
            // block in `logFold` will not get another turn — queue it here.
            if isFinal {
                doneStepIssued = true
                queueStep(seq: 3, kind: "after-done")
            }
        default: // step #3's (after-done) match landed -> done.
            log("lesssheet.find.seq_complete landings=\(landings) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
            finish()
        }
    }

    /// Issue the next ⌘G only once the CURRENT match is physically on screen —
    /// see `FindStepPacer` for why pacing on the observed scroll (rather than on
    /// how fast the core resolves matches) is what makes this sequence
    /// deterministic.
    private static func queueStep(seq: Int, kind: String) {
        FindStepPacer.queue(afterRow: lastLandedRow.map { Int(min($0, UInt64(Int.max))) }) {
            guard let model else { return }
            log("lesssheet.find.step seq=\(seq) kind=\(kind) at_ms=\(elapsedMs())")
            model.stepFind(.forward)
        }
    }

    /// The submit was rejected (ordering predicate, non-numeric value) or the
    /// core refused the start (seed core) — a terminal state.
    static func rejected(model: DocumentModel) {
        guard active, !finished else { return }
        log("lesssheet.find.rejected at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        finish()
    }

    private static func checkTerminal() {
        guard active, !finished, let model else { return }
        let display = model.findSession.display
        let landed = display.current != nil
        let noMatches = display.notice == .noMatches

        if wrapMode {
            // Phase 1: once the initial search is final and landed, trigger a
            // wrap — Previous before the first match exhausts core-side and the
            // view-model turns it into "Wrapped to end".
            if display.totalIsFinal, landed, !wrapTriggered {
                wrapTriggered = true
                log("lesssheet.find.wrap_trigger dir=backward at_ms=\(elapsedMs())")
                model.stepFind(.backward)
                return
            }
            // Phase 2: the wrap notice must appear, hold for the latch, then
            // clear when the wrap lands — terminal once it has cleared.
            if wrapTriggered {
                if display.notice != nil { wrapNoticeSeen = true }
                if wrapNoticeSeen, display.notice == nil, display.current != nil {
                    log("lesssheet.find.wrap_landed pos=\(display.position ?? 0)"
                        + " row_0based=\(display.current?.row ?? 0) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    finish()
                }
            }
            return
        }

        // Terminal once the scan is final and the first landing resolved (or the
        // whole file holds no match).
        if display.totalIsFinal, landed || noMatches {
            log("lesssheet.find.terminal total=\(display.total) final=\(display.totalIsFinal)"
                + " landed=\(landed) no_matches=\(noMatches) at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
            if scrollWhileActiveMode, landed {
                if !scrollProbeStarted {
                    scrollProbeStarted = true
                    runActiveSearchScrollProbe(model)
                }
                return
            }
            finish()
        }
    }

    /// Wait one render turn for `findScanning` to become false and install the
    /// click-away scrim, then directly invoke that exact view with a pixel-wheel
    /// event (never posted, so no input-monitoring permission is involved). The
    /// frozen native-grid suite can assert the three booleans in this signal.
    private static func runActiveSearchScrollProbe(_ model: DocumentModel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let controller = NativeGridController.live,
                  let scrim = PopupDismissScrimView.live,
                  let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: -160, wheel2: 0, wheel3: 0
                  ),
                  let event = NSEvent(cgEvent: cgEvent)
            else {
                log("lesssheet.find.scroll_while_active probe_ready=false")
                finish()
                return
            }
            let before = controller.scroll.contentView.bounds.origin.y
            scrim.scrollWheel(with: event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let after = controller.scroll.contentView.bounds.origin.y
                let moved = abs(after - before) > 0.5
                let searchActive = model.findSession.display.request != nil
                log(String(format:
                    "lesssheet.find.scroll_while_active probe_ready=true before_y=%.1f after_y=%.1f"
                        + " moved=\(moved) search_active=\(searchActive) popup_active=\(model.findFieldActive)",
                    before, after
                ))
                finish()
            }
        }
    }

    private static func finish() {
        guard !finished else { return }
        finished = true
        heartbeat?.cancel()
        heartbeat = nil
        if let model { FrameDump.dumpFindResult(for: model) }
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

extension FindProbe {
    private static func noticeName(_ notice: FindNotice?) -> String {
        switch notice {
        case .wrappedToStart: "wrappedToStart"
        case .wrappedToEnd: "wrappedToEnd"
        case .noMatches: "noMatches"
        case .stopped: "stopped"
        case nil: "none"
        }
    }

    private static func phaseName(_ phase: SearchScanPhase) -> String {
        switch phase {
        case .scanning: "scanning"
        case .done: "done"
        case .cancelled: "cancelled"
        }
    }

    private static func navName(_ nav: SearchNavStatus) -> String {
        switch nav {
        case .none: "none"
        case .searching: "searching"
        case .found: "found"
        case .exhausted: "exhausted"
        }
    }
}
