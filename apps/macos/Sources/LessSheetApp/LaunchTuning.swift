import Foundation

/// THE switch for the launch-time tuning that changes observable ORDERING —
/// one named constant, one resolver, read once at process start.
///
/// Two launch optimizations move work relative to AppKit/SwiftUI bring-up:
/// `LaunchOpenPrewarm` (the launch document's core open, started at process
/// entry, which can hand the document to SwiftUI before the window's content
/// view is even built) and `DeferredOverlay` (the glass control row, one
/// main-queue turn late). Both are invisible to a user — the rows are the same
/// rows, and the chrome is always visible — but both are visible to the
/// verification hooks, which drive the LIVE grid and the LIVE overlay from
/// `documentContent`'s `.task(id:)` and reasonably assume today's ordering.
///
/// This is not hypothetical: `FrameDump.dumpArrival` waits for
/// `NativeGridController.live` to have a laid-out container and silently falls
/// back to a SwiftUI mirror if it does not. Landing the document earlier made
/// that fall back on ~30% of jump-probe runs (0% before) — a different image,
/// no failure. A probe must not have to race for its subject.
///
/// So a verification run keeps EXACTLY today's launch: no prewarm (the launch
/// route falls through to `DocumentModel.open`'s async funnel, byte for byte
/// what it always did) and the overlay in the hierarchy from the first pass.
///
/// What this gate would COST if the list below were drawn too wide, and why the
/// plain frame dump is nevertheless on it: a gate that switches off every
/// pixel-comparing tool leaves the shipped ordering image-verified by nothing,
/// so the sweeps "proving" a launch change is safe would all execute the OTHER
/// path. That is exactly what happened when this landed (2026-08-07 review):
/// every scenario of the 28-shot sweep set `LESSSHEET_DUMP_FRAME`, so both arms
/// ran the baseline ordering and the sweep could not see the change at all.
///
/// Do NOT lean on the frozen corpus cold-open tests to fill that hole. They
/// assert that a `first_rows_visible_ms` line appeared and was under 500 ms —
/// no image, no content, no exit code — and they RETRY up to three launches. A
/// regression that painted a blank grid while still scheduling
/// `documentContent`'s `.task` would pass them.
///
/// So the three plain-dump variables are benign, which makes the shipping
/// ordering image-verifiable. That is safe BY CONSTRUCTION, not by luck: the
/// plain grid dump is fired from inside `GridView.makeNSView`
/// (`NativeGrid+Build.swift`), where the grid provably exists, while the racing
/// path above (`dumpArrival` → `captureLiveGrid`) is reachable only from
/// `JumpProbe` / `FindProbe` / `LandingStallProbe`, whose own `LESSSHEET_JUMP` /
/// `_FIND` / `_LANDING_STALL` variables are NOT benign and so keep forcing the
/// baseline ordering. Verified: 21 scenarios — the corpus, the 50 MB document,
/// empty, three malformed fixtures, nonexistent, directory-as-path, forced
/// dialect, hidden columns, dark appearance — byte-identical PNGs against the
/// pre-change binary with both optimizations ON.
///
/// Deciding this from the ENVIRONMENT rather than from a list of probe flags
/// keeps it exhaustive by construction: a hook added later is covered
/// automatically, and the failure direction is safe — an unrecognised variable
/// can only cost the launch optimization, it can never break a probe.
enum LaunchTuning {
    /// Variables that do NOT mean "verification run": the launch phase stamps,
    /// the bare dump-exit used to time them, the forced initial dialect, the
    /// pre-hidden columns, and the plain frame dump (see above — its capture is
    /// fired from `makeNSView`, not from the racing `.task`). Anything ELSE
    /// prefixed `LESSSHEET_` is a hook.
    private static let benignVariables: Set<String> = [
        "LESSSHEET_LAUNCH_PHASES", "LESSSHEET_DUMP_EXIT", "LESSSHEET_HIDE_COLS",
        "LESSSHEET_FORCE_SEP", "LESSSHEET_FORCE_QUOTE", "LESSSHEET_FORCE_HEADER",
        "LESSSHEET_DUMP_FRAME", "LESSSHEET_DUMP_SCENE", "LESSSHEET_DUMP_APPEARANCE"
    ]

    static let applies: Bool = !ProcessInfo.processInfo.environment.keys.contains {
        $0.hasPrefix("LESSSHEET_") && !benignVariables.contains($0)
    }
}
