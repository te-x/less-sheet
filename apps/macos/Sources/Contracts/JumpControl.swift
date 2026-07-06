/// Jump-to-row view-model contract (ARCH-viewer-ui req. 7, criterion 12):
/// pure input parsing and the pure state machine driving the jump control —
/// including the pinned "cancel returns the viewport to the pre-jump
/// position" semantic. The core interaction (start/cancel/poll) happens
/// through `DocumentSession`; this logic decides what the UI does with it.

/// The jump control's state.
public enum JumpFlow: Equatable, Sendable {
    /// No jump in flight.
    case idle
    /// Scanning toward `target`; `preJumpFirstRow` is the viewport's first
    /// visible row captured when the jump began (the cancel restore point);
    /// `progress` in [0, 1] is what the control displays.
    case scanning(target: UInt64, preJumpFirstRow: UInt64, progress: Double)
    /// The jump finished: scroll so `row` is visible (row anchoring within
    /// the viewport is presentation state).
    case landed(row: UInt64)
    /// The jump was cancelled: restore the viewport to `restoreToFirstRow`
    /// (the captured pre-jump position). Frontier gains stay in the core.
    case cancelled(restoreToFirstRow: UInt64)
}

/// Pure jump logic. Pinned semantics:
/// - `parseTarget(_:)` — the jump field accepts 1-BASED row numbers (UI
///   copy counts rows from 1), digits only, 64-bit: the input must be
///   non-empty, all ASCII digits, with a value v in 1...UInt64.max; the
///   result is the 0-based data row v − 1. Anything else (empty, non-digit,
///   zero, overflow) returns nil and the UI rejects the submit.
/// - `begin(target:preJumpFirstRow:)` — `.scanning(target, preJumpFirstRow,
///   progress: 0)`.
/// - `resolve(_:with:)` — folds a `DocumentSession.jumpStatus()` poll into
///   the flow:
///     .scanning + .scanning(p) -> .scanning with progress max(old, p)
///       (display progress never regresses);
///     .scanning + .done(row)   -> .landed(row);
///     anything else            -> unchanged (an .idle poll never resets a
///       flow by itself; cancellation goes through `cancelled`).
/// - `cancelled(_:)` — user cancel (Esc): .scanning(_, pre, _) ->
///   .cancelled(restoreToFirstRow: pre); any other flow unchanged.
public protocol JumpControlling: Sendable {
    func parseTarget(_ input: String) -> UInt64?
    func begin(target: UInt64, preJumpFirstRow: UInt64) -> JumpFlow
    func resolve(_ flow: JumpFlow, with status: JumpStatus) -> JumpFlow
    func cancelled(_ flow: JumpFlow) -> JumpFlow
}
