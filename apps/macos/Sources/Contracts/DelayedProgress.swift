/// The reusable "subtle progress after a delay" GATE (ARCH-stream-copy AC8/AC9)
/// — the ONE component every long-running operation (COPY, background index,
/// jump-scan, filter-scan) drives so the app reveals a subtle, non-blocking
/// progress indicator once an operation has been running longer than `threshold`
/// (~500 ms). A fast operation shows NOTHING (no flicker); a slow one signals
/// "working through a lot of data — not frozen." This is the never-look-frozen
/// half of the feature (win #2), delivered as one affordance and consumed by
/// copy here + the existing long ops where that is only wiring.
///
/// PURE + HERMETIC: the decision reads NO real wall-clock. The DRIVER (in the
/// App / LessSheetKit) owns the clock — the real `ContinuousClock` in the app, a
/// controlled one in tests — measures how long the operation has run, and passes
/// that `elapsed` in. So the threshold + show/hide logic is deterministic and
/// unit-testable without timing flakiness (ARCH AC8: "the threshold + show/hide
/// logic is unit-tested hermetically … no real wall-clock in the logic test").
///
/// ACCURACY IS A NON-GOAL (ARCH scope + AC8). The indication is COARSE /
/// indeterminate: it carries only WHETHER to show the indicator and whether a
/// Cancel affordance is offered — NEVER a fraction. There is deliberately no
/// percentage field, and the frozen tests deliberately pin none: the indicator's
/// whole job is "ongoing work on a large dataset," not a precise measure.

/// A long-running operation's live state, as its DRIVER observes it. `elapsed`
/// is how long the operation has been running — the driver computes it from the
/// clock it was handed (real in the app; injected/controlled in tests), so the
/// gate itself never reads a clock.
public enum OperationState: Sendable, Equatable {
    /// The operation is still running: it has been for `elapsed`, and may or may
    /// not be `cancellable` (copy carries the Task/Esc/Cancel; a poll-driven scan
    /// may not offer an explicit cancel).
    case running(elapsed: Duration, cancellable: Bool)
    /// The operation has SETTLED — completed OR cancelled. Both hide the
    /// indicator (gone on completion or cancel); the gate does not distinguish
    /// them (there is no chrome to keep once work stops).
    case settled
}

/// What the UI should present for a long operation right now. COARSE by design —
/// visibility + an optional Cancel affordance, and NOTHING about progress amount
/// (accuracy is a non-goal; there is no fraction here on purpose).
public struct ProgressIndication: Sendable, Equatable {
    /// Whether the subtle progress indicator is shown at all.
    public let isVisible: Bool
    /// Whether a Cancel affordance accompanies the indicator. Only meaningful
    /// when `isVisible`; always false when hidden.
    public let offersCancel: Bool

    public init(isVisible: Bool, offersCancel: Bool) {
        self.isVisible = isVisible
        self.offersCancel = offersCancel
    }

    /// Show nothing — no chrome, no flicker. The result for a sub-threshold or a
    /// settled operation.
    public static let hidden = ProgressIndication(isVisible: false, offersCancel: false)
}

/// The reusable delayed-progress gate. Implemented in `LessSheetKit` as
/// `DelayedProgressGate`, pinned by a frozen conformance test
/// (`let _: any DelayedProgressGating = DelayedProgressGate()`).
///
/// PINNED rules (this doc-comment is the spec the seed does NOT yet satisfy):
///
/// 1. THRESHOLD. `threshold` is the single delay a running operation must exceed
///    before its indicator appears — subtle-after-~500 ms — SHARED by every long
///    operation (copy / index / jump / filter) so the whole app reveals progress
///    consistently. It is a tunable ~500 ms; the frozen tests pin its BEHAVIOR
///    (and that it is a sane ~500 ms), never a magic exact value.
///
/// 2. APPEARS ONLY PAST THRESHOLD. For `.running(elapsed, _)`, the indicator is
///    VISIBLE iff `elapsed >= threshold`. A sub-threshold operation shows NOTHING
///    (`.hidden`) — a copy/jump/filter that finishes fast never flickers chrome.
///
/// 3. GONE ON COMPLETION OR CANCEL. For `.settled` the indication is `.hidden`,
///    regardless of how long the operation ran.
///
/// 4. CANCEL AFFORDANCE. `offersCancel` is true IFF the indicator is visible AND
///    the running operation is `cancellable` (so copy's indicator carries its
///    cancel; a non-cancellable op's does not). Never true when hidden.
///
/// 5. COARSE. The indication carries no fraction — accuracy is explicitly not
///    part of this contract.
public protocol DelayedProgressGating: Sendable {
    /// The delay a running operation must exceed before its subtle indicator
    /// appears (~500 ms). One value shared by every long operation.
    var threshold: Duration { get }

    /// PURE, hermetic decision (reads no clock — see rules 2–5 above).
    func indication(for state: OperationState) -> ProgressIndication
}
