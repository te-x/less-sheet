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

// The floating overlay — the one signature element over a data-first window.
// A vertical Liquid Glass cluster (filename · jump-to-row · guess-pills ·
// Configure) revealed on pointer movement or keyboard focus and faded after
// ~2 s idle. 8pt spacing rhythm; one orchestrated reveal (fade + slight rise);
// Reduce Motion honored; every control accessibility-labelled.

struct OverlayView: View {
    @Bindable var model: DocumentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                FilenameChip(name: filename)
                JumpControlView(model: model)
                PillsCluster(model: model)
                ConfigureButton { AppDelegate.shared?.presentConfigure() }
            }
        }
        .fixedSize()                 // hug the cluster; don't fill the window
        .padding(.trailing, 24)
        .padding(.bottom, 24)
        .opacity(model.overlayRevealed ? 1 : 0)
        .offset(y: revealOffset)
        .allowsHitTesting(model.overlayRevealed)
        .animation(revealAnimation, value: model.overlayRevealed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewer controls")
    }

    private var filename: String {
        let name = (model.path as NSString).lastPathComponent
        return name.isEmpty ? "Untitled" : name
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

/// The document filename, display-only, on a glass capsule.
struct FilenameChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 260)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassChrome(.regular, in: Capsule())
            .accessibilityLabel("File \(name)")
    }
}

/// Jump-to-row: a glass button that opens a digits-only field showing the
/// current row-count knowledge; while a scan runs it shows progress with an
/// Esc-cancel affordance (ARCH req. 7).
struct JumpControlView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @FocusState private var fieldFocused: Bool
    @State private var text = ""
    @State private var expanded = false

    var body: some View {
        Group {
            if case let .scanning(_, _, progress) = model.jumpFlow {
                scanning(progress: progress)
            } else if expanded {
                field
            } else {
                button
            }
        }
        .glassChrome(.regular, in: Capsule())
        .onChange(of: expanded) { _, now in model.jumpFieldActive = now }
        .onChange(of: model.jumpFlow) { _, flow in
            // Landing or cancelling collapses the field back to the button.
            switch flow {
            case .landed, .cancelled, .idle: expanded = false
            case .scanning: break
            }
        }
        .onChange(of: model.jumpFocusRequests) { _, _ in
            // ⌘J: open the field and focus it (keyboard reveal path).
            if case .scanning = model.jumpFlow { return }
            expanded = true
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var button: some View {
        Button {
            expanded = true
            model.revealOverlay()
            DispatchQueue.main.async { fieldFocused = true }
        } label: {
            Text("Jump to row")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to row")
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Row", text: $text)
                .textFieldStyle(.plain)
                .font(.callout.monospacedDigit())
                .frame(width: 92)
                .focused($fieldFocused)
                .onSubmit(submit)
            Text(RowCountText.summary(model.rowCountInfo))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onExitCommand { expanded = false }          // Esc closes the field
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
            if case .scanning = model.jumpFlow {} else { expanded = false }
        }
        // Invalid input: keep the field open for correction (no re-open).
    }
}

/// A glass button opening the Configure window.
struct ConfigureButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Configure")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassChrome(.regular, in: Capsule())
        .accessibilityLabel("Configure")
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
