import Contracts
import SwiftUI

/// The reusable "subtle progress after a while" indicator, driven by the shared
/// gate's coarse verdict — visible plus optional cancel, never a fraction. Copy
/// embeds this directly; jump and filter gate their own richer progress bars on
/// the same verdict.
///
/// Under Reduce Motion it swaps to a static glyph, because an indeterminate
/// `ProgressView` never stops its own sweep. Renders nothing while hidden, so a
/// sub-threshold operation never flickers chrome.
struct DelayedProgressSpinner: View {
    let indication: ProgressIndication
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if indication.isVisible {
            if reduceMotion {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)   // the surrounding label speaks for it
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        }
    }
}
