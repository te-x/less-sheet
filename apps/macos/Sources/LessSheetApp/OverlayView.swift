import AppKit
import Contracts
import SwiftUI

// Glass chrome with a headless-dump fallback. `glassEffect` needs a live
// compositor backdrop and renders transparent under `ImageRenderer`, so when
// the frame-dump environment flag is set we swap in an opaque material so the
// overlay is legible in verification PNGs. The live app always uses real glass.

extension EnvironmentValues {
    @Entry var overlayDumpChrome: Bool = false
    /// Forces the jump field's rejected (red) styling in a headless dump so the
    /// rejection moment can be captured off-screen (item 4).
    @Entry var overlayJumpRejected: Bool = false
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
// [Find] [Jump] [Header] [Separator] [Quote] [Settings]. Find, Jump, Separator
// and Quote open small popups that expand UPWARD from their button; Header
// toggles immediately; Settings opens the Settings window. Revealed on pointer
// movement or keyboard
// focus, faded after ~2 s idle (the window title + traffic lights ride the same
// reveal). A click-away scrim dismisses any open popup. 8pt rhythm; one
// orchestrated reveal (fade + slight rise); Reduce Motion honored; every control
// accessibility-labelled.

struct OverlayView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Click-away scrim — clicks dismiss, while wheel events pass to the
            // native grid. An active search is navigation chrome, not a modal
            // interaction that replaces normal viewport scrolling. SKIPPED in
            // headless dumps: it is an NSViewRepresentable, which ImageRenderer
            // renders as a full-frame red "no entry" placeholder (masking the
            // whole scene), and a dump has no clicks to dismiss anyway.
            if model.anyPopupOpen && !dumpChrome {
                PopupDismissScrim(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }

            // Brief, subtle notices floating above the control row, auto-
            // cleared by the model after a readable beat, never blocking or
            // requiring dismissal: the "what was copied" notice (ARCH-select-
            // copy AC2) and the header-toggle "what changed" notice. Stacked
            // when both are live, so neither ever covers the other.
            if model.copyNotice != nil || model.dialectNotice != nil {
                VStack(alignment: .trailing, spacing: 8) {
                    if let notice = model.dialectNotice {
                        NoticeCapsule(text: notice)
                    }
                    if let notice = model.copyNotice {
                        CopyNoticeView(model: model, text: notice)
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, 24 + OverlayMetrics.controlSize + 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    // The filtered banner rides the control row, left of Find,
                    // while a filter is active (reveals/fades with the row).
                    if model.filterBanner != nil {
                        FilterBannerView(model: model)
                    }
                    FindControlView(model: model)
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
        // Always visible (the author 2026-07-08: no fade — controls, traffic lights,
        // and the title-bar filename all stay put).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewer controls")
        .animation(.easeInOut(duration: 0.2), value: model.copyNotice)
        .animation(.easeInOut(duration: 0.2), value: model.dialectNotice)
    }
}

/// A plain transient notice pill — the same glass language as the copy notice,
/// for one-line "what changed" feedback that needs no progress or cancel
/// affordance (currently the header toggle).
struct NoticeCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassChrome(.regular, in: Capsule())
            .accessibilityLabel(text)
    }
}

/// The network-open progress affordance (ARCH-network-source req 10 / AC9;
/// round-2 review finding 1) — the SAME glass-capsule language as
/// `CopyNoticeView`/`JumpControlView`'s popup, but ALWAYS visible from the
/// instant the open starts (no 500 ms `DelayedProgressGate` threshold: network
/// latency is unpredictable even for a small file). Determinate (a linear bar +
/// percentage) once `Content-Length`/`Content-Range` is known; indeterminate
/// (a spinner + live byte counter) otherwise. Carries its own Cancel, mirroring
/// the jump-scan popup's Cancel/Esc — `model.cancelNetworkOpen()` signals the
/// in-flight open-job.
struct NetworkOpenBanner: View {
    @Bindable var model: DocumentModel
    let progress: NetworkOpenProgress

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text(Self.byteFormatter.string(fromByteCount: Int64(progress.bytesFetched)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Opening URL…")
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button("Cancel", role: .cancel) { model.cancelNetworkOpen() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassChrome(.regular, in: Capsule())
        .onExitCommand { model.cancelNetworkOpen() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let fraction = progress.fraction {
            return "Opening URL, \(Int((fraction * 100).rounded())) percent. Press Escape to cancel."
        }
        let fetched = Self.byteFormatter.string(fromByteCount: Int64(progress.bytesFetched))
        return "Opening URL, \(fetched) fetched. Press Escape to cancel."
    }
}

/// Full-window click-away surface for floating controls. The former SwiftUI
/// `Color.clear.contentShape` swallowed wheel events because it was the view
/// hit-tested above the grid for the whole lifetime of an idle Find popup.
/// This native surface preserves click-away and forwards the original wheel
/// event to the document's real NSScrollView.
private struct PopupDismissScrim: NSViewRepresentable {
    let model: DocumentModel

    func makeNSView(context: Context) -> PopupDismissScrimView {
        let view = PopupDismissScrimView()
        view.model = model
        return view
    }

    func updateNSView(_ view: PopupDismissScrimView, context: Context) {
        view.model = model
    }
}

@MainActor
final class PopupDismissScrimView: NSView {
    static weak var live: PopupDismissScrimView?
    weak var model: DocumentModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.live = self
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.live = self
        setAccessibilityElement(false)
    }

    override func mouseDown(with event: NSEvent) {
        model?.dismissPopups()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let model, let controller = NativeGridController.live,
              controller.model === model
        else {
            super.scrollWheel(with: event)
            return
        }
        controller.forwardScrollWheel(event)
    }
}

/// The post-copy notice pill (ARCH-select-copy AC2) — same glass language as
/// the control row. While the copy is STILL RUNNING (`model.copyInFlight`,
/// round 2 finding 2) it carries a Cancel button + an Esc affordance,
/// mirroring the jump-scanning popup's own Cancel/`onExitCommand`
/// (`JumpControlView.scanning` below) — the grid's own `SheetTableView.
/// cancelOperation(_:)` override is the PRIMARY way Esc reaches
/// `DocumentModel.cancelCopy` (it fires whenever the grid itself is first
/// responder, the common case right after ⌘C); this is the belt-and-
/// suspenders match for whatever else might hold focus. Once the build
/// finishes, `copyInFlight` flips false and this reverts to a static label —
/// nothing left to cancel.
struct CopyNoticeView: View {
    @Bindable var model: DocumentModel
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            // ARCH-stream-copy AC8: the SAME delayed-progress affordance
            // every long op in this app drives, gated by `model.copyProgress`
            // — a no-op once the copy is done/cancelled, or before it has
            // run past the shared ~500 ms threshold.
            DelayedProgressSpinner(indication: model.copyProgress)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if model.copyInFlight {
                Button("Cancel", role: .cancel) { model.cancelCopy() }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassChrome(.regular, in: Capsule())
        .onExitCommand { if model.copyInFlight { model.cancelCopy() } }
        .accessibilityLabel(model.copyInFlight ? "\(text). Press Escape to cancel." : text)
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
        .help("Settings — header, separator, quote, text encoding, and column visibility")
        .accessibilityLabel("Settings")
    }
}

/// Row-count knowledge as overlay copy: exact "N rows"; the estimating form
/// "~12.4M rows, estimating…" for a known-total doc still converging (ARCH
/// req. 7); or the lower-bound form "≥N rows" for an UNKNOWN-length network
/// stream whose total firms only at EOF (never-full-download-streaming AC12).
/// User vocabulary; sentence case.
enum RowCountText {
    static func summary(_ info: RowCountInfo, unknownTotal: Bool = false) -> String {
        if info.isExact {
            return "\(info.count) row\(info.count == 1 ? "" : "s")"
        }
        if unknownTotal {
            return "≥\(abbreviated(info.count)) rows"
        }
        return "~\(abbreviated(info.count)) rows, estimating…"
    }

    static func abbreviated(_ count: UInt64) -> String {
        switch count {
        case 1_000_000_000...: return String(format: "%.1fB", Double(count) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(count) / 1e6)
        case 1_000...: return String(format: "%.1fK", Double(count) / 1e3)
        default: return "\(count)"
        }
    }
}
