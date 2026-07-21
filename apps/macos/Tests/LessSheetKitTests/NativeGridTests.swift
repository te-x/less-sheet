// Frozen behavior tests — native-grid slice (planner-owned).
//
// ARCH-native-grid is an ENGINE SWAP (SwiftUI ScrollView grid -> NSTableView-backed
// grid) with exactly ONE new behavioral requirement — any landing (jump / find /
// wrap) stalls the main thread < 100 ms — and strict behavioral equivalence
// otherwise. No new ABI, no new Kit protocols: the contract of this slice is the
// app's existing env-probe surface (log formats + values), pinned here by
// PROCESS-LAUNCHING the built LessSheet binary headless and asserting on its
// stderr probe lines. The probes live in implementer-owned Sources — this file
// pins their formats and required values; gutting or rewiring an instrument to
// dodge a bound is visible in the Sources diff and is the reviewer's escape to
// catch (the gate catches drift, the reviewer catches fraud).
//
// FROZEN here (gate-stable, deterministic or high-margin):
//   1. landingsStallTheMainThreadLessThan100ms — THE red seed. LESSSHEET_LANDING_STALL
//      drives 5 far landings alternating jump/find (viewport moves of 0.6M-1.6M rows
//      on a 3M-row fixture); every per-landing isolated main-thread max gap must be
//      < 100 ms. RED on the current SwiftUI grid — baseline recorded 2026-07-07,
//      debug build, M-series, 3M-row fixture:
//        step=1 kind=jump 191 ms OVER · step=2 kind=find 712 ms OVER ·
//        step=3 kind=jump 55 ms OK   · step=4 kind=find 1255 ms OVER ·
//        step=5 kind=find 99 ms OK   · worst_max_gap_ms=1255 OVER_BUDGET
//      (repeat run: 211 / 735 / 84 / 1294 / 100 — worst 1294; the far find-steps
//      are stably 7x-13x over budget, the red verdict does not ride the boundary)
//      Margin: the failing landings are 2x-12x over budget, so the 100 ms bound has
//      real headroom against scheduler noise. Flake policy: up to 3 launches; PASS
//      needs one fully-clean run; a well-formed run with worst >= 300 ms fails fast
//      (that is engine behavior, not noise — keeps red build-loop iterations cheap).
//      The 100 ms bound itself is never weakened.
//   2. jumpSequenceLandsExactlyAndRejectsPastEnd — LESSSHEET_JUMP equivalence:
//      far target lands exactly (scan + progress path), past-EOF target is REJECTED
//      (never lands, never clamps), follow-up jump still lands. Exactness only — NO
//      timing asserts here: the 250 ms jump heartbeat measurably absorbs the current
//      grid's landing stall (max_gap_ms=593 on the baseline run), so a timing pin
//      would duplicate test 1; criterion-2's "< 500 ms during scans" stays with the
//      reviewer's release run on the big fixture. PHYSICAL-VIEWPORT LOCK (cc-macos
//      defect pass): every jump landing's lesssheet.viewport.landed line must report
//      target_visible=true — the target sits in the REAL NSTableView visible rect,
//      not merely resolved in the model (ViewportLandingProbe fires only AFTER the
//      shipping NSClipView is scrolled by NativeGrid.applyPendingLanding).
//   3. findStepSequenceLandsOnEachMarker — LESSSHEET_FIND + LESSSHEET_FIND_STEP_SEQ
//      equivalence: submit -> first match, step x2 during scan, step x1 after done —
//      landings exactly on the fixture's 4 marker rows in order, final count exactly 4.
//      Each landing also carries the same PHYSICAL-VIEWPORT LOCK (target_visible=true).
//   4. layoutFramesArePinnedAtRest — LESSSHEET_LOG_LAYOUT equivalence: at-rest
//      window-space frames band y[0,54], header y[32,54], row1 y[54,76] (+-1 pt),
//      scrollview top at 0 — the same numbers the current grid logs; the new grid
//      re-emits them over AppKit frames in the identical format (ARCH criterion 4).
//   5. selectionSecondClickDeselectsCellRowAndColumn — LESSSHEET_SELECT_COPY: a
//      second click on an already-selected cell / whole row / whole column clears
//      the selection (deselected=true for all three), through the shipping
//      controller's event-free semantic seam (cc-macos defect-pass regression-lock).
//   6. scrollWheelMovesViewportWhileFindPopupActive — LESSSHEET_FIND_SCROLL_ACTIVE
//      (AC21 cc-macos round-2 defect-pass regression-LOCK): after a known-match Find
//      completes with its popup STILL open, ONE real pixel wheel event driven through
//      the shipping PopupDismissScrimView must SCROLL the live NSClipView while both
//      the search and the popup stay active. The single lesssheet.find.scroll_while_active
//      line must report probe_ready=true moved=true search_active=true popup_active=true.
//      GREEN today (the scrim now forwards scroll-wheel events to the grid); the earlier
//      transparent scrim swallowed them. Event-free of TCC (a synthesized NSEvent handed
//      straight to the scrim's handler, never posted). LESSSHEET_FIND (a known match)
//      arms FindProbe; LESSSHEET_DUMP_EXIT quits after the probe's terminal line.
//   7. columnConfigEditRepaintsGridWithoutInteraction — LESSSHEET_CONFIG_REPAINT
//      (cc-macos config-repaint defect-pass regression-LOCK). After first paint the probe
//      drives ONE real model-side column-config edit — setColumnFormat(grouping: true) on
//      people.csv's "age" column (0-based col 1, integer), the SAME model entry point the
//      Settings inspector's Thousands-grouping toggle calls — then, WITHOUT ever calling
//      apply() itself, reports the model's current columnConfigurationRevision vs the live
//      grid controller's APPLIED revision. The single lesssheet.configrepaint.result line
//      must report applied=true, model_rev > 0 (a real edit happened), and model_rev ==
//      controller_applied_rev (the grid caught up). MATERIALIZATION-INDEPENDENT: it compares
//      two ints, never a paged NSTableView row view, so — unlike the selection-repaint
//      content check below — it IS gateable off-screen. RED WITHOUT THE POKE: a headless
//      window gets no implicit updateNSView (see HeaderToggleProbe), so if the model's
//      config mutators do NOT explicitly poke NativeGridController.live?.apply() after
//      bumping the revision (the original "stale until interaction" defect, or any
//      regression of its fix), nothing applies the edit — controller_applied_rev LAGS
//      model_rev, applied=false. With the poke, apply() syncs the controller to the model's
//      current revision, so they match. The edit is fully synchronous (the probe reads both
//      revisions in the SAME main-actor turn), so this is an exactness lock — no timing/
//      flaky assert.
//
// REVIEWER-MEASURED (deliberately not gated — flaky gates are worse than reviewer
// enforcement):
//   - Criterion 1's release-mode run on the 2.6 GB fixture (this gate pins the same
//     bound in debug on the generated fixture — strictly easier for the new engine,
//     decisively red for the old one).
//   - Visual equivalence captures (criterion 5, live cacheDisplay + dump scenes),
//     hidden-column reflow / dialect re-open / header toggle (criterion 6's dumps).
//   - Estimate-refinement viewport stability (criterion 6): the 35 MB gate fixture
//     indexes in well under a second — a mid-refinement observation window cannot be
//     parked deterministically at gate scale.
//   - Cold start / RSS / 60 Hz / content-size warning (criterion 8), no-selection +
//     no column drag (criterion 9 — needs synthetic click events, not cheaply
//     probeable headless), wrap-landing stall + wrap-notice latch (LESSSHEET_FIND_WRAP),
//     Reduce Transparency, dark mode.
//   - Selection repaint preserves already-loaded row content (SelectCopyProbe's
//     lesssheet.selectcopy.selection_repaint content_preserved=true): an off-screen
//     headless run never materializes a paged NSTableView row view at probe time
//     (the probe honestly logs skip=no_loaded_row instead), so THIS one defect-pass
//     fix stays a human/reviewer visual check — the selection-toggle lock (test 5)
//     and the jump/find physical-viewport locks above ARE gated.
//
// Fixture: generated once into the user temp dir and cached by exact byte size
// (34_888_925 bytes) — header "id,tag,val" + 3_000_000 data rows "<i>,r,<i%10>",
// with tag "ZQZmark" (the stall probe's default query; matched case-insensitively by
// default, and the cell text equals the query so it matches either way) on
// 0-based data rows 200000 / 1400000 / 2000000 / 2800000. Generation ~2 s, one-time.
// Gate cost: 6 headless app launches (one per probe test on the happy path; some
// relaunch once on a malformed run), ~20-30 s green (red adds nothing: fail-fast).
// The scroll-while-active test reuses the byte-size-cached big fixture (no regen).
//
// HAZARD (pinned knowledge): a LANDING_STALL run must NOT set LESSSHEET_FIND — that
// arms FindProbe, whose terminal check under LESSSHEET_DUMP_EXIT quits the app the
// moment the seeded search resolves, killing the landing sequence mid-run. The stall
// probe's built-in default query ("ZQZmark") is baked into the fixture instead.
//
// Determinism notes: find-step landings anchor at current.row + 1 (pinned in
// FindControlling.step), so the marker sequence is viewport-independent; jump targets
// are 1-based in the env var (pinned in JumpControlling.parseTarget). Every
// equivalence run retries once on a MALFORMED run only (missing completion marker =
// infra failure); wrong values fail immediately.

