import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the match-flags FETCH CADENCE — INERT
// unless LESSSHEET_MATCHFLAGS_FETCH is set. It locks ARCH-thin-frontend-shared-core
// Phase-1 AC5 ("one flags fetch per window materialization, NOT per repaint") and
// Round-2 finding 1 (a stale mask must never be served after a same-geometry
// content change), which the direct MatchFlagsBridgeTests (they call
// windowMatchFlags on the session, not through DocumentModel.highlights) can't see.
//
// It reads DocumentModel.matchFlagsFetchCount — a counter bumped ONLY on a real
// windowMatchFlags ABI fetch inside ensureMatchFlagsFresh (a cache MISS), never on
// a cache hit — around real highlight repaints (cellHighlights over the whole
// window, the same ensureMatchFlagsFresh path the live grid drives). No synthetic
// input events (no TCC prompt risk); no grid window required (highlights key off
// the materialized window, not the NSView).
//
//   LESSSHEET_MATCHFLAGS_FETCH=1  After first paint, seed a search and emit one
//     `lesssheet.matchflagsfetch.case name=<> fetches=<> expected=<> pass=<bool>`
//     line per case, then (under LESSSHEET_DUMP_EXIT) quit. Cases:
//       repaint_cadence     — N repaints of a fixed window fetch EXACTLY once (not N).
//       repaint_stable      — further repaints with no change fetch zero times.
//       refetch_same_geom   — a same-GEOMETRY, same-REQUEST re-materialize STILL
//                             refetches (LOCKS finding 1: geometry can't gate the
//                             cache; only the content epoch changed).
//       refetch_after_filter— a filter set+clear round-trip refetches (locks the
//                             filter-path content-epoch bumps).
@MainActor
enum MatchFlagsFetchProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_MATCHFLAGS_FETCH"] != nil

    private static let query = "a"       // activates a search; matches are not required
    private static let repaintN = 5      // "N repaints" for the cadence case
    private static var started = false
    private static var seeded = false
    private static var startTime = DispatchTime.now()

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    private static var gridWindowReady: Bool {
        NativeGridController.live?.container.window != nil
    }

    /// One "repaint": derive highlights for every materialized row (the same
    /// `ensureMatchFlagsFresh` path the live grid drives), so a stable window
    /// fetches at most once across all rows.
    private static func repaint(_ model: DocumentModel) {
        let first = Int(model.window.firstRow)
        let rowCount = model.window.rows.count
        guard rowCount > 0 else { return }
        for row in first..<(first + rowCount) { _ = model.cellHighlights(forRow: row) }
    }

    static func run(model: DocumentModel) {
        guard active, !started else { return }
        started = true
        startTime = DispatchTime.now()
        guard model.columnCount > 0 else {
            log("lesssheet.matchflagsfetch.skip reason=empty_document"); finish(); return
        }
        proceed(model: model, triesLeft: 400)
    }

    /// Wait for the grid, seed the search once, then wait for it to settle
    /// (progress cleared + a materialized window) before the synchronous cases,
    /// so no stray async landing perturbs the counts.
    private static func proceed(model: DocumentModel, triesLeft: Int) {
        func retry() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                proceed(model: model, triesLeft: triesLeft - 1)
            }
        }
        guard gridWindowReady || triesLeft <= 0 else { return retry() }
        if !seeded {
            seeded = true
            model.submitFindQuery(query)   // sets the active request synchronously; scan/landing are async
            return retry()
        }
        let settled = model.findSession.display.progress == nil && !model.window.rows.isEmpty
        guard settled || triesLeft <= 0 else { return retry() }
        runCases(model)
        finish()
    }

    private static func runCases(_ model: DocumentModel) {
        // --- repaint_cadence: N repaints of a FIXED window => exactly ONE fetch.
        // Re-materialize first so the very next repaint is a guaranteed cache miss,
        // then repaint N times; only the first should fetch.
        model.rematerializeSameWindowForProbe()
        model.resetMatchFlagsFetchCount()
        for _ in 0..<repaintN { repaint(model) }
        report("repaint_cadence", model.matchFlagsFetchCount, expected: 1, pass: model.matchFlagsFetchCount == 1)

        // --- repaint_stable: further repaints with NO change => ZERO fetches.
        model.resetMatchFlagsFetchCount()
        for _ in 0..<repaintN { repaint(model) }
        report("repaint_stable", model.matchFlagsFetchCount, expected: 0, pass: model.matchFlagsFetchCount == 0)

        // --- refetch_same_geom (LOCKS finding 1): a same-GEOMETRY, same-REQUEST
        // re-materialize MUST refetch. Geometry + request are byte-identical to the
        // stable state above; only the content epoch differs — so a key that keyed
        // off geometry+request alone would (wrongly) serve the stale mask here.
        model.resetMatchFlagsFetchCount()
        model.rematerializeSameWindowForProbe()
        repaint(model)
        report("refetch_same_geom", model.matchFlagsFetchCount, expected: 1, pass: model.matchFlagsFetchCount >= 1)

        // --- refetch_after_filter: a filter set + clear round-trip (each bumps the
        // content epoch) then a re-search refetches. Locks the filter-path bumps.
        model.resetMatchFlagsFetchCount()
        model.applyFindAsFilter()          // bumps epoch; nils the find request
        model.clearFilter()                // bumps epoch; restores the identity view
        model.submitFindQuery(query)       // re-activate the search
        repaint(model)
        report("refetch_after_filter", model.matchFlagsFetchCount, expected: 1, pass: model.matchFlagsFetchCount >= 1)
    }

    private static func report(_ name: String, _ fetches: Int, expected: Int, pass: Bool) {
        log("lesssheet.matchflagsfetch.case name=\(name) fetches=\(fetches)"
            + " expected=\(expected) pass=\(pass) at_ms=\(elapsedMs())")
    }

    private static func finish() {
        log("lesssheet.matchflagsfetch.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
