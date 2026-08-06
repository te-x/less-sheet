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
    func applied(from current: UInt64?, seed: UInt64, lastRow: UInt64) -> String {
        let bound = max(1, lastRow)                     // every document has a row 1
        let from = min(max(current ?? seed, 1), bound)
        switch self {
        case .towardStart: return String(from == 1 ? bound : from - 1)
        case .towardEnd: return String(from == bound ? 1 : from + 1)
        }
    }
}

extension DocumentModel {
    /// Step the OPEN jump field's row number one row (↑/↓ while the popup is up).
    /// Edits `jumpFieldText` and NOTHING else: no `beginJump`, no core call, no
    /// `pendingScrollRow` — the user still presses Enter to travel, exactly as
    /// before. Inert while the field is closed, so the grid keeps its own arrow
    /// navigation (`KeyboardNavigator`) to itself.
    func stepJumpField(_ direction: JumpFieldStep) {
        guard jumpFieldActive else { return }
        // Read the current text through the FROZEN parser the submit path uses
        // (`parseTarget` is 0-based; the field is 1-based), so "what counts as a
        // row number" can never disagree between stepping and submitting.
        let current = jumpControl.parseTarget(jumpFieldText).map { $0 &+ 1 }
        jumpFieldText = direction.applied(from: current, seed: jumpFieldSeedRow,
                                          lastRow: jumpRowCountInfo.count)
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
