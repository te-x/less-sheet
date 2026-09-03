import Foundation

/// The one switch for the two launch optimizations that change observable
/// ORDERING: the prewarmed launch open, which can hand the document to SwiftUI
/// before the window's content view exists, and the deferred overlay, one
/// main-queue turn late. Neither is visible to a user — same rows, same
/// always-on chrome — but both are visible to the verification hooks, which
/// drive the live grid and overlay from the document view's `.task` and
/// reasonably assume the unoptimized ordering. A probe must not have to race for
/// its subject: the live-grid capture silently falls back to a SwiftUI mirror
/// when the grid is not laid out yet, which is a different image and no failure
/// at all.
///
/// So a verification run keeps exactly the unoptimized launch — and the plain
/// frame-dump variables are deliberately NOT counted as one, or every
/// pixel-comparing sweep would execute the other path and the shipping ordering
/// would be image-verified by nothing. That exception is safe by construction:
/// the plain grid dump fires from inside `makeNSView`, where the grid provably
/// exists, while the racing capture is reachable only from probes whose own
/// variables are not benign.
///
/// Do not lean on the frozen cold-open tests to cover that gap: they assert only
/// that a marker line appeared under budget, with retries, so a regression that
/// painted a blank grid would still pass them.
///
/// Deciding this from the ENVIRONMENT rather than a list of probe flags keeps it
/// exhaustive: a hook added later is covered automatically, and the failure
/// direction is safe — an unrecognised variable can only cost the optimization,
/// never break a probe.
enum LaunchTuning {
    /// Variables that do NOT mean "verification run". `LESSSHEET_OPEN_URL` is
    /// benign for a structural reason: it names the launch DOCUMENT, exactly as a
    /// path in argv does, drives no probe, and cannot interact with the prewarm,
    /// which never engages for a network open.
    private static let benignVariables: Set<String> = [
        "LESSSHEET_LAUNCH_PHASES", "LESSSHEET_DUMP_EXIT", "LESSSHEET_HIDE_COLS",
        "LESSSHEET_FORCE_SEP", "LESSSHEET_FORCE_QUOTE", "LESSSHEET_FORCE_HEADER",
        "LESSSHEET_DUMP_FRAME", "LESSSHEET_DUMP_SCENE", "LESSSHEET_DUMP_APPEARANCE",
        "LESSSHEET_OPEN_URL"
    ]

    static let applies: Bool = !ProcessInfo.processInfo.environment.keys.contains {
        $0.hasPrefix("LESSSHEET_") && !benignVariables.contains($0)
    }
}
