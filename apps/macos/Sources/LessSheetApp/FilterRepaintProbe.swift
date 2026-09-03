import AppKit
import Contracts
import Foundation

// The filter twin of ConfigRepaintProbe: locks that toggling "Filter to matches"
// repaints the grid itself rather than waiting for a scroll. Inert unless
// LESSSHEET_FILTER_REPAINT is set, armed only after the first data-bearing frame,
// and it drives the real model entry point with no synthetic input events.
//
// The seam is materialization-independent in the same way: after the toggle, the
// controller's APPLIED filter state must equal the model's — proven without this
// probe ever calling apply(). Remove the poke and, in a headless window, the
// async landing apply runs on a LATER turn than this synchronous read, so the
// applied state lags and this goes red.
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

    /// `LESSSHEET_FILTER_WHERE=<header>=<value>` switches the probe from a text
    /// filter to a COLUMN PREDICATE, e.g. `city=Lisbon`.
    ///
    /// Resolves the column by its HEADER TEXT rather than an index on purpose:
    /// an index silently points at a different column the moment the fixture
    /// gains a field, and the screenshot would still look plausible — filtered
    /// rows, a correct pill, the wrong column. Returns nil when the variable is
    /// absent or names a header this document does not have, in which case the
    /// probe keeps its original text-filter behaviour.
    @MainActor
    private static func predicate(model: DocumentModel) -> (column: Int, value: String)? {
        guard let raw = env["LESSSHEET_FILTER_WHERE"],
              let split = raw.firstIndex(of: "=") else { return nil }
        let header = String(raw[raw.startIndex..<split])
        let value = String(raw[raw.index(after: split)...])
        guard !header.isEmpty, !value.isEmpty else { return nil }
        let labels = (0..<model.columnCount).map { model.columnLabel($0) }
        guard let column = labels.firstIndex(where: {
            $0.compare(header, options: .caseInsensitive) == .orderedSame
        }) else {
            log("lesssheet.filterrepaint.where_unknown_column header=\(header)"
                + " available=\(labels.prefix(12).joined(separator: ","))")
            return nil
        }
        return (column, value)
    }

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

    static func run(model: DocumentModel) {
        guard active, !started else { return }
        started = true
        startTime = DispatchTime.now()

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
        if let (column, value) = predicate(model: model) {
            // "Where" mode: a COLUMN PREDICATE, not a text match filtered to
            // hits. The two look nearly identical on screen otherwise — the
            // first screenshot set shipped two images that differed only by the
            // "Filter to matches" switch, so the predicate feature was never
            // actually pictured. Same submit path as the UI (`applyFindAsFilter`
            // reads the draft), only the draft's mode differs.
            model.findSession.draft.mode = .predicate
            model.findSession.draft.column = column
            model.findSession.draft.comparison = .equals
            model.findSession.draft.value = value
        } else {
            model.findSession.draft.mode = .text
            model.findSession.draft.text = query
        }
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
