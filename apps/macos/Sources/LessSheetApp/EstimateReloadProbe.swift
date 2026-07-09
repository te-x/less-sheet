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