import Foundation
import Testing

// MARK: - Generated fixture (pinned by this file)

private enum NativeGridFixture {
    static let dataRows = 3_000_000
    /// 0-based data rows carrying the marker tag (the header row is not a data row).
    static let markerRows = [200_000, 1_400_000, 2_000_000, 2_800_000]
    static let markerTag = "ZQZmark"
    static let header = "id,tag,val\n"

    /// Exact deterministic size of the generated file — the cache/reuse check.
    static var expectedBytes: Int {
        var total = header.utf8.count
        var lo = 0
        var width = 1
        var bound = 10
        while lo < dataRows {
            let hi = min(dataRows, bound)
            total += (hi - lo) * (width + 5) // "<i>" + "," + "r" + "," + digit + "\n"
            lo = hi
            width += 1
            bound *= 10
        }
        total += markerRows.count * (markerTag.utf8.count - 1) // "ZQZmark" replaces "r"
        return total
    }

    /// Returns the fixture path, generating it once (atomic publish) and reusing
    /// it across runs when the exact expected byte size is already present.
    static func path() throws -> String {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("lesssheet-native-grid-fixture-v1.csv")
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size == expectedBytes {
            return url.path
        }
        var data = Data()
        data.reserveCapacity(expectedBytes + 64)
        data.append(contentsOf: header.utf8)
        let markers = Set(markerRows)
        for i in 0..<dataRows {
            data.append(contentsOf: String(i).utf8)
            data.append(UInt8(ascii: ","))
            data.append(contentsOf: (markers.contains(i) ? markerTag : "r").utf8)
            data.append(UInt8(ascii: ","))
            data.append(UInt8(ascii: "0") + UInt8(i % 10))
            data.append(UInt8(ascii: "\n"))
        }
        guard data.count == expectedBytes else {
            throw ProbeError("fixture generator drifted: \(data.count) bytes, expected \(expectedBytes)")
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent(
            "lesssheet-native-grid-fixture-v1.\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        try data.write(to: tmp)
        try? fm.removeItem(at: url)
        try fm.moveItem(at: tmp, to: url)
        return url.path
    }
}

// MARK: - Headless app launcher

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Thread-safe stderr accumulator for the readability handler.
private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum AppProbe {
    /// The built app binary sits in the same SwiftPM products directory as this
    /// test target's resource bundle; `swift build` / `swift test` both (re)build it.
    static var binaryURL: URL {
        Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("LessSheet")
    }

    /// Launch the app headless on `fixture` with exactly the LESSSHEET_* hooks in
    /// `env` (any LESSSHEET_* from the outer shell is stripped first), capture its
    /// stderr until self-termination or `timeout`, and return the full log text.
    static func launchOnce(fixture: String, env extra: [String: String], timeout: TimeInterval) throws -> String {
        let binary = binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ProbeError("LessSheet binary not found at \(binary.path) — build it (swift build / the component gate) before testing")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = [fixture]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("LESSSHEET_") {
            environment.removeValue(forKey: key)
        }
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let buffer = LogBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(chunk)
            }
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 1.0)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stderrPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            buffer.append(rest)
        }
        return buffer.text
    }
}

