import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the search-escape defect-pass — INERT
// unless LESSSHEET_FIND_ESCAPE is set. Proves the "escape from search" path:
// once a find is open (the common stuck case is focus having left the popup
// field — the user clicked a cell after searching, so Esc reaches the GRID, not
// the popup), pressing Esc while the grid is first responder must close the find
// popup and clear its highlights.
//
// The bug: `SheetTableView.cancelOperation` (Esc while the grid is first
// responder) only cancelled an in-flight copy; it never closed an open find, so
// a search that had lost field focus was undismissable by Esc. The fix routes
// `cancelOperation` -> `NativeGridController.handleEscape`, which dismisses an
// open find/jump/dialect popup (clearing an active search), else cancels a copy.
//
// The seam this locks: with a find open + active, driving the controller's
// `handleEscape` (exactly what the grid's Esc key binding now calls) must leave
// `findFieldActive == false` AND the find request cleared (highlights gone) —
// WITHOUT touching the popup field's own onExitCommand path (which only fires
// when the FIELD holds focus).
//
//   LESSSHEET_FIND_ESCAPE=<query>   After first paint, run <query> through the
//     real find path, then invoke the grid's Esc handler and report whether the
//     find closed + cleared. A bare "1"/empty falls back to "a".
@MainActor
enum FindEscapeProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_FIND_ESCAPE"] != nil

    private static var query: String {
        let raw = env["LESSSHEET_FIND_ESCAPE"] ?? ""
        return (raw.isEmpty || raw == "1") ? "a" : raw
    }

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
        performWhenReady(model: model, triesLeft: 300)
    }

    private static func performWhenReady(model: DocumentModel, triesLeft: Int) {
        guard gridWindowReady || triesLeft <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                performWhenReady(model: model, triesLeft: triesLeft - 1)
            }
            return
        }

        // Open + run a real search (findFieldActive = true, request set — the
        // grid highlights are live). This is exactly typing <query> + Enter.
        model.submitFindQuery(query)
        let openBefore = model.findFieldActive
        let requestBefore = model.findSession.display.request != nil

        // Esc while the GRID is first responder: the exact call the grid's
        // cancelOperation key binding now makes. The probe drives it directly —
        // no synthetic key event (no input-monitoring permission involved).
        NativeGridController.live?.handleEscape()

        let openAfter = model.findFieldActive
        let requestAfter = model.findSession.display.request != nil
        let escaped = !openAfter && !requestAfter

        log("lesssheet.findescape.result open_before=\(openBefore) request_before=\(requestBefore)"
            + " open_after=\(openAfter) request_after=\(requestAfter) escaped=\(escaped)"
            + " query=\(query) at_ms=\(elapsedMs())")
        finish()
    }

    private static func finish() {
        log("lesssheet.findescape.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
