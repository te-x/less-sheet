import AppKit
import Foundation

// Verification-only instrumentation for the estimate-refinement / elastic-
// overscroll collision (the "flashes / resets and resumes during the first
// few seconds" bug): for a while after opening a large file the background
// indexer refines `DocumentModel.rowCountInfo` on or near every 100 ms poll
// tick (see `DocumentModel.startPolling`), and each refinement drives
// `NativeGridController.apply()` to re-sync the scrollbar via a `reloadData`
// + clip-origin restore (REVIEW-7: sanctioned over `noteNumberOfRowsChanged`,
// which is O(row-count delta) on a huge table). Doing that WHILE the clip is
// mid an elastic rubber-band bounce (a live drag past the top/left edge, or
// its spring bounce-back still returning) resets/resumes the bounce — the
// reported flash. Both hooks below are INERT unless their env var is set, so
// they cost nothing in normal use and never touch the < 500 ms cold-start
// measurement (armed only after the live grid is built).
//
//   LESSSHEET_LOG_ESTIMATE=1   Log every row-count-estimate reload decision
//     `NativeGridController.syncRowCountEstimate` makes — applied
//     immediately, or deferred because the clip is beyond its natural range
//     on either axis — with the clip's current origin. This is the
//     applied/overscroll correlation the fix must break: `applied=true`
//     must never coincide with `overscroll_x=true` or `overscroll_y=true`.
//
//   LESSSHEET_SIMULATE_OVERSCROLL=top|left   Headless proxy for a HELD
//     elastic bounce, without any synthetic input event / TCC prompt: once
//     the live grid is built, force the clip just beyond the named edge
//     (nothing else moves it afterwards — a static hold, like a finger held
//     past the edge) for LESSSHEET_SIMULATE_OVERSCROLL_MS (default 4000,
//     matching the reported 3-5 s window) while the REAL background indexer
//     keeps refining the estimate and driving `apply()`, then release back
//     to the resting top-left, log the release marker, and quit shortly
//     after so a follow-up (flushed) reload's timing is observable — a
//     self-contained run that does not depend on LESSSHEET_DUMP_EXIT (the
//     app's first-paint hook would otherwise consume that to quit almost
//     immediately, well before the hold completes). Combine with
//     LESSSHEET_LOG_ESTIMATE=1 to see the correlation directly.
@MainActor
enum EstimateReloadProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let logEnabled = env["LESSSHEET_LOG_ESTIMATE"] != nil
    private static let simulateEdge = env["LESSSHEET_SIMULATE_OVERSCROLL"]?.lowercased()

    private static let start = DispatchTime.now()
    private static var armed = false

    private static func elapsedMs() -> Int {
        // Read the lazily-initialized `start` BEFORE calling `.now()` for the
        // current time: evaluating them in the other order (as a single
        // subtraction expression) risks initializing `start` to a time AFTER
        // the already-evaluated "now" on the very first call — an `&-`
        // underflow (a huge bogus elapsed value) rather than a small one.
        let t0 = start
        return Int((DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000)
    }

    /// Logs one reload decision (called from `NativeGridController.syncRowCountEstimate`).
    static func noteDecision(
        applied: Bool, rows: Int, lastRows: Int, origin: CGPoint, overscrollX: Bool, overscrollY: Bool
    ) {
        guard logEnabled else { return }
        FileHandle.standardError.write(Data(String(
            format: "lesssheet.estimate.reload applied=\(applied) rows=%d last=%d"
                + " overscroll_x=\(overscrollX) overscroll_y=\(overscrollY)"
                + " origin_x=%.1f origin_y=%.1f at_ms=%d\n",
            rows, lastRows, origin.x, origin.y, elapsedMs()
        ).utf8))
    }

    /// Logs a stranded-past-EOF re-anchor (`NativeGridController.
    /// reanchorIfStrandedPastNewEnd`, the estimate-COLLAPSE fix): the estimate
    /// shrank enough to leave the (static, non-bouncing) viewport resting past
    /// the new end, so it was snapped back to the new bottom edge instead of
    /// left stranded. Gated by the SAME `LESSSHEET_LOG_ESTIMATE` flag as
    /// `noteDecision` — both trace the estimate poll's effect on the live
    /// viewport.
    static func noteReanchor(fromY: CGFloat, toY: CGFloat, rows: Int, lastRows: Int) {
        guard logEnabled else { return }
        FileHandle.standardError.write(Data(String(
            format: "lesssheet.estimate.reanchor from_y=%.1f to_y=%.1f rows=%d last=%d at_ms=%d\n",
            fromY, toY, rows, lastRows, elapsedMs()
        ).utf8))
    }

    /// Called once the live grid is built (`NativeGridController.makeContainer`):
    /// forces + holds a simulated overscroll if armed, so the natural
    /// estimate-refinement reloads (driven by the REAL background indexer, not
    /// synthesized) can be observed colliding with it — or, once fixed,
    /// deferring around it. The FIRST force is delayed past `makeContainer`'s
    /// own post-open settling (the container's real size can still arrive a
    /// beat after `makeContainer` returns, and that resize's retile clamps an
    /// out-of-range clip origin straight back — a one-shot force set any
    /// earlier does not survive to the first poll-driven reload at all).
    static func armIfRequested(on controller: NativeGridController) {
        guard let edge = simulateEdge, !armed else { return }
        armed = true
        let holdMs = env["LESSSHEET_SIMULATE_OVERSCROLL_MS"].flatMap(Int.init) ?? 4000
        let clip = controller.scroll.contentView
        let restY = -(GridMetrics.titleBarInset + GridMetrics.rowHeight)   // the resting top inset
        let margin: CGFloat = 250
        let forced = edge == "left"
            ? NSPoint(x: -margin, y: restY)
            : NSPoint(x: 0, y: restY - margin)   // "top" (also the default for any other value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            log("lesssheet.estimate.overscroll_forced edge=\(edge) x=\(forced.x) y=\(forced.y) at_ms=\(elapsedMs())")
            let deadline = Date().addingTimeInterval(Double(holdMs) / 1000)
            hold(clip: clip, scroll: controller.scroll, at: forced, restY: restY, until: deadline)
        }
    }

    /// Re-asserts `point` every 250 ms until `deadline` — self-healing against
    /// anything that nudges the origin mid-hold, the same way a REAL held
    /// rubber-band is a continuous stream of bounds changes rather than one
    /// placement, without fighting AppKit hard enough to starve the run loop
    /// (a tighter, e.g. 20 ms, reassertion interval was observed to do exactly
    /// that: something battles each forced set closely enough that the
    /// resulting `clipBoundsChanged` churn crowds out the poll-driven
    /// `apply()` calls this probe exists to observe). Releases back to the
    /// resting top-left at the deadline, logs the release, and quits shortly
    /// after (self-contained — see the type doc).
    private static func hold(clip: NSClipView, scroll: NSScrollView, at point: NSPoint, restY: CGFloat, until deadline: Date) {
        clip.scroll(to: point)
        scroll.reflectScrolledClipView(clip)
        if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                hold(clip: clip, scroll: scroll, at: point, restY: restY, until: deadline)
            }
            return
        }
        clip.scroll(to: NSPoint(x: 0, y: restY))
        scroll.reflectScrolledClipView(clip)
        log("lesssheet.estimate.overscroll_released at_ms=\(elapsedMs())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

// Verification-only: headless proxy for "the user scrolled the live
// scrollbar to the current (possibly wildly over-estimated) end and let go"
// — the estimate-COLLAPSE repro (a huge head-extrapolated total, e.g. one
// final multi-GB row inflating a small-row-density extrapolation by orders
// of magnitude, that later collapses toward the true count as the background
// indexer reaches it). There is no scroll-to-position probe (no synthetic
// input event / TCC-prompting API is used anywhere in this app), so this
// parks the clip directly at the CURRENT estimate's bottom edge — the same
// one-time-force technique `EstimateReloadProbe` already uses for its
// overscroll-hold simulation — then lets the REAL background indexer run
// completely unmodified and watches whether the viewport re-anchors the
// instant the estimate collapses (`lesssheet.estimate.reanchor`, logged by
// `EstimateReloadProbe.noteReanchor` when LESSSHEET_LOG_ESTIMATE=1 is also
// set) instead of staying stranded past the new end. Self-terminates once the
// estimate goes exact or the timeout elapses — independent of
// LESSSHEET_DUMP_EXIT, since this is a one-shot diagnostic run, not a normal
// viewing session.
//
//   LESSSHEET_SIMULATE_ESTIMATE_COLLAPSE=1      Arm the probe.
//   LESSSHEET_SIMULATE_ESTIMATE_COLLAPSE_MS     Max wait for the estimate to
//     go exact before giving up and quitting (default 60000).
@MainActor
enum EstimateCollapseProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_SIMULATE_ESTIMATE_COLLAPSE"] != nil

    private static var armed = false
    private static var watchTask: Task<Void, Never>?
    private static let start = DispatchTime.now()

    private static func elapsedMs() -> Int {
        let t0 = start   // see EstimateReloadProbe.elapsedMs for the ordering note
        return Int((DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000)
    }

    /// Called once the live grid is built (mirrors `EstimateReloadProbe.
    /// armIfRequested`): park after the container's own post-open settling, so
    /// the one-shot force survives to the first poll-driven estimate tick.
    static func armIfRequested(on controller: NativeGridController) {
        guard active, !armed else { return }
        armed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { park(on: controller) }
    }

    /// Forces the clip to the bottom edge of the CURRENT estimate — exactly
    /// where a scrollbar drag to "the end" would leave it — using the same
    /// clamp math `NativeGridController.landOn` / `overscrollAxes` use.
    private static func park(on controller: NativeGridController) {
        let clip = controller.scroll.contentView
        let rows = controller.numberOfRows(in: controller.table)
        let maxY = maxYFor(rows: rows, controller: controller)
        clip.scroll(to: NSPoint(x: 0, y: maxY))
        controller.scroll.reflectScrolledClipView(clip)
        log("lesssheet.collapse.parked rows=\(rows) y=\(maxY)"
            + " known_total=\(controller.model.rowCountInfo.count) exact=\(controller.model.rowCountInfo.isExact)"
            + " at_ms=\(elapsedMs())")
        watch(controller: controller, parkedRows: rows)
    }

    private static func maxYFor(rows: Int, controller: NativeGridController) -> CGFloat {
        let clip = controller.scroll.contentView
        let contentHeight = CGFloat(rows) * GridMetrics.rowHeight
        let viewportHeight = max(clip.bounds.height, controller.scroll.bounds.height)
        let restTop = -(GridMetrics.titleBarInset + GridMetrics.rowHeight)
        return max(restTop, contentHeight - viewportHeight)
    }

    /// Polls the REAL (unmodified) indexer's progress: on every rows-count
    /// change, logs the clip origin against the freshly-recomputed valid
    /// range so "stranded" is a measured boolean, not an eyeball. Also drives
    /// `apply()` itself each tick — headless windows get no implicit
    /// `updateNSView` (see `HeaderToggleProbe`) — so the real fix path (and
    /// the colwidth probe it shares) actually runs on a schedule independent
    /// of whatever else happens to poke the view tree.
    private static func watch(controller: NativeGridController, parkedRows: Int) {
        let maxWaitMs = env["LESSSHEET_SIMULATE_ESTIMATE_COLLAPSE_MS"].flatMap(Int.init) ?? 60_000
        watchTask = Task { @MainActor in
            var lastLoggedRows = parkedRows
            while elapsedMs() < maxWaitMs {
                controller.apply()
                let rows = controller.numberOfRows(in: controller.table)
                if rows != lastLoggedRows {
                    lastLoggedRows = rows
                    let origin = controller.scroll.contentView.bounds.origin
                    let maxY = maxYFor(rows: rows, controller: controller)
                    let stranded = origin.y > maxY + 0.5
                    log("lesssheet.collapse.tick rows=\(rows) origin_y=\(origin.y) max_y=\(maxY)"
                        + " stranded=\(stranded) at_ms=\(elapsedMs())")
                }
                if controller.model.rowCountInfo.isExact {
                    log("lesssheet.collapse.exact rows=\(rows) at_ms=\(elapsedMs())")
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            log("lesssheet.collapse.done at_ms=\(elapsedMs())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
