import AppKit
import Contracts
import SwiftUI

// Glass chrome, with an opaque fallback for headless dumps: the glass effect
// needs a live compositor backdrop and renders transparent off-screen, which
// would leave the overlay invisible in a verification PNG.

extension EnvironmentValues {
    @Entry var overlayDumpChrome: Bool = false
    /// Forces the jump field's rejected styling, so that moment can be captured
    /// off-screen.
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

/// Shared sizing, so every overlay control reads as one consistent row.
enum OverlayMetrics {
    static let controlSize: CGFloat = 36
    static let optionSize: CGFloat = 28
    static let popupGap: CGFloat = 10
    /// Used to float the jump popup above its button; a slight overestimate only
    /// widens the gap, and can never overlap.
    static let jumpPopupHeight: CGFloat = 40
}

/// The floating control row, bottom-right: Find, Jump, Header, Separator, Quote,
/// Settings. Find, Jump, Separator and Quote open popups that expand upward;
/// Header toggles immediately. Always visible — there is no idle fade — with a
/// click-away scrim over any open popup.
struct OverlayView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Clicks dismiss; wheel events still reach the grid, since an active
            // search is navigation chrome rather than a modal interaction.
            // Skipped in a dump: `ImageRenderer` paints a representable as a
            // full-frame placeholder, masking the whole scene.
            if model.anyPopupOpen && !dumpChrome {
                PopupDismissScrim(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }

            // Brief notices above the control row, auto-cleared after a readable
            // beat and never requiring dismissal. Stacked when both are live, so
            // neither can cover the other.
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Viewer controls")
        .animation(.easeInOut(duration: 0.2), value: model.copyNotice)
        .animation(.easeInOut(duration: 0.2), value: model.dialectNotice)
    }
}

/// A transient notice pill for one-line "what changed" feedback that needs no
/// progress or cancel affordance.
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

/// The network-open progress affordance: the same glass language as the other
/// popups, but visible from the instant the open starts rather than behind the
/// shared delay gate, because network latency is unpredictable even for a small
/// file. Determinate once the length is known, indeterminate with a live byte
/// counter otherwise.
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

/// The click-away surface. A SwiftUI `Color.clear.contentShape` swallowed wheel
/// events, because it is the view hit-tested above the grid for the whole
/// lifetime of an idle popup; this one forwards the original event to the real
/// scroll view instead.
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

/// The post-copy notice pill. While the copy is still running it carries a
/// Cancel button and an Esc affordance; the grid's own Esc override is the
/// primary route to that, since the grid is usually first responder right after
/// ⌘C, and this covers whatever else might hold focus. Once the copy finishes
/// there is nothing left to cancel and this reverts to a static label.
struct CopyNoticeView: View {
    @Bindable var model: DocumentModel
    let text: String

    var body: some View {
        HStack(spacing: 8) {
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

/// The Settings button: no word, its meaning carried by the tooltip and the
/// accessibility label.
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

/// Row-count knowledge as overlay copy: the exact "N rows", the converging
/// "~12.4M rows, estimating…", or the lower-bound "≥N rows" for an
/// unknown-length network stream whose total firms only at EOF.
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
