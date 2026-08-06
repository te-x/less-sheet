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
/// The shipping configuration is NOT left untested by this: the frozen corpus
/// cold-open tests strip every `LESSSHEET_*` variable except `LESSSHEET_DUMP_EXIT`
/// (benign, below), so they launch the real binary over five corpus documents
/// with both optimizations ON.
///
/// Deciding this from the ENVIRONMENT rather than from a list of probe flags
/// keeps it exhaustive by construction: a hook added later is covered
/// automatically, and the failure direction is safe — an unrecognised variable
/// can only cost the launch optimization, it can never break a probe.
enum LaunchTuning {
    /// Variables that do NOT mean "verification run": the launch phase stamps,
    /// the bare dump-exit used to time them, the forced initial dialect, and the
    /// pre-hidden columns. Anything ELSE prefixed `LESSSHEET_` is a hook.
    private static let benignVariables: Set<String> = [
        "LESSSHEET_LAUNCH_PHASES", "LESSSHEET_DUMP_EXIT", "LESSSHEET_HIDE_COLS",
        "LESSSHEET_FORCE_SEP", "LESSSHEET_FORCE_QUOTE", "LESSSHEET_FORCE_HEADER"
    ]

    static let applies: Bool = !ProcessInfo.processInfo.environment.keys.contains {
        $0.hasPrefix("LESSSHEET_") && !benignVariables.contains($0)
    }
}
