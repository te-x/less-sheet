import Contracts
import SwiftUI

// The ONE reusable "subtle progress after ~500 ms" affordance (ARCH-stream-
// copy AC8/AC9): a small, non-blocking indicator gated by a `ProgressIndication`
// — the frozen `Contracts.DelayedProgressGating` protocol's coarse output
// (visible + optional cancel, NEVER a fraction; accuracy is a non-goal). Every
// long op `DocumentModel` drives through its shared `DelayedProgressGate`
// (copy embeds this view directly; jump/filter reuse their own richer
// progress-bar/% surfaces, gated by the SAME indication — see
// `docs/architecture/ARCH-stream-copy-audit.md` for the full rundown) can
// embed this. Renders nothing (zero layout cost) while hidden, so a
// sub-threshold operation never flickers chrome.

/// A subtle spinner — or, under Reduce Motion, a static glyph — shown only
/// while `indication.isVisible`. An indeterminate `ProgressView` never stops
/// its own sweep for Reduce Motion, so this swaps to a static glyph instead
/// of animating (the same treatment `JumpControlView`'s reject-shake already
/// gives Reduce Motion elsewhere in this app — see OverlayView.swift).
/// Negligible overhead: an `EmptyView` (no timer, no drawing) whenever hidden.
struct DelayedProgressSpinner: View {
    let indication: ProgressIndication
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if indication.isVisible {
            if reduceMotion {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)   // the surrounding label already speaks for it
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
    }
}
