import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the jump field's ARROW-KEY STEPPING
// (↑/↓ while the ⌘J popup is open) — INERT unless the environment variable is
// set, so it costs nothing in normal use and can never touch the < 500 ms
// cold-start measurement (it starts only after the first data-bearing frame).
//
//   LESSSHEET_JUMP_STEP=1   After first paint, drive the REAL entry points and
//     log a pass/fail line per property:
//       · DIRECTION       ↑ decrements, ↓ increments (the deliberate inversion).
//       · WRAP            ↑ from row 1 → the last row; ↓ from the last row → 1.
//       · ESTIMATE WRAP   the same wrap against a NON-exact row count, whose
//                         estimate is the boundary (no scan is forced).
//       · SEED            an empty field steps from the top visible row.
//       · NO LANDING      firstVisibleRow / pendingScrollRow / jumpFlow are
//                         untouched by any number of arrow presses.
//       · ENTER           submitting the STEPPED text still jumps, landing on
//                         exactly that row.
//       · KEY ROUTING     a real ↑/↓ NSEvent, posted in-process (never through
//                         CGEvent, so no input-monitoring permission is
//                         involved), reaches the field's handler; the same key
//                         with the popup CLOSED changes nothing.
//     Ends with a summary line (`checks=` / `failures=`) and, under
//     LESSSHEET_DUMP_EXIT, quits the headless instance.