// MARK: - Probe-log parsing

/// All log lines starting with `prefix` (include a trailing space in the prefix
/// when the line continues with fields, so "row1" never matches a longer label).
private func probeLines(_ log: String, prefix: String) -> [String] {
    log.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        .filter { $0.hasPrefix(prefix) }
}

/// The `key=value` fields of one probe line (values in these probes never
/// contain spaces).
private func probeFields(_ line: String) -> [String: String] {
    var fields: [String: String] = [:]
    for token in line.split(separator: " ") {
        if let eq = token.firstIndex(of: "=") {
            fields[String(token[..<eq])] = String(token[token.index(after: eq)...])
        }
    }
    return fields
}

private func intField(_ line: String, _ key: String) -> Int? {
    probeFields(line)[key].flatMap(Int.init)
}

private func doubleField(_ line: String, _ key: String) -> Double? {
    probeFields(line)[key].flatMap(Double.init)
}

/// The `true` / `false` value of a boolean probe field (nil if absent/other).
private func boolField(_ line: String, _ key: String) -> Bool? {
    switch probeFields(line)[key] {
    case "true": return true
    case "false": return false
    default: return nil
    }
}

/// A short tail of the log for failure messages.
private func logTail(_ log: String, lines n: Int = 30) -> String {
    log.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).joined(separator: "\n")
}

