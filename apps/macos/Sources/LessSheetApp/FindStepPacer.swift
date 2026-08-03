import AppKit
import Foundation

// Pacing for the headless find step-sequence probe, split out of FindProbe.swift
// to keep that file within the length budget. Pure code motion plus the state it
// owns — no behavior of its own beyond the ordering it enforces.

/// Holds a probe's next ⌘G until the CURRENT match is PHYSICALLY on screen.
///
/// `NativeGrid.applyPendingLanding` reads a single `model.pendingScrollRow` slot
/// and `scheduleLandingApply` coalesces to one apply per run-loop turn. A driver
/// that steps straight out of the model's fold handler therefore overwrites that
/// slot, and only the LAST match ever scrolls — right for the product (you want
/// the final target on screen, not three intermediate scrolls) and wrong for a
/// driver whose whole job is to exercise EACH landing.
///
/// That also made the sequence implicitly timing-dependent: it passed only while
/// the core was slow enough for the view to settle between matches, and core
/// speedups broke it — landings arrived ~4 ms apart, so a single
/// `viewport.landed` covered three of them and the intermediate ones looked as
/// though they had never scrolled.
///
/// A real ⌘G always arrives on a later run-loop turn with the previous match
/// already visible, so pacing on the OBSERVED scroll is both more faithful to the
/// interaction and deterministic — it cannot regress again when the core gets
/// faster.
@MainActor
enum FindStepPacer {
    /// The row whose landing is being waited on, the step held until then, and the
    /// last row the viewport probe actually reported.
    private static var awaitingRow: Int?
    private static var queued: (() -> Void)?
    private static var lastNotedRow: Int?

    /// Run `step` once the viewport has been observed to land on `afterRow`. If
    /// that landing was ALREADY reported (the note can precede the queue), runs it
    /// immediately, so a sequence can never stall waiting for a past event.
    static func queue(afterRow: Int?, step: @escaping () -> Void) {
        guard let afterRow else {
            step()
            return
        }
        if afterRow == lastNotedRow {
            step()
            return
        }
        awaitingRow = afterRow
        queued = step
    }

    /// The shipping NSClipView finished scrolling to `row` (from
    /// `ViewportLandingProbe`). Releases a step held for exactly that row.
    static func noteLanded(_ row: Int) {
        lastNotedRow = row
        guard awaitingRow == row, let step = queued else { return }
        awaitingRow = nil
        queued = nil
        step()
    }
}
