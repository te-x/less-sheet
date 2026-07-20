import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the repaint-family AUDIT — INERT unless
// LESSSHEET_REPAINT_AUDIT is set. For each cell-painting model mutation below it
// reads the controller's `applyTick` DELTA across the SINGLE synchronous mutation
// call: delta >= 1 means the mutation drove a repaint itself (an explicit
// `NativeGridController.live?.apply()` poke — INSTANT), delta == 0 means it left
// the redraw to the next event/scroll (the "repaints only on scroll" family).
//
// This does NOT call apply() itself; it only observes the tick the model's own
// mutators bump. It answers "which interactions are (or might be) not instant?"
// deterministically, with no synthetic input events (no TCC prompt risk).
//
//   LESSSHEET_REPAINT_AUDIT=1   After first paint, drive each mutation once and
//     emit one `lesssheet.repaintaudit.case name=<> delta=<> instant=<>` line per
//     case, then (under LESSSHEET_DUMP_EXIT) quit.
@MainActor
enum RepaintAuditProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_REPAINT_AUDIT"] != nil

    private static var started = false
    private static var startTime = DispatchTime.now()

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    private static var gridWindowReady: Bool {
        NativeGridController.live?.container.window != nil
    }

    static func run(model: DocumentModel) {
        guard active, !started else { return }
        started = true
        startTime = DispatchTime.now()
        guard model.columnCount > 0 else {
            log("lesssheet.repaintaudit.skip reason=empty_document"); finish(); return
        }
        performWhenReady(model: model, triesLeft: 300)
    }

    /// Measures the applyTick delta across `mutate()` — a single synchronous
    /// model call. Uses the value captured immediately BEFORE the call, so any
    /// earlier async landing apply is already counted and cannot inflate it.
    private static func measure(_ name: String, _ mutate: () -> Void) {
        let before = NativeGridController.live?.applyTick ?? -1
        mutate()
        let after = NativeGridController.live?.applyTick ?? -1
        let delta = after - before
        log("lesssheet.repaintaudit.case name=\(name) delta=\(delta)"
            + " instant=\(delta >= 1) at_ms=\(elapsedMs())")
    }

    private static func performWhenReady(model: DocumentModel, triesLeft: Int) {
        guard gridWindowReady || triesLeft <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                performWhenReady(model: model, triesLeft: triesLeft - 1)
            }
            return
        }

        // Baseline: a known-poked mutation must read instant=true (proves the
        // tick seam itself works). Column format edit -> refreshAfterColumnConfiguration.
        let col = model.columnCount > 1 ? 1 : 0
        measure("setColumnFormat") { model.setColumnFormat(ColumnFormatOptions(grouping: true), column: col) }

        // Filter apply / clear (already fixed — expect instant=true).
        model.openFindField()
        model.findSession.draft.mode = .text
        model.findSession.draft.text = "a"
        measure("applyFindAsFilter") { model.applyFindAsFilter() }
        measure("clearFilter") { model.clearFilter() }

        // The audit target: closeFind clears all find highlights. Seed an active
        // search first (its landing settles), then measure the close.
        model.submitFindQuery("a")
        measure("closeFind_clearsHighlights") { model.closeFind() }

        // cancelFind: stops a scan; highlights are RETAINED, so a missing repaint
        // is far less visible — measured for completeness.
        model.submitFindQuery("a")
        measure("cancelFind") { model.cancelFind() }

        // A NEW search whose query finds NO match, replacing prior highlights:
        // no found landing, so (like closeFind) there is no scroll to carry the
        // repaint that must ERASE the old highlights. Seed a matching search
        // first so there ARE prior highlights to clear.
        model.submitFindQuery("a")
        measure("submitFind_noMatch_clearsPriorHighlights") {
            model.findSession.draft.mode = .text
            model.findSession.draft.text = "zzq_no_such_match_qzz"
            model.submitFind()
        }

        finish()
    }

    private static func finish() {
        log("lesssheet.repaintaudit.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