// MARK: - Frozen behavior (serialized: one headless app instance at a time)

@Suite("native-grid probes", .serialized)
struct NativeGridProbeTests {

    // THE behavioral delta of the slice (ARCH criterion 1, gate-scaled): five far
    // landings alternating jump/find — viewport moves of 600k/600k/1M/1.6M/800k
    // rows — each with an isolated main-thread max gap < 100 ms, measured by the
    // probe's 16 ms heartbeat. See the file header for the recorded RED baseline
    // (worst 1255 ms on the SwiftUI grid) and the retry/fail-fast policy.
    @Test func landingsStallTheMainThreadLessThan100ms() throws {
        let fixture = try NativeGridFixture.path()
        let env = [
            "LESSSHEET_LANDING_STALL": "800001,400001", // 1-based; 0-based 800000 / 400000
            "LESSSHEET_DUMP_EXIT": "1",
        ]
        let budgetMs = 100
        let failFastMs = 300 // a well-formed run this far over is the engine, not noise
        var verdict = "landing-stall probe never produced a well-formed run"

        for attempt in 1...3 {
            let log = try AppProbe.launchOnce(fixture: fixture, env: env, timeout: 120)

            guard let worstLine = probeLines(log, prefix: "lesssheet.landing.worst_max_gap_ms=").last,
                  let worst = intField(worstLine, "lesssheet.landing.worst_max_gap_ms")
            else {
                // Malformed run (crash / never completed): infra, not behavior — relaunch.
                verdict = "attempt \(attempt): malformed run — no worst_max_gap line.\n\(logTail(log))"
                continue
            }

            let results = probeLines(log, prefix: "lesssheet.landing.result ")
            let gaps = results.compactMap { intField($0, "max_gap_ms") }
            let kinds = results.compactMap { probeFields($0)["kind"] }
            let begin = probeLines(log, prefix: "lesssheet.landing.begin ").first ?? ""

            // Shape pin: the probe really ran the pinned 5-landing far sequence.
            let shapeOK = results.count == 5
                && gaps.count == 5
                && kinds == ["jump", "find", "jump", "find", "find"]
                && begin.contains("jumps=800001,400001")
                && intField(worstLine, "landings") == 5
            guard shapeOK else {
                verdict = "landing-stall probe shape drifted (expected 5 jump/find/jump/find/find "
                    + "results over jumps=800001,400001):\n\(begin)\n\(results.joined(separator: "\n"))\n\(worstLine)"
                break // deterministic — the instrument changed; do not retry
            }

            if worst < budgetMs && gaps.allSatisfy({ $0 < budgetMs }) {
                return // PASS: every landing under budget in a fully-clean run
            }

            verdict = "attempt \(attempt): per-landing main-thread gaps over the \(budgetMs) ms budget:\n"
                + results.joined(separator: "\n") + "\n" + worstLine
            if worst >= failFastMs { break } // engine-class stall: deterministic, no retry
        }

        #expect(Bool(false), Comment(rawValue: verdict))
    }

