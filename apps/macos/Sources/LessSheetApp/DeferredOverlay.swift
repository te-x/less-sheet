import Foundation
import Observation
import SwiftUI

/// Whether the glass control row is in the view hierarchy yet.
///
/// Process-global on purpose: once revealed it STAYS revealed, so a re-open can
/// never re-defer it. A per-view `@State` would reset with the view's identity
/// and make the chrome blink.
@MainActor
@Observable
final class OverlayRevealGate {
    static let shared = OverlayRevealGate()

    private(set) var isRevealed: Bool
    private var scheduled = false

    /// Every probe that drives or photographs the live overlay runs from the
    /// document view's `.task`, whose ordering against a deferred reveal is not
    /// guaranteed — so on a verification run the deferral is off and the overlay
    /// is in the hierarchy from the first pass.
    private init() { isRevealed = !LaunchTuning.applies }

    /// Reveals the overlay one main-queue turn from now, after the turn that laid
    /// out and drew the grid rows.
    func revealAfterFirstPaint() {
        guard !isRevealed, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { self.revealNow() }
    }

    /// The explicit "now, not next turn" entry.
    func revealNow() { isRevealed = true }
}

/// The glass control row, inserted one main-queue turn after the grid's first
/// paint.
///
/// The six glass controls cost about 13 ms of the FIRST paint (measured by
/// ablating them: 172.0 -> 158.7 ms to first row pixels on a 50 MB file). The
/// rows are the data; the controls are chrome the user cannot act on in the
/// first frame anyway. This is a deferral, never a removal — no transition, no
/// animation — so it reads as "always been there" rather than as a pop-in.
///
/// Deliberately its own view, so flipping the gate re-evaluates only this
/// wrapper's body and not the grid's.
struct DeferredOverlay: View {
    @Bindable var model: DocumentModel
    private let gate = OverlayRevealGate.shared

    var body: some View {
        if gate.isRevealed {
            OverlayView(model: model)
        } else {
            // A 1-point transparent placeholder carrying the reveal trigger, in
            // the same slot the control row will take, so it changes no geometry.
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .onAppear { gate.revealAfterFirstPaint() }
        }
    }
}