@MainActor
enum JumpStepProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active: Bool = env["LESSSHEET_JUMP_STEP"] != nil

    static var checks = 0
    static var failures = 0

    static func run(model: DocumentModel) {
        guard active else { return }
        let info = model.jumpRowCountInfo
        log("lesssheet.jumpstep.start rows=\(info.count) exact=\(info.isExact)"
            + " top_row_1based=\(model.jumpFieldSeedRow) unknown_total=\(model.documentTotalUnknown)")
        closedFieldIsInert(model)
        directionAndWrap(model)
        estimateWrap(model)
        seedFromTopVisibleRow(model)
        enterSubmitsSteppedValue(model)
    }

    // MARK: - Model-level properties (deterministic, no key events)

    /// Arrows must do NOTHING while the popup is closed — the grid keeps its own
    /// arrow navigation.
    private static func closedFieldIsInert(_ model: DocumentModel) {
        model.jumpFieldActive = false
        model.jumpFieldText = ""
        model.stepJumpField(.towardEnd)
        model.stepJumpField(.towardStart)
        expect("closed_inert", model.jumpFieldText, "")
    }

    /// ↑ DECREASES the number, ↓ INCREASES it, and each wraps at its end — all
    /// with the viewport and the jump flow provably untouched.
    private static func directionAndWrap(_ model: DocumentModel) {
        model.openJumpField()
        let lastRow = String(max(1, model.jumpRowCountInfo.count))
        let beforeTop = model.firstVisibleRow
        let beforeScroll = model.pendingScrollRow
        let beforeFlow = flowName(model.jumpFlow)

        expect("up_decrements", step(model, from: "5", .towardStart), "4")
        expect("down_increments", step(model, from: "5", .towardEnd), "6")
        expect("up_wraps_to_last", step(model, from: "1", .towardStart), lastRow)
        expect("down_wraps_to_first", step(model, from: lastRow, .towardEnd), "1")

        let landed = beforeTop == model.firstVisibleRow
            && beforeScroll == model.pendingScrollRow
            && beforeFlow == flowName(model.jumpFlow)
        expect("no_landing", String(landed), "true",
               extra: "top=\(model.firstVisibleRow) pending=\(model.pendingScrollRow.map(String.init) ?? "nil")"
                   + " flow=\(flowName(model.jumpFlow))")
    }

    /// With the count still an ESTIMATE the wrap uses that estimate as the
    /// boundary rather than refusing or forcing a scan. Drives a non-exact count
    /// the fixture would otherwise settle too fast to exhibit, then restores it.
    private static func estimateWrap(_ model: DocumentModel) {
        let real = model.rowCountInfo
        model.rowCountInfo = RowCountInfo(count: 4242, isExact: false)
        expect("estimate_up_wraps", step(model, from: "1", .towardStart), "4242",
               extra: "exact=\(model.jumpRowCountInfo.isExact)")
        expect("estimate_down_wraps", step(model, from: "4242", .towardEnd), "1",
               extra: "exact=\(model.jumpRowCountInfo.isExact)")
        expect("estimate_up_steps", step(model, from: "4242", .towardStart), "4241")
        model.rowCountInfo = real
    }

    /// An empty field steps from the TOP VISIBLE row (the number the gutter shows
    /// for it), not from row 1 or from nothing.
    private static func seedFromTopVisibleRow(_ model: DocumentModel) {
        let seed = model.jumpFieldSeedRow
        let bound = max(1, model.jumpRowCountInfo.count)
        let wantDown = String(seed >= bound ? 1 : seed + 1)
        let wantUp = String(seed <= 1 ? bound : seed - 1)
        expect("seed_down", step(model, from: "", .towardEnd), wantDown, extra: "seed=\(seed)")
        expect("seed_up", step(model, from: "", .towardStart), wantUp, extra: "seed=\(seed)")
        // Anything the submit path would reject seeds the same way.
        expect("seed_unparsable", step(model, from: "not-a-row", .towardEnd), wantDown, extra: "seed=\(seed)")
    }

    /// Enter still submits — of the STEPPED value, landing on exactly that row.
    /// The proof is the jump flow's own terminal row (0-based), not
    /// `firstVisibleRow`: a document whose rows all fit the window cannot scroll,
    /// so the viewport legitimately stays at the top even after landing (the
    /// scroll mechanics themselves are what LESSSHEET_JUMP already covers).
    private static func enterSubmitsSteppedValue(_ model: DocumentModel) {
        let target = step(model, from: "41", .towardEnd)      // "42"
        let accepted = model.submitJump(model.jumpFieldText)   // identical to onSubmit
        expect("enter_accepts_stepped", String(accepted), "true", extra: "text=\(target)")
        after(0.6) {
            // 1-based "42" is 0-based row 41.
            expect("enter_lands_on_stepped", flowName(model.jumpFlow), "landed(41)",
                   extra: "stepped_text=\(target)")
            seedFollowsViewport(model)
            heldArrowCycles(model)
            keyRouting(model)
        }
    }

    /// The seed TRACKS the viewport: the jump landed on 0-based row 41, which
    /// parks that row at the top of the data area, so an empty field must now
    /// step from 42 (1-based) — 43 after one ↓ — and not from 1. The expected
    /// number comes from the LANDED row, not from the seed accessor, so a seed
    /// wired to a stale or hardcoded row fails here. Skipped (never faked) if the
    /// clip did not actually park there — a short document cannot scroll that far.
    private static func seedFollowsViewport(_ model: DocumentModel) {
        let gridTop = NativeGridController.live?.currentTopDataRow()
        guard gridTop == 41 else {
            log("lesssheet.jumpstep.seed_follows_viewport skipped grid_top_0based=\(gridTop.map(String.init) ?? "nil")"
                + " paging_top_0based=\(model.firstVisibleRow) seed=\(model.jumpFieldSeedRow)")
            return
        }
        model.openJumpField()
        expect("seed_follows_viewport", step(model, from: "", .towardEnd), "43",
               extra: "seed=\(model.jumpFieldSeedRow) grid_top_0based=41 paging_top_0based=\(model.firstVisibleRow)")
    }

    /// A HELD arrow: 200 consecutive presses walk the number and wrap cleanly
    /// (two full cycles of a 100-row document land back where they started), and
    /// the whole burst costs no core work — the elapsed time is the evidence that
    /// stepping is independent of document size.
    private static func heldArrowCycles(_ model: DocumentModel) {
        model.openJumpField()
        let bound = max(1, model.jumpRowCountInfo.count)
        model.jumpFieldText = "1"
        let started = DispatchTime.now()
        for _ in 0..<200 { model.stepJumpField(.towardEnd) }
        let elapsedUs = (DispatchTime.now().uptimeNanoseconds &- started.uptimeNanoseconds) / 1000
        let expected = 1 + (200 % Int(min(bound, UInt64(Int.max))))
        expect("held_200_steps", model.jumpFieldText, String(expected),
               extra: "rows=\(bound) elapsed_us=\(elapsedUs) flow=\(flowName(model.jumpFlow))")
    }

    // MARK: - Real key events (in-process; no CGEvent, no permission prompt)

    /// Prove the arrow keys actually REACH the field's handler: open + focus the
    /// popup the ⌘J way, post a genuine ↓ then ↑ keyDown into the app's own event
    /// queue, and read the field back.
    private static func keyRouting(_ model: DocumentModel) {
        model.jumpFieldText = "10"
        model.requestJumpFocus()
        after(0.5) {
            post(arrow: .downward)
            after(0.35) {
                expect("key_down_routed", model.jumpFieldText, "11",
                       extra: "focus=\(firstResponderName())")
                post(arrow: .upward)
                after(0.35) {
                    expect("key_up_routed", model.jumpFieldText, "10")
                    closedKeyIsInert(model)
                }
            }
        }
    }

    /// The same key with the popup CLOSED must leave the field alone (and the
    /// grid free to navigate — its selection is logged as an observation).
    private static func closedKeyIsInert(_ model: DocumentModel) {
        model.dismissPopups()
        if let controller = NativeGridController.live {
            controller.container.window?.makeFirstResponder(controller.table)
        }
        after(0.3) {
            let selectionBefore = selectionName(model.selection)
            post(arrow: .downward)
            after(0.35) {
                expect("key_closed_inert", model.jumpFieldText, "10",
                       extra: "active=\(model.jumpFieldActive) focus=\(firstResponderName())")
                log("lesssheet.jumpstep.grid_selection before=\(selectionBefore)"
                    + " after=\(selectionName(model.selection))")
                rampPhase(model)
            }
        }
    }

    private enum Arrow {
        case upward, downward

        /// AppKit's function-key scalar + hardware key code for the arrow.
        var characters: String {
            let code = UInt32(self == .upward ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)
            return UnicodeScalar(code).map(String.init) ?? ""
        }

        var keyCode: UInt16 { self == .upward ? 126 : 125 }
    }

    /// Post a real arrow keyDown/keyUp pair into this app's OWN event queue —
    /// `NSApp.postEvent` (never `CGEvent.post`), so the full dispatch path runs
    /// without any input-monitoring permission being involved.
    private static func post(arrow: Arrow) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            log("lesssheet.jumpstep.post_failed reason=no_window")
            return
        }
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: phase, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: arrow.characters,
                charactersIgnoringModifiers: arrow.characters, isARepeat: false, keyCode: arrow.keyCode
            ) else {
                log("lesssheet.jumpstep.post_failed reason=no_event")
                return
            }
            NSApp.postEvent(event, atStart: false)
        }
    }

    // MARK: - Reporting

    /// One deliberate TAP: `endJumpFieldHold` first, so every single-step check
    /// below is about the step-1 rule and not about how fast the probe happens to
    /// run (the hold ramp is exercised separately, in `JumpStepProbe+Ramp`).
    static func step(_ model: DocumentModel, from text: String, _ direction: JumpFieldStep) -> String {
        model.jumpFieldText = text
        model.endJumpFieldHold()
        model.stepJumpField(direction)
        return model.jumpFieldText
    }

    static func expect(_ name: String, _ got: String, _ want: String, extra: String = "") {
        checks += 1
        let passed = got == want
        if !passed { failures += 1 }
        log("lesssheet.jumpstep.\(name) got=\(got) want=\(want) pass=\(passed)"
            + (extra.isEmpty ? "" : " \(extra)"))
    }

    static func finish() {
        log("lesssheet.jumpstep.summary checks=\(checks) failures=\(failures) pass=\(failures == 0)")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            after(0.2) { NSApp.terminate(nil) }
        }
    }

    static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    private static func flowName(_ flow: JumpFlow) -> String {
        switch flow {
        case .idle: "idle"
        case let .scanning(target, _, _): "scanning(\(target))"
        case let .landed(row): "landed(\(row))"
        case let .cancelled(row): "cancelled(\(row))"
        }
    }

    private static func selectionName(_ selection: Selection?) -> String {
        guard let selection else { return "none" }
        return "r\(selection.active.row)c\(selection.active.column)"
    }

    private static func firstResponderName() -> String {
        guard let responder = NSApp.keyWindow?.firstResponder else { return "none" }
        return String(describing: type(of: responder))
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