    // Equivalence pin (ARCH criterion 2, gate-scaled): a far jump lands EXACTLY
    // (scan-with-progress path), a past-EOF jump is REJECTED — never lands, never
    // clamps — and a follow-up jump still lands. Exactness only; timing lives in
    // the stall test (see file header).
    @Test func jumpSequenceLandsExactlyAndRejectsPastEnd() throws {
        let fixture = try NativeGridFixture.path()
        let env = [
            "LESSSHEET_JUMP": "2750001,999999999999,1234568",
            "LESSSHEET_DUMP_EXIT": "1",
        ]

        var log = ""
        for _ in 1...2 { // relaunch only when the run never reached its terminal state
            log = try AppProbe.launchOnce(fixture: fixture, env: env, timeout: 90)
            let terminal = !probeLines(log, prefix: "lesssheet.jump.landed seq=2 ").isEmpty
                || !probeLines(log, prefix: "lesssheet.jump.rejected seq=2 ").isEmpty
            if terminal { break }
        }

        let landed0 = probeLines(log, prefix: "lesssheet.jump.landed seq=0 ").first
        #expect(landed0.flatMap { intField($0, "landed_row_0based") } == 2_750_000,
                "far jump must land exactly on 0-based row 2750000:\n\(logTail(log))")
        #expect(landed0.flatMap { intField($0, "gutter_1based") } == 2_750_001)

