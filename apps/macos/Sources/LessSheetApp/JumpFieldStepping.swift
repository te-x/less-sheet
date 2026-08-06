import Contracts
import Foundation

// Arrow-key stepping of the OPEN jump field's row number (⌘J, then ↑/↓). The
// field's TEXT is the only thing that changes: no jump begins, no scan runs and
// the viewport never moves until Enter — so stepping costs exactly the same on a
// 40-byte file as on a 40 GB one, and the < 500 ms cold start is untouched
// (nothing here runs at launch).

/// Which way an arrow key walks the jump field's 1-based row number.
///
/// DELIBERATELY INVERTED relative to a numeric stepper (the author, 2026-08): ↑
/// steps toward the START of the document (a SMALLER row number), ↓ toward the
/// END (a LARGER one). Rows travel UP the screen while you scroll DOWN, so
/// "down" reads as "further down the document" — the direction the row number
/// grows. The physical-key → case mapping lives in exactly ONE place
/// (`JumpControlView`'s `onKeyPress`), so the inversion is stated once and
/// cannot drift.
enum JumpFieldStep {
    /// ↑ — one row toward row 1, wrapping from row 1 round to the LAST row.
    case towardStart
    /// ↓ — one row toward the last row, wrapping from the last row round to 1.
    case towardEnd

    /// The field's next text. `current` is the 1-based row the field holds now,
    /// or nil when it is empty (or holds something the jump submit would reject
    /// anyway) — that steps from `seed`, the top visible row, instead.
    ///
    /// `lastRow` is the 1-based last row the document is known — or merely
    /// ESTIMATED — to have: both the wrap boundary and the clamp, so an arrow
    /// never leaves a number outside 1…lastRow. Under an estimate the boundary
    /// IS the estimate (the author: "wraps up to the end, estimate if needed"); it
    /// sharpens by itself as the background index converges and no scan is ever
    /// forced to sharpen it here.
    ///
    /// `magnitude` is the held-arrow step size (`JumpFieldRamp`). A step larger
    /// than 1 SNAPS to the next multiple of itself in the direction of travel, so
    /// a held ↓ reads 20, 30, 40 … rather than 22, 32, 42 (the author's ramp) — and
    /// snapping to the next multiple is always forward, never a step back. A step
    /// that would leave the document LANDS ON the end it was heading for (the last
    /// row, or row 1) instead of jumping over it; only a press made while already
    /// standing on that end wraps round. So no step size can ever overshoot the
    /// wrap, and with `magnitude == 1` this is exactly the original ±1 rule.
    func applied(from current: UInt64?, seed: UInt64, lastRow: UInt64, magnitude: UInt64) -> String {
        let bound = max(1, lastRow)                     // every document has a row 1
        let step = max(1, magnitude)
        let from = min(max(current ?? seed, 1), bound)
        // Both directions work in DISTANCES to the neighbouring multiple (1…step)
        // rather than absolute multiples, so nothing can overflow near UInt64.max.
        switch self {
        case .towardStart:
            let remainder = from % step
            let retreat = remainder == 0 ? step : remainder
            if retreat >= from { return String(from == 1 ? bound : 1) }
            return String(from - retreat)
        case .towardEnd:
            let advance = step - from % step
            if advance > bound - from { return String(from == bound ? 1 : bound) }
            return String(from + advance)
        }
    }
}

/// Hold-to-accelerate for the arrow keys: the step size grows the LONGER the key
/// is held, so a hold is useful past a nudge (the author's ramp, 2026-08).
///
///     hold ↓ from row 1
///       0.0s   1  2  3  4 …        step 1
///       1.0s   20  30  40 …        step 10
///       2.0s   200  300  400 …     step 100
///       3.0s   2000  3000 …        step 1000
///     release → back to step 1
///
/// Keyed off ELAPSED HOLD TIME, never off a repeat COUNT: the OS auto-repeat rate
/// differs per platform and per user (~11/s on this Mac, ~12.5/s on GTK, both
/// configurable), so a count-based ramp would accelerate at different rows on each
/// — while the two frontends must behave identically.
struct JumpFieldRamp {
    /// How long the key must have been held before each step size takes over, and
    /// the gap that ends a hold — the ONE place the ramp is tuned.
    static let tensAfter: Duration = .seconds(1)
    static let hundredsAfter: Duration = .seconds(2)
    static let thousandsAfter: Duration = .seconds(3)
    /// A gap longer than this ends the hold BY ITSELF, with no key-up needed.
    /// Comfortably above one auto-repeat interval (~90 ms here) so a real hold is
    /// never cut short, and short enough that the ramp cannot survive to the next
    /// deliberate tap. This is the belt to the key-up's braces: a key-up that is
    /// swallowed (focus change, popup close, dropped event) must NEVER leave the
    /// ramp hot, because the next single tap would then move 1000 rows.
    static let holdLapse: Duration = .milliseconds(300)

