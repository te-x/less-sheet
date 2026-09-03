import AppKit
import Contracts
import Foundation

// Locks the rule that a column-config edit repaints the grid ITSELF rather than
// waiting for the user's next click or scroll. Inert unless
// LESSSHEET_CONFIG_REPAINT is set, and armed only after the first data-bearing
// frame, so it never touches the cold-start measurement. It drives the real model
// entry point the Settings inspector calls, with no synthetic input events.
//
// The seam is deliberately materialization-independent: after the model-side
// edit, the controller's APPLIED revision must equal the model's current one —
// proven without this probe ever calling apply() itself. Remove the mutator's
// explicit poke and, in a headless window where no implicit update fires, the
// applied revision lags and this goes red.
//
//   LESSSHEET_CONFIG_REPAINT=1   After first paint, drive ONE real column-config
//     edit once and read both revisions in the SAME synchronous main-actor turn
//     (the edit + its poke are fully synchronous — NO await/DispatchQueue hop
//     between the edit and the read, so a stray apply can never interleave and
//     mask a missing poke), emit one terminal line, then (under
//     LESSSHEET_DUMP_EXIT) quit.
//
// WINDOW-READINESS WAIT (before the edit, never within it): the live grid
// controller attaches to its window a runloop turn AFTER makeNSView (see
// NativeGrid.makeNSView's deferred makeFirstResponder), and apply() is a no-op
// until then (`guard built, container.window != nil`). This probe fires from the
// first-paint .task, which races that attachment, so it waits — off the edit
// path — for the controller to be window-attached, exactly the state a real
// Settings-window edit always finds. The wait is purely a readiness gate: it
// never calls apply(), and in the RED (no-poke) case a window-attached apply()
// still never runs, so the wait cannot mask a missing poke.
@MainActor
enum ConfigRepaintProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_CONFIG_REPAINT"] != nil

    private static var started = false
    private static var startTime = DispatchTime.now()

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    /// Whether the live grid controller is attached to a window — the state in
    /// which its `apply()` poke actually does work (mirrors apply()'s own
    /// `container.window != nil` guard, WITHOUT calling apply()).
    private static var gridWindowReady: Bool {
        NativeGridController.live?.container.window != nil
    }

    /// Called from the first data-bearing frame's task (after the cold-start
    /// marker). One-shot; delegates to `performEdit` once the grid is
    /// window-attached.
    static func run(model: DocumentModel) {
        guard active, !started else { return }
        started = true
        startTime = DispatchTime.now()

        guard model.columnCount > 0 else {
            log("lesssheet.configrepaint.skip reason=empty_document")
            finish()
            return
        }
        performEditWhenReady(model: model, triesLeft: 300)
    }

    /// Waits (off the edit path) for the live grid controller to be
    /// window-attached, then drives the edit + reads both revisions in ONE
    /// synchronous main-actor turn. The retry hop is only BEFORE the edit — the
    /// edit→read block below has no await/DispatchQueue between its two reads.
    private static func performEditWhenReady(model: DocumentModel, triesLeft: Int) {
        guard gridWindowReady || triesLeft <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                performEditWhenReady(model: model, triesLeft: triesLeft - 1)
            }
            return
        }

        // people.csv's "age" column (0-based column 1, integer) when present;
        // a single-column document falls back to column 0.
        let column = model.columnCount > 1 ? 1 : 0

        // The REAL edit — the SAME model entry point the Settings inspector's
        // "Thousands grouping" toggle calls. `setColumnFormat` ->
        // `refreshAfterColumnConfiguration` (incl. the fix's explicit
        // `NativeGridController.live?.apply()` poke) is fully synchronous.
        model.setColumnFormat(ColumnFormatOptions(grouping: true), column: column)

        // SAME synchronous main-actor turn (no await, no DispatchQueue between
        // the edit above and these reads): the probe NEVER calls apply() — the
        // model's mutator is the only thing that can have poked the controller.
        let modelRev = model.columnConfigurationRevision
        let controllerRev = NativeGridController.live?.appliedColumnConfigurationRevision ?? -1
        let applied = (controllerRev == modelRev)

        log("lesssheet.configrepaint.result model_rev=\(modelRev)"
            + " controller_applied_rev=\(controllerRev) applied=\(applied)"
            + " column=\(column) at_ms=\(elapsedMs())")
        finish()
    }

    private static func finish() {
        log("lesssheet.configrepaint.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