        #expect(!probeLines(log, prefix: "lesssheet.jump.rejected seq=1 ").isEmpty,
                "past-EOF jump (999999999999) must be rejected:\n\(logTail(log))")
        #expect(probeLines(log, prefix: "lesssheet.jump.landed seq=1 ").isEmpty,
                "past-EOF jump must never land (no clamping):\n\(logTail(log))")

        let landed2 = probeLines(log, prefix: "lesssheet.jump.landed seq=2 ").first
        #expect(landed2.flatMap { intField($0, "landed_row_0based") } == 1_234_567,
                "follow-up jump after a rejection must land exactly:\n\(logTail(log))")

        // Physical-viewport lock (cc-macos defect pass): resolving the target in
        // the MODEL is not enough — the shipping NSTableView must actually scroll so
        // the target row is inside the LIVE visible rect. ViewportLandingProbe emits
        // `lesssheet.viewport.landed` only after NativeGrid.applyPendingLanding has
        // scrolled the real NSClipView (never on the resolved model row alone), so
        // target_visible=true here is a true physical-viewport assertion. Both the
        // far jump and the post-rejection follow-up jump must land in the viewport.
        for target in [2_750_000, 1_234_567] {
            let vp = probeLines(log, prefix: "lesssheet.viewport.landed ")
                .last { intField($0, "requested_row_0based") == target }
            #expect(vp.flatMap { boolField($0, "target_visible") } == true,
                    "jump to 0-based \(target) must land it inside the REAL viewport:\n\(logTail(log))")
        }
    }

    // Equivalence pin (ARCH criterion 3, gate-scaled): submit lands the FIRST match,
    // step x2 during the scan and x1 after completion land the next matches in order
    // — exactly the fixture's four marker rows — and the final count is exactly 4.
    @Test func findStepSequenceLandsOnEachMarker() throws {
        let fixture = try NativeGridFixture.path()
        let env = [
            "LESSSHEET_FIND": NativeGridFixture.markerTag,
            "LESSSHEET_FIND_STEP_SEQ": "1",
            "LESSSHEET_DUMP_EXIT": "1",
        ]

        var log = ""
        for _ in 1...2 { // relaunch only when the sequence never completed
            log = try AppProbe.launchOnce(fixture: fixture, env: env, timeout: 90)
            if !probeLines(log, prefix: "lesssheet.find.seq_complete ").isEmpty { break }
        }

        for (index, marker) in NativeGridFixture.markerRows.enumerated() {
            let landing = probeLines(log, prefix: "lesssheet.find.landing n=\(index + 1) ").first
            #expect(landing.flatMap { intField($0, "row_0based") } == marker,
                    "find landing \(index + 1) must be 0-based row \(marker):\n\(logTail(log))")
            #expect(landing.flatMap { intField($0, "pos") } == index + 1)

            // Physical-viewport lock (cc-macos defect pass): each find landing must
            // scroll the shipping NSTableView so the marker row is in the LIVE
            // visible rect — not merely resolved in the model. See the jump test's
            // note; the probe emits this only after the real NSClipView is scrolled.
            let vp = probeLines(log, prefix: "lesssheet.viewport.landed ")
                .last { intField($0, "requested_row_0based") == marker }
            #expect(vp.flatMap { boolField($0, "target_visible") } == true,
                    "find landing \(index + 1) must put marker row \(marker) inside the REAL viewport:\n\(logTail(log))")
        }

        let complete = probeLines(log, prefix: "lesssheet.find.seq_complete ").first
        #expect(complete.flatMap { intField($0, "landings") } == 4,
                "step sequence must complete with exactly 4 landings:\n\(logTail(log))")
        let countFinal = probeLines(log, prefix: "lesssheet.find.count_final ").first
        #expect(countFinal.flatMap { intField($0, "total") } == NativeGridFixture.markerRows.count,
                "final match count must be exactly \(NativeGridFixture.markerRows.count):\n\(logTail(log))")
    }

    // Scroll-while-Find-active lock (AC21, cc-macos round-2 defect pass): after a
    // known-match Find completes with its popup STILL open, a real wheel event over
    // the grid must SCROLL the viewport while both the search and the popup stay
    // active — the earlier transparent click-away scrim swallowed scroll-wheel events.
    // Regression-LOCK, not a red seed: the shipping scrim now forwards the wheel to
    // the grid (PopupDismissScrimView.scrollWheel -> NativeGridController.forwardScrollWheel),
    // so this passes GREEN today. LESSSHEET_FIND (a known match) arms FindProbe;
    // LESSSHEET_FIND_SCROLL_ACTIVE diverts its terminal path — once the scan is final
    // and the first match landed — into runActiveSearchScrollProbe, which drives ONE
    // pixel wheel event straight into the shipping PopupDismissScrimView (a synthesized
    // NSEvent handed to the handler, never posted — no TCC) and reports whether the
    // LIVE NSClipView moved with the search + popup still active. The big fixture makes
    // the content far taller than the viewport, so a real scroll has ample headroom
    // (moved is high-margin). Exactly one terminal line; all four booleans must hold.
    @Test func scrollWheelMovesViewportWhileFindPopupActive() throws {
        let fixture = try NativeGridFixture.path()
        let env = [
            "LESSSHEET_FIND": NativeGridFixture.markerTag, // known match -> a landing
            "LESSSHEET_FIND_SCROLL_ACTIVE": "1",
            "LESSSHEET_DUMP_EXIT": "1",
        ]

        var log = ""
        for _ in 1...2 { // relaunch only when the probe never reached its terminal line
            log = try AppProbe.launchOnce(fixture: fixture, env: env, timeout: 90)
            if !probeLines(log, prefix: "lesssheet.find.scroll_while_active ").isEmpty { break }
        }

        let lines = probeLines(log, prefix: "lesssheet.find.scroll_while_active ")
        #expect(lines.count == 1,
                "scroll-while-active probe must emit exactly one terminal line:\n\(logTail(log))")
        let line = lines.first
        #expect(line.flatMap { boolField($0, "probe_ready") } == true,
                "scroll-while-active probe must set up headless (live grid + scrim + wheel event):\n\(logTail(log))")
        #expect(line.flatMap { boolField($0, "moved") } == true,
                "a wheel event over the grid while the Find popup is open must MOVE the viewport:\n\(logTail(log))")
        #expect(line.flatMap { boolField($0, "search_active") } == true,
                "scrolling with the Find popup open must NOT clear the active search:\n\(logTail(log))")
        #expect(line.flatMap { boolField($0, "popup_active") } == true,
                "scrolling with the Find popup open must NOT dismiss the popup:\n\(logTail(log))")
    }

    // Selection-toggle lock (cc-macos defect pass): a second click on an already-
    // selected cell / whole row / whole column DESELECTS it. Driven through the
    // controller's event-free semantic seam (the SAME functions the shipping mouse
    // handlers call — no synthetic events, no TCC), so this pins the real toggle
    // wiring. SelectCopyProbe emits one `deselected=` line per form after first
    // paint; all three must be true. (Its sibling selection-repaint
    // `content_preserved` guard is deliberately NOT gated — it needs a materialized,
    // paged NSTableView row view, which an off-screen headless run never has at
    // probe time; it stays a reviewer/human visual check — see REVIEWER-MEASURED.)
    @Test func selectionSecondClickDeselectsCellRowAndColumn() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "people", withExtension: "csv", subdirectory: "Fixtures"),
            "missing fixture people.csv"
        )
        let env = ["LESSSHEET_SELECT_COPY": "1", "LESSSHEET_DUMP_EXIT": "1"]

        var log = ""
        for _ in 1...2 { // relaunch only when the probe sequence never reached its terminal line
            log = try AppProbe.launchOnce(fixture: fixtureURL.path(percentEncoded: false), env: env, timeout: 60)
            if !probeLines(log, prefix: "lesssheet.selectcopy.done ").isEmpty { break }
        }

        let forms: [(probe: String, label: String)] = [
            ("toggle_cell", "cell"),
            ("toggle_row", "whole row"),
            ("toggle_column", "whole column"),
        ]
        for form in forms {
            let line = probeLines(log, prefix: "lesssheet.selectcopy.\(form.probe) ").first
            #expect(line.flatMap { boolField($0, "deselected") } == true,
                    "second click on a selected \(form.label) must clear the selection:\n\(logTail(log))")
        }
    }

    // Equivalence pin (ARCH criterion 4): at-rest window-space frames — glass band
    // y[0,54], header y[32,54], row 1 y[54,76], scroll view top at 0 (the grid
    // extends under the transparent title bar) — the same numbers the current grid
    // logs, re-emitted by the new grid over AppKit frames in the identical format.
    // The LAST line per label is the settled (at-rest) frame; the app quits itself
    // well after settle under LESSSHEET_DUMP_EXIT. One relaunch absorbs a slow
    // settle; the pinned values themselves are never loosened.
    @Test func layoutFramesArePinnedAtRest() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "people", withExtension: "csv", subdirectory: "Fixtures"),
            "missing fixture people.csv"
        )
        let env = ["LESSSHEET_LOG_LAYOUT": "1", "LESSSHEET_DUMP_EXIT": "1"]
        let tolerance = 1.0
        let pins: [(label: String, minY: Double, maxY: Double)] = [
            ("band", 0, 54),
            ("header", 32, 54),
            ("row1", 54, 76),
        ]

        var failure: String?
        for attempt in 1...2 {
            let log = try AppProbe.launchOnce(
                fixture: fixtureURL.path(percentEncoded: false), env: env, timeout: 60
            )
            failure = nil
            for pin in pins {
                guard let line = probeLines(log, prefix: "lesssheet.layout.\(pin.label) ").last,
                      let minY = doubleField(line, "minY"),
                      let maxY = doubleField(line, "maxY"),
                      abs(minY - pin.minY) <= tolerance,
                      abs(maxY - pin.maxY) <= tolerance
                else {
                    failure = "attempt \(attempt): \(pin.label) at-rest frame must be "
                        + "y[\(pin.minY), \(pin.maxY)] ±\(tolerance):\n\(logTail(log))"
                    break
                }
            }
            if failure == nil {
                guard let scroll = probeLines(log, prefix: "lesssheet.layout.scrollview ").last,
                      let minY = doubleField(scroll, "minY"),
                      abs(minY) <= tolerance
                else {
                    failure = "attempt \(attempt): scrollview must start at the window top "
                        + "(grid extends under the title bar):\n\(logTail(log))"
                    continue
                }
                return // PASS
            }
        }
        #expect(Bool(false), Comment(rawValue: failure ?? "layout probe produced no verdict"))
    }

    // Config-repaint lock (cc-macos config-repaint defect pass): after a model-side
    // column-configuration edit made from the SEPARATE (key) Settings window, the
    // already-visible grid must update WITHOUT the user first clicking or scrolling
    // it — "stale until interaction" was the reported bug. The gateable, materialization-
    // INDEPENDENT seam this pins: the live grid controller's APPLIED column-configuration
    // revision must equal the model's current columnConfigurationRevision — proven
    // WITHOUT the probe ever calling apply() itself.
    //
    // WHY this is a true RED/GREEN lock (not merely a green regression guard): a headless
    // window gets NO implicit updateNSView (documented in HeaderToggleProbe), so the ONLY
    // thing that can call apply() after the edit is the fix's explicit
    // NativeGridController.live?.apply() poke inside the model's config mutators
    // (refreshAfterColumnConfiguration — setColumnFormat/setColumnOverride/
    // setColumnNullSentinel — plus toggleColumn / showAllColumns). WITHOUT that poke (the
    // original defect, or any regression of the fix) nothing applies the edit: the
    // controller's applied revision LAGS the model's -> applied=false -> RED. WITH the
    // poke, apply() unconditionally syncs lastColumnConfigurationRevision to the model's
    // current revision -> they match -> GREEN.
    //
    // MATERIALIZATION-INDEPENDENT: the probe compares two integers, never a paged
    // NSTableView row view, so it does NOT depend on any row being on-screen. That is
    // exactly why THIS repaint lock is gated while the sibling selection-repaint content
    // check (SelectCopyProbe's content_preserved) stays a human/reviewer pass — see
    // REVIEWER-MEASURED — an off-screen headless run never materializes a paged row view.
    //
    // The probe drives setColumnFormat(grouping: true) on people.csv's "age" column
    // (0-based column 1, integer) — the SAME model entry point the Settings inspector's
    // Thousands-grouping toggle calls — then reads both revisions in ONE synchronous
    // main-actor turn (the edit, incl. the poke, is fully synchronous), so this is an
    // exactness lock with no timing/flaky assert. model_rev > 0 pins that a real edit
    // happened (a vacuous 0 == 0 cannot pass); model_rev == controller_applied_rev is the
    // repaint. Retries only a MALFORMED run (terminal line absent = infra); a
    // present-but-wrong value fails immediately.
    @Test func columnConfigEditRepaintsGridWithoutInteraction() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "people", withExtension: "csv", subdirectory: "Fixtures"),
            "missing fixture people.csv"
        )
        let env = ["LESSSHEET_CONFIG_REPAINT": "1", "LESSSHEET_DUMP_EXIT": "1"]

        var log = ""
        for _ in 1...2 { // relaunch only when the probe never reached its terminal line
            log = try AppProbe.launchOnce(fixture: fixtureURL.path(percentEncoded: false), env: env, timeout: 60)
            if !probeLines(log, prefix: "lesssheet.configrepaint.result ").isEmpty { break }
        }

        let line = probeLines(log, prefix: "lesssheet.configrepaint.result ").first
        #expect(line != nil,
                "config-repaint probe emitted no terminal line (LESSSHEET_CONFIG_REPAINT not wired):\n\(logTail(log))")

        let modelRev = line.flatMap { intField($0, "model_rev") }
        let controllerRev = line.flatMap { intField($0, "controller_applied_rev") }

        #expect(line.flatMap { boolField($0, "applied") } == true,
                Comment(rawValue: "after a model-side column-config edit, the live grid controller must have "
                    + "APPLIED the model's current columnConfigurationRevision with no interaction (no scroll/click, "
                    + "and the probe never calls apply()):\n\(logTail(log))"))
        #expect((modelRev ?? 0) > 0,
                "the probe must drive a real config edit that bumps the revision (model_rev > 0):\n\(logTail(log))")
        #expect(modelRev != nil && modelRev == controllerRev,
                Comment(rawValue: "the grid controller's APPLIED config revision must equal the model's current "
                    + "revision (model_rev=\(modelRev.map(String.init) ?? "nil") "
                    + "controller_applied_rev=\(controllerRev.map(String.init) ?? "nil")):\n\(logTail(log))"))
    }
}
