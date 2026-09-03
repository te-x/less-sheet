import Contracts
import Foundation

// Arrow-key stepping of the OPEN jump field's row number. The field's TEXT is
// the only thing that changes: no jump begins, no scan runs and the viewport
// never moves until Enter, so stepping costs the same on a 40-byte file as on a
// 40 GB one.

/// Which way an arrow key walks the jump field's 1-based row number.
///
/// DELIBERATELY INVERTED relative to a numeric stepper: ↑ steps toward the START
/// of the document, ↓ toward the END. Rows travel up the screen while you scroll
/// down, so "down" reads as "further down the document" — the direction the row
/// number grows. The physical-key mapping lives in exactly one place, so the
/// inversion is stated once and cannot drift.
enum JumpFieldStep {
    /// ↑ — one row toward row 1, wrapping from row 1 round to the LAST row.
    case towardStart
    /// ↓ — one row toward the last row, wrapping from the last row round to 1.
    case towardEnd

    /// The field's next text. `current` is the 1-based row the field holds now,
    /// or nil when it is empty (or holds something the jump submit would reject
    /// anyway) — that steps from `seed`, the top visible row, instead.
    ///
    /// `lastRow` is both the wrap boundary and the clamp, so an arrow never
    /// leaves a number outside 1…lastRow. Under an estimate the boundary IS the
    /// estimate, sharpening by itself as the index converges; no scan is ever
    /// forced here.
    ///
    /// `magnitude` is the held-arrow step size. A step larger than 1 SNAPS to the
    /// next multiple of itself in the direction of travel, so a held ↓ reads 20,
    /// 30, 40 rather than 22, 32, 42 — and snapping is always forward, never a
    /// step back. A step that would leave the document LANDS ON the end it was
    /// heading for; only a press made while already standing there wraps. So no
    /// step size can overshoot the wrap, and a magnitude of 1 is exactly ±1.
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

/// Hold-to-accelerate: the step size grows the longer the key is held, so a hold
/// is useful past a nudge.
///
///     hold ↓ from row 1
///       0.0s   1  2  3  4 …        step 1
///       1.0s   20  30  40 …        step 10
///       2.0s   200  300  400 …     step 100
///       3.0s   2000  3000 …        step 1000
///     release → back to step 1
///
/// Keyed off ELAPSED HOLD TIME, never a repeat COUNT: the auto-repeat rate
/// differs per platform and per user, so a count-based ramp would accelerate at
/// different rows on each, and the two frontends must behave identically.
struct JumpFieldRamp {
    /// How long the key must have been held before each step size takes over, and
    /// the gap that ends a hold — the ONE place the ramp is tuned.
    static let tensAfter: Duration = .seconds(1)
    static let hundredsAfter: Duration = .seconds(2)
    static let thousandsAfter: Duration = .seconds(3)
    /// A gap longer than this ends the hold BY ITSELF, with no key-up needed:
    /// comfortably above one auto-repeat interval, so a real hold is never cut
    /// short, and short enough that the ramp cannot survive to the next tap. It is
    /// the belt to the key-up's braces — a swallowed key-up must never leave the
    /// ramp hot, or the next single tap would move a thousand rows.
    static let holdLapse: Duration = .milliseconds(300)

    private var startedAt: ContinuousClock.Instant?
    private var steppedAt: ContinuousClock.Instant?
    /// Which arrow the open hold belongs to. A press in the OTHER direction is a
    /// new intent, never a continuation — the third defence, after the key-up and
    /// the lapse: a swallowed key-up followed quickly by the opposite arrow would
    /// otherwise step a thousand rows the other way.
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
    /// Steps the OPEN jump field's row number. Edits the text and NOTHING else —
    /// no jump, no core call — so the user still presses Enter to travel. Inert
    /// while the field is closed, and it returns BEFORE the ramp is touched, so a
    /// keypress the grid owns can never arm it.
    func stepJumpField(_ direction: JumpFieldStep) {
        guard jumpFieldActive else { return }
        let magnitude = jumpFieldRamp.magnitude(pressedAt: progressClock.now, going: direction)
        // Read the text through the SAME parser the submit path uses, so "what
        // counts as a row number" cannot disagree between stepping and submitting.
        let current = jumpControl.parseTarget(jumpFieldText).map { $0 &+ 1 }
        jumpFieldText = direction.applied(from: current, seed: jumpFieldSeedRow,
                                          lastRow: jumpRowCountInfo.count, magnitude: magnitude)
    }

    /// Ends the hold, so the next press steps by 1. Paired with the hold lapse,
    /// which ends one on its own if this never arrives.
    func endJumpFieldHold() {
        jumpFieldRamp.release()
    }

    /// The 1-based row an empty field steps from: the row the gutter shows for
    /// the TOP VISIBLE row.
    ///
    /// "Top visible" is the row at the top of the UNOBSCURED data area — the same
    /// definition the grid's own arrow navigation seeds from — not the paging
    /// `firstVisibleRow`, which counts rows scrolled under the band and so sits a
    /// row or two above what the user sees. That one is only the fallback for a
    /// model with no live grid. The gutter's mapping is already the ORIGINAL row
    /// number under a filter, which is the domain the jump field takes, so the
    /// seed needs no filtered branch of its own.
    var jumpFieldSeedRow: UInt64 {
        let top = NativeGridController.live?.currentTopDataRow() ?? firstVisibleRow
        return (gutterRow(forRow: top) ?? 0) &+ 1
    }
}