    private var startedAt: ContinuousClock.Instant?
    private var steppedAt: ContinuousClock.Instant?
    /// Which arrow the open hold belongs to. A press in the OTHER direction is a
    /// new intent, never a continuation — the third defence, after the key-up and
    /// the lapse. Without it, a swallowed key-up followed within 300 ms by the
    /// opposite arrow would step 1000 in the new direction. Added to match the GTK
    /// implementation, which had this guard while this side did not.
    private var direction: JumpFieldStep?

    /// The step size for a press at `now`, opening a FRESH hold (step 1) whenever
    /// this press is not a continuation of the current one.
    mutating func magnitude(pressedAt now: ContinuousClock.Instant,
                            going way: JumpFieldStep) -> UInt64 {
        if !continues(at: now, going: way) { startedAt = now }
        steppedAt = now
        direction = way
        return Self.magnitude(held: now - (startedAt ?? now))
    }

    /// The key came up: the hold is over, so the next press steps by 1 again.
    mutating func release() {
        startedAt = nil
        steppedAt = nil
        direction = nil
    }

    /// A press continues the current hold only if one is open AND it follows the
    /// previous step closely enough to belong to the same auto-repeat stream.
    private func continues(at now: ContinuousClock.Instant, going way: JumpFieldStep) -> Bool {
        guard startedAt != nil, let steppedAt, direction == way else { return false }
        return now - steppedAt <= Self.holdLapse
    }

    /// The step size for a hold of `held`.
    static func magnitude(held: Duration) -> UInt64 {
        if held < tensAfter { return 1 }
        if held < hundredsAfter { return 10 }
        if held < thousandsAfter { return 100 }
        return 1000
    }
}

extension DocumentModel {
    /// Step the OPEN jump field's row number one row (↑/↓ while the popup is up).
    /// Edits `jumpFieldText` and NOTHING else: no `beginJump`, no core call, no
    /// `pendingScrollRow` — the user still presses Enter to travel, exactly as
    /// before. Inert while the field is closed, so the grid keeps its own arrow
    /// navigation (`KeyboardNavigator`) to itself.
    /// Held arrows accelerate through `jumpFieldRamp` (step 1 → 10 → 100 → 1000 by
    /// elapsed hold time); a closed field returns BEFORE the ramp is touched, so a
    /// keypress the grid owns can never arm it.
    func stepJumpField(_ direction: JumpFieldStep) {
        guard jumpFieldActive else { return }
        let magnitude = jumpFieldRamp.magnitude(pressedAt: progressClock.now, going: direction)
        // Read the current text through the FROZEN parser the submit path uses
        // (`parseTarget` is 0-based; the field is 1-based), so "what counts as a
        // row number" can never disagree between stepping and submitting.
        let current = jumpControl.parseTarget(jumpFieldText).map { $0 &+ 1 }
        jumpFieldText = direction.applied(from: current, seed: jumpFieldSeedRow,
                                          lastRow: jumpRowCountInfo.count, magnitude: magnitude)
    }

    /// The arrow key came UP: end the hold so the very next press steps by 1.
    /// Paired with `JumpFieldRamp.holdLapse`, which ends a hold on its own if this
    /// never arrives — a missed key-up must not leave the ramp accelerated.
    func endJumpFieldHold() {
        jumpFieldRamp.release()
    }

    /// The 1-based row an empty field steps from: the row the gutter shows for
    /// the TOP VISIBLE row.
    ///
    /// "Top visible row" is the grid's `currentTopDataRow()` — the row at the top
    /// of the UNOBSCURED data area — the same definition the grid's own arrow
    /// navigation seeds from (`NativeGridController.navigate`), NOT the paging
    /// `firstVisibleRow`, which counts the rows scrolled under the glass band and
    /// so sits a row or two above what the user sees. One definition of "the top
    /// row" for both keyboard features; `firstVisibleRow` is only the fallback
    /// for a model with no live grid (headless dumps). `gutterRow` then maps it
    /// exactly as the gutter does, which is already the ORIGINAL row number under
    /// a filter — the domain the jump field takes (ARCH criterion 12/17) — so the
    /// seed needs no filtered/identity branch of its own. Row 1 when that row is
    /// not currently servable.
    var jumpFieldSeedRow: UInt64 {
        let top = NativeGridController.live?.currentTopDataRow() ?? firstVisibleRow
        return (gutterRow(forRow: top) ?? 0) &+ 1
    }
}
