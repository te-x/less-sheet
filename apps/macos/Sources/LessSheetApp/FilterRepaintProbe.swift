import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the filter-repaint defect-pass — INERT
// unless LESSSHEET_FILTER_REPAINT is set, so it costs nothing in normal use and
// never touches the < 500 ms cold-start measurement (it starts only after the
// first data-bearing frame). Mirrors ConfigRepaintProbe: drive the REAL model
// entry point the Find popup's "Filter to matches" toggle ultimately calls
// (`DocumentModel.applyFindAsFilter`) DIRECTLY — no synthetic input events (no
// TCC prompt risk) — then prove the fix headlessly.
//
// The bug: toggling "Filter to matches" ON repainted the grid only after a
// scroll. Root cause: applyFindAsFilter/clearFilter set the @Observable filter
// state and scheduled an ASYNC landing apply, but when the filter is applied
// while already at the top (landing row 0 == the current top), that apply
// produces no scroll and AppKit defers the row/gutter redraw until this window
// next handles an event — the reported "shows only after a scroll". The fix adds
// an explicit synchronous `NativeGridController.live?.apply()` poke (the same
// remedy the column-config mutators use).
//
// The MATERIALIZATION-INDEPENDENT seam this locks: after the model-side toggle,
// the controller's APPLIED filter state (`appliedFilterState`) must equal the
// model's current `isFiltered` — proven WITHOUT this probe ever calling apply().
// Remove the poke and, in a headless window (no implicit updateNSView; the async
// landing apply runs on a LATER main-actor turn, AFTER this synchronous read),
// nothing applies the toggle -> the controller's applied state LAGS the model's
// -> applied=false -> RED.
//
//   LESSSHEET_FILTER_REPAINT=<query>   After first paint, seed the find draft
//     with <query> (Text mode) and apply it as a filter once, then read both
//     states in the SAME synchronous main-actor turn (the toggle + its poke are
//     fully synchronous — NO await/DispatchQueue hop between the toggle and the
//     read, so a stray apply can never interleave and mask a missing poke), emit
//     one terminal line, then (under LESSSHEET_DUMP_EXIT) quit. A bare "1"
//     (or empty) falls back to the query "a".
//
// WINDOW-READINESS WAIT (before the toggle, never within it): identical to
// ConfigRepaintProbe — the live grid controller attaches to its window a runloop
// turn AFTER makeNSView, and apply() is a no-op until then. This probe waits —
// off the toggle path — for window attachment; the wait never calls apply(), and
// in the RED (no-poke) case a window-attached apply() still never runs, so the
// wait cannot mask a missing poke.
@MainActor
enum FilterRepaintProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_FILTER_REPAINT"] != nil

    /// The find query applied as a filter — a bare "1" or empty falls back to a
    /// substring that matches at least one row of the standard fixtures.
    private static var query: String {
        let raw = env["LESSSHEET_FILTER_REPAINT"] ?? ""
        return (raw.isEmpty || raw == "1") ? "a" : raw
    }

    private static var started = false
    private static var t0 = DispatchTime.now()

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000)
    }

    /// Whether the live grid controller is attached to a window — the state in
    /// which its `apply()` poke actually does work (mirrors apply()'s own
    /// `container.window != nil` guard, WITHOUT calling apply()).
    private static var gridWindowReady: Bool {
        NativeGridController.live?.container.window != nil
    }

    static func run(model: DocumentModel) {
        guard active, !started else { return }
        started = true
        t0 = DispatchTime.now()

        guard model.columnCount > 0 else {
            log("lesssheet.filterrepaint.skip reason=empty_document")
            finish()
            return
        }
        performWhenReady(model: model, triesLeft: 300)
    }

    /// Waits (off the toggle path) for the live grid controller to be
    /// window-attached, then drives the toggle + reads both states in ONE
    /// synchronous main-actor turn. The retry hop is only BEFORE the toggle.
    private static func performWhenReady(model: DocumentModel, triesLeft: Int) {
        guard gridWindowReady || triesLeft <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                performWhenReady(model: model, triesLeft: triesLeft - 1)
            }
            return
        }

        // The REAL toggle path: seed the find draft exactly as typing <query> in
        // the Text field, then apply it as a filter — the SAME model entry point
        // the "Filter to matches" toggle's binding calls (`applyFindAsFilter`,
        // incl. the fix's explicit `NativeGridController.live?.apply()` poke).
        model.openFindField()
        model.findSession.draft.mode = .text
        model.findSession.draft.text = query
        model.applyFindAsFilter()

        // SAME synchronous main-actor turn (no await, no DispatchQueue between
        // the toggle above and these reads): the probe NEVER calls apply() — the
        // model's mutator is the only thing that can have poked the controller.
        let modelFiltered = model.isFiltered
        let controllerFiltered = NativeGridController.live?.appliedFilterState ?? false
        let applied = (controllerFiltered == modelFiltered)

        log("lesssheet.filterrepaint.result model_filtered=\(modelFiltered)"
            + " controller_applied_filtered=\(controllerFiltered) applied=\(applied)"
            + " query=\(query) at_ms=\(elapsedMs())")
        finish()
    }

    private static func finish() {
        log("lesssheet.filterrepaint.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
