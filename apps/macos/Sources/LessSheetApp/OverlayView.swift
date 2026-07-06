import Contracts
import SwiftUI

// Glass chrome with a headless-dump fallback. `glassEffect` needs a live
// compositor backdrop and renders transparent under `ImageRenderer`, so when
// the frame-dump environment flag is set we swap in an opaque material so the
// overlay is legible in verification PNGs. The live app always uses real glass.

extension EnvironmentValues {
    @Entry var overlayDumpChrome: Bool = false
}

private struct GlassChrome<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    @Environment(\.overlayDumpChrome) private var dumpChrome

    func body(content: Content) -> some View {
        if dumpChrome {
            content
                .background(.quaternary, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 1))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass in the running app; an opaque fallback in frame dumps.
    func glassChrome(_ glass: Glass = .regular, in shape: some Shape = Capsule()) -> some View {
        modifier(GlassChrome(glass: glass, shape: shape))
    }
}

/// Shared sizing for the overlay controls so all five read as one consistent
/// row (req. 3), plus the gap a popup floats above its button.
enum OverlayMetrics {
    static let controlSize: CGFloat = 36
    static let optionSize: CGFloat = 28
    static let popupGap: CGFloat = 10
    /// Height of the single-row jump popup (field / progress), used to float it
    /// above the button; a slight overestimate only widens the gap (never
    /// overlaps).
    static let jumpPopupHeight: CGFloat = 40
}

// The floating overlay — the one signature element over a data-first window.
// A single horizontal Liquid Glass row in the BOTTOM-RIGHT (req. 3), left→right:
// [Jump] [Header] [Separator] [Quote] [Settings]. Jump, Separator and Quote open
// small popups that expand UPWARD from their button; Header toggles immediately;
// Settings opens the Settings window. Revealed on pointer movement or keyboard
// focus, faded after ~2 s idle (the window title + traffic lights ride the same
// reveal). A click-away scrim dismisses any open popup. 8pt rhythm; one
// orchestrated reveal (fade + slight rise); Reduce Motion honored; every control
// accessibility-labelled.

struct OverlayView: View {
    @Bindable var model: DocumentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Click-away scrim — present ONLY while a popup is open, so ordinary
            // scrolling is never intercepted. Invisible; a tap dismisses.
            if model.anyPopupOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissPopups() }
                    .accessibilityHidden(true)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    JumpControlView(model: model)
                    HeaderButton(model: model)
                    DialectPopupButton(kind: .separator, model: model)
                    DialectPopupButton(kind: .quote, model: model)
                    SettingsButton { AppDelegate.shared?.presentSettings() }
                }
            }
            .fixedSize()                 // hug the row; don't fill the window
            .padding(.trailing, 24)
            .padding(.bottom, 24)
        }
        .opacity(model.overlayRevealed ? 1 : 0)
        .offset(y: revealOffset)
        .allowsHitTesting(model.overlayRevealed)
        .animation(revealAnimation, value: model.overlayRevealed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewer controls")
    }

    private var revealOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        return model.overlayRevealed ? 0 : 6      // slight rise on reveal
    }

    private var revealAnimation: Animation? {
        guard !reduceMotion else { return nil }
        // ~180 ms orchestrated reveal; gentle, unhurried fade-out.
        return model.overlayRevealed ? .easeOut(duration: 0.18) : .easeIn(duration: 0.5)
    }
}

