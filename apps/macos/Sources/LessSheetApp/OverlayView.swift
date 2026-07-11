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

            // ARCH-select-copy AC2: a brief, subtle "what was copied" notice —
            // floats above the control row, auto-cleared by the model after a
            // readable beat (`DocumentModel.completeCopy`), never blocking or
            // requiring dismissal.
            if let notice = model.copyNotice {
                CopyNoticeView(model: model, text: notice)
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

/// Jump-to-row (req. 6): a glass button that opens an upward popup with a
/// digits-only field showing the current row-count knowledge; while a scan runs
/// the popup shows progress with an Esc-cancel affordance (ARCH req. 7). Jump
/// behavior itself is unchanged — only its presentation moved into the popup.
struct JumpControlView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @Environment(\.overlayJumpRejected) private var dumpRejected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var text = ""
    @State private var shake: CGFloat = 0        // 0…1 drives the reject shake
    @State private var rejectedFlash = false     // red blink while true

    private var popupVisible: Bool {
        if model.jumpFieldActive { return true }
        if case .scanning = model.jumpFlow { return true }
        return false
    }

    /// The field shows its rejected (red) styling on a live blink or when a
    /// headless dump forces it.
    private var rejected: Bool { rejectedFlash || dumpRejected }

    var body: some View {
        Button {
            model.openJumpField()
            model.revealOverlay()
            DispatchQueue.main.async { fieldFocused = true }
        } label: {
            // A custom "jump from here to there" glyph (item 4): two stacked
            // circles joined by an arc that bulges right and arrows into the
            // lower circle. SF Symbols had nothing that read correctly.
            JumpArrowGlyph(lineWidth: 1.1)
                .foregroundStyle(.primary)
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(.regular.interactive(), in: Circle())
        .overlay(alignment: .top) {
            if popupVisible {
                // Float the popup above the button (expands upward); fixedSize
                // so it uses its own width, not the button's small frame. The
                // shake is applied here so a rejection nudges the whole popup.
                popup
                    .fixedSize()
                    .modifier(Shake(animatableData: shake))
                    .offset(y: -(OverlayMetrics.jumpPopupHeight + OverlayMetrics.popupGap))
            }
        }
        .help("Jump to a specific row number")
        .accessibilityLabel("Jump to row")
        .onChange(of: model.jumpFlow) { _, flow in
            switch flow {
            // Landing or cancelling collapses the popup back to the button.
            case .landed, .cancelled: model.jumpFieldActive = false
            // A rejection also lands the flow on .idle, but the field must STAY
            // open for correction — so .idle does NOT close it (item 4).
            case .idle: break
            case .scanning:
                // The scanning progress state reached the view layer — evidence
                // (main-actor) that progress rendered right after submit.
                JumpProbe.noteScanningShown()
            }
        }
        .onChange(of: model.jumpRejections) { _, _ in reject() }
        .onChange(of: model.jumpFocusRequests) { _, _ in
            // ⌘J: open the field and focus it (keyboard reveal path).
            if case .scanning = model.jumpFlow { return }
            model.openJumpField()
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    /// A rejected jump (item 4): keep the field open with its text selected for
    /// correction, blink it red, and — unless Reduce Motion — shake it briefly.
    private func reject() {
        model.jumpFieldActive = true
        fieldFocused = true
        DispatchQueue.main.async {   // select the text so a retype replaces it
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
        }
        rejectedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.5)) { rejectedFlash = false }
        }
        if !reduceMotion {
            shake = 0
            withAnimation(.linear(duration: 0.4)) { shake = 1 }
        }
        JumpProbe.noteRejectionShown()
    }

    @ViewBuilder
    private var popup: some View {
        Group {
            if case let .scanning(_, _, progress) = model.jumpFlow {
                // ARCH-stream-copy AC9 ("just wiring"): the scanning
                // progress bar + Cancel only SURFACE once the shared gate
                // says so (past ~500 ms) — a scan that lands sooner never
                // flickers it. Esc still cancels the REAL scan either way
                // (`field(onExit:)` below), so gating the VISUAL never
                // weakens cancellability.
                if model.jumpProgressIndication.isVisible {
                    scanning(progress: progress)
                } else {
                    field(onExit: { model.cancelJump() })
                }
            } else {
                field(onExit: { model.dismissPopups() })
            }
        }
        .glassChrome(.regular, in: Capsule())
    }

    /// The row/hint field. `onExit` differs by context (ARCH-stream-copy
    /// AC9): plain Esc dismisses the popup when idle, but while a
    /// sub-threshold scan is quietly running underneath (see `popup` above)
    /// Esc must still CANCEL that real scan, not merely hide UI that was
    /// never shown.
    private func field(onExit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Group {
                if dumpChrome {
                    // ImageRenderer can't snapshot a live TextField; show its state.
                    Text(text.isEmpty ? "Row" : text)
                        .foregroundStyle(rejected ? Color.red : (text.isEmpty ? Color.secondary : Color.primary))
                        .frame(width: 84, alignment: .leading)
                } else {
                    TextField("Row", text: $text)
                        .textFieldStyle(.plain)
                        .frame(width: 84)
                        .foregroundStyle(rejected ? Color.red : Color.primary)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                }
            }
            .font(.callout.monospacedDigit())
            // While filtered, the field takes ORIGINAL row numbers (ARCH
            // criterion 12/17), so the hint is scaled to the whole document
            // (`jumpRowCountInfo`), not the filtered row count.
            Text(RowCountText.summary(model.jumpRowCountInfo))
                .font(.caption)
                .foregroundStyle(rejected ? Color.red : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Red blink on rejection (item 4): a red ring over the capsule.
        .overlay { if rejected { Capsule().strokeBorder(Color.red, lineWidth: 2) } }
        .onExitCommand(perform: onExit)               // Esc: dismiss (idle) or cancel (scanning)
        .accessibilityLabel("Jump to row, \(RowCountText.summary(model.jumpRowCountInfo))")
        .accessibilityValue(rejected ? "No such row. Enter a row from 1 to \(model.jumpRowCountInfo.count)." : "")
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

/// The custom jump glyph (item 4): two circles stacked and horizontally
/// aligned; an arrow leaves the TOP circle heading south-east, arcs out to the
/// right, curves back south-west and arrows into the BOTTOM circle — "jump from
/// this row to that row". Drawn as stroked paths (no fill) so it adapts to
/// light/dark via the inherited foreground style; stroke weight matches the
/// neighbouring SF Symbols (~semibold).
struct JumpArrowGlyph: View {
    var lineWidth: CGFloat = 2
    /// Fraction of the (square) frame the glyph height fills (~10% up from the
    /// previous tuning).
    var fill: CGFloat = 0.43
    // TRUE content bounding box in design coords (NOT an outer design box):
    // circle-left … arc-right, top-circle-top … bottom-circle-bottom. Centering
    // THIS box in the frame centers the visible glyph exactly (the stroke adds a
    // symmetric outset, so it doesn't shift the centre).
    private let bMinX: CGFloat = 19, bMaxX: CGFloat = 56
    private let bMinY: CGFloat = 7,  bMaxY: CGFloat = 93

    var body: some View {
        GeometryReader { geo in
            let bw = bMaxX - bMinX, bh = bMaxY - bMinY
            let k = min(geo.size.width / bw, geo.size.height / bh) * fill
            // Center the content bbox in the frame on BOTH axes (no eyeballed
            // padding): map bbox-centre → frame-centre.
            let ox = (geo.size.width - bw * k) / 2 - bMinX * k
            let oy = (geo.size.height - bh * k) / 2 - bMinY * k
            let P = { (x: CGFloat, y: CGFloat) in CGPoint(x: ox + x * k, y: oy + y * k) }

            let rr: CGFloat = 11 * k          // small circles
            let topC = P(30, 18), botC = P(30, 82)
            let start = P(40, 26), end = P(40, 74)
            // A TRUE circular arc (constant radius) bulging right: its centre
            // sits to the LEFT of the vertical start→end chord, so the arc bows
            // out to the right — smoother than a Bézier.
            let arcCenter = P(30, 50)
            let arcR = hypot(start.x - arcCenter.x, start.y - arcCenter.y)
            let a1 = atan2(start.y - arcCenter.y, start.x - arcCenter.x)
            let a2 = atan2(end.y - arcCenter.y, end.x - arcCenter.x)

            ZStack {
                Path { p in
                    p.addEllipse(in: CGRect(x: topC.x - rr, y: topC.y - rr, width: 2 * rr, height: 2 * rr))
                    p.addEllipse(in: CGRect(x: botC.x - rr, y: botC.y - rr, width: 2 * rr, height: 2 * rr))
                }
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                Path { p in
                    p.addArc(center: arcCenter, radius: arcR,
                             startAngle: .radians(a1), endAngle: .radians(a2), clockwise: false)
                    // Arrowhead at the arrival: tangent to the arc at `end`
                    // (perpendicular to the end radius), pointing south-west into
                    // the bottom circle.
                    let dx = -(end.y - arcCenter.y), dy = (end.x - arcCenter.x)   // SW travel direction
                    let len = max(0.001, (dx * dx + dy * dy).squareRoot())
                    let bx = -dx / len, by = -dy / len         // unit vector back along the arc
                    let barb = 12 * k
                    let a: CGFloat = 0.55                       // ~31° half-spread
                    let ca = cos(a), sa = sin(a)
                    let b1 = CGPoint(x: end.x + barb * (bx * ca - by * sa),
                                     y: end.y + barb * (bx * sa + by * ca))
                    let b2 = CGPoint(x: end.x + barb * (bx * ca + by * sa),
                                     y: end.y + barb * (-bx * sa + by * ca))
                    p.move(to: b1); p.addLine(to: end); p.addLine(to: b2)
                }
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// A short horizontal shake for the rejected jump field (item 4); Reduce Motion
/// callers simply never drive it (blink only).
struct Shake: GeometryEffect {
    var amount: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat = 0     // animate 0 → 1 for one burst

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: amount * sin(animatableData * .pi * shakes * 2), y: 0))
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
