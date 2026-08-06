import Foundation
import Observation
import SwiftUI

/// Whether the always-visible glass control row is in the view hierarchy yet.
///
/// Process-global on purpose: once the overlay is revealed it STAYS revealed, so
/// a document re-open or a dialect change can never re-defer it. A per-view
/// `@State` would reset with the view's identity and make the chrome blink.
@MainActor
@Observable
final class OverlayRevealGate {
    static let shared = OverlayRevealGate()

    private(set) var isRevealed: Bool
    private var scheduled = false

    /// Determinism w.r.t. the verification hooks: every probe that drives or
    /// photographs the LIVE overlay (`FindProbe`, `JumpProbe`, `JumpStepProbe`,
    /// `FindEscapeProbe`, `CaptureProbe`, the `FrameDump` scenes,
    /// `SettingsRedesignProbe`, `LandingStallProbe`, …) runs from
    /// `documentContent`'s `.task(id:)`, and the ordering of that task against a
    /// `DispatchQueue.main.async` reveal is NOT guaranteed. So we never race it:
    /// on a verification run (`LaunchTuning.applies == false`) the deferral is
    /// switched off and the overlay is in the hierarchy from the FIRST pass,
    /// exactly as before this optimization existed.
    private init() { isRevealed = !LaunchTuning.applies }

    /// Reveals the overlay one main-queue turn from now — after the turn that
    /// laid out and drew the grid rows. Idempotent, and a no-op once revealed.
    func revealAfterFirstPaint() {
        guard !isRevealed, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { self.revealNow() }
    }

    /// Reveals immediately — the explicit "now, not next turn" entry for any
    /// caller that needs the live overlay in the hierarchy synchronously.
    func revealNow() { isRevealed = true }
}

/// The always-visible glass control row, inserted ONE main-queue turn after the
/// grid's first paint.
///
/// Why: `OverlayView` is a `GlassEffectContainer` with six glass controls and it
/// costs ~13 ms of the FIRST paint (measured by ablating it entirely: 172.0 ->
/// 158.7 ms to first row pixels on a 50 MB file). The rows are the data; the
/// controls are chrome, and the user cannot act on them in the first frame
/// anyway. The overlay is ALWAYS visible (no idle fade — the author, 2026-07-08), so
/// this is a DEFERRAL and never a removal: it is inserted with no transition,
/// no animation and no interaction required, so it reads as "always been there"
/// rather than as a pop-in.
///
/// Deliberately its own view: when the gate flips, only this wrapper's body is
/// re-evaluated — `documentContent` and the grid are not.
struct DeferredOverlay: View {
    @Bindable var model: DocumentModel
    private let gate = OverlayRevealGate.shared

    var body: some View {
        if gate.isRevealed {
            OverlayView(model: model)
        } else {
            // A 1-point transparent placeholder carrying the reveal trigger. It
            // occupies the same bottom-trailing slot the control row will, and
            // is smaller than the grid it sits over, so it changes no geometry.
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .onAppear { gate.revealAfterFirstPaint() }
        }
    }
}