/// Jump-to-row (req. 6): a glass button that opens an upward popup with a
/// digits-only field showing the current row-count knowledge; while a scan runs
/// the popup shows progress with an Esc-cancel affordance (ARCH req. 7). Jump
/// behavior itself is unchanged — only its presentation moved into the popup.
struct JumpControlView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @FocusState private var fieldFocused: Bool
    @State private var text = ""

    private var popupVisible: Bool {
        if model.jumpFieldActive { return true }
        if case .scanning = model.jumpFlow { return true }
        return false
    }

    var body: some View {
        Button {
            model.openJumpField()
            model.revealOverlay()
            DispatchQueue.main.async { fieldFocused = true }
        } label: {
            // A curved point-to-point arrow reads as "jump from here to there"
            // (item 4); the plain down-arrow read as "jump to end". VoiceOver
            // label stays "Jump to row".
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.callout.weight(.semibold))
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(.regular.interactive(), in: Circle())
        .overlay(alignment: .top) {
            if popupVisible {
                // Float the popup above the button (expands upward); fixedSize
                // so it uses its own width, not the button's small frame.
                popup.fixedSize().offset(y: -(OverlayMetrics.jumpPopupHeight + OverlayMetrics.popupGap))
            }
        }
        .help("Jump to row")
        .accessibilityLabel("Jump to row")
        .onChange(of: model.jumpFlow) { _, flow in
            // Landing or cancelling collapses the popup back to the button.
            switch flow {
            case .landed, .cancelled, .idle: model.jumpFieldActive = false
            case .scanning:
                // The scanning progress state reached the view layer — evidence
                // (main-actor) that progress rendered right after submit.
                JumpProbe.noteScanningShown()
            }
        }
        .onChange(of: model.jumpFocusRequests) { _, _ in
            // ⌘J: open the field and focus it (keyboard reveal path).
            if case .scanning = model.jumpFlow { return }
            model.openJumpField()
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    @ViewBuilder
    private var popup: some View {
        Group {
            if case let .scanning(_, _, progress) = model.jumpFlow {
                scanning(progress: progress)
            } else {
                field
            }
        }
        .glassChrome(.regular, in: Capsule())
    }

    private var field: some View {
        HStack(spacing: 8) {
            Group {
                if dumpChrome {
                    // ImageRenderer can't snapshot a live TextField; show its state.
                    Text(text.isEmpty ? "Row" : text)
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                        .frame(width: 84, alignment: .leading)
                } else {
                    TextField("Row", text: $text)
                        .textFieldStyle(.plain)
                        .frame(width: 84)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                }
            }
            .font(.callout.monospacedDigit())
            Text(RowCountText.summary(model.rowCountInfo))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onExitCommand { model.dismissPopups() }      // Esc closes the field
        .accessibilityLabel("Jump to row, \(RowCountText.summary(model.rowCountInfo))")
    }

    @ViewBuilder
    private func progressBar(_ progress: Double) -> some View {
        let fraction = max(0, min(1, progress))
        if dumpChrome {
            // ImageRenderer can't snapshot a live ProgressView; draw a static bar.
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 96, height: 6)
                Capsule().fill(Color.accentColor).frame(width: 96 * fraction, height: 6)
            }
        } else {
            ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 96)
        }
    }

    private func scanning(progress: Double) -> some View {
        HStack(spacing: 8) {
            progressBar(progress)
            Text("\(Int((max(0, min(1, progress))) * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { model.cancelJump() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onExitCommand { model.cancelJump() }         // Esc cancels the scan
        .accessibilityLabel("Scanning to row, \(Int(progress * 100)) percent. Press Escape to cancel.")
    }

    private func submit() {
        if model.submitJump(text) {
            text = ""
            if case .scanning = model.jumpFlow {} else { model.jumpFieldActive = false }
        }
        // Invalid input: keep the field open for correction (no re-open).
    }
}

/// A glass gear button opening the Settings window (req. 7): no word, its
/// meaning carried by the tooltip and VoiceOver label.
struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.callout.weight(.semibold))
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(.regular.interactive(), in: Circle())
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

/// Row-count knowledge as overlay copy: exact "N rows" or the estimating form
/// "~12.4M rows, estimating…" (ARCH req. 7). User vocabulary; sentence case.
enum RowCountText {
    static func summary(_ info: RowCountInfo) -> String {
        if info.isExact {
            return "\(info.count) row\(info.count == 1 ? "" : "s")"
        }
        return "~\(abbreviated(info.count)) rows, estimating…"
    }

    static func abbreviated(_ n: UInt64) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
        default: return "\(n)"
        }
    }
}
