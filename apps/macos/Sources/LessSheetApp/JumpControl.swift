import AppKit
import Contracts
import SwiftUI

// Jump-to-row overlay controls, split out of OverlayView.swift to keep each
// file within the length budget. Pure code motion — no behavior change.

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
        let rowSummary = RowCountText.summary(
            model.jumpRowCountInfo, unknownTotal: model.documentTotalUnknown)
        return HStack(spacing: 8) {
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
            Text(rowSummary)
                .font(.caption)
                .foregroundStyle(rejected ? Color.red : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Red blink on rejection (item 4): a red ring over the capsule.
        .overlay { if rejected { Capsule().strokeBorder(Color.red, lineWidth: 2) } }
        .onExitCommand(perform: onExit)               // Esc: dismiss (idle) or cancel (scanning)
        .accessibilityLabel("Jump to row, \(rowSummary)")
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
    private let bMinY: CGFloat = 7, bMaxY: CGFloat = 93

    var body: some View {
        GeometryReader { geo in
            let boxWidth = bMaxX - bMinX, boxHeight = bMaxY - bMinY
            let scale = min(geo.size.width / boxWidth, geo.size.height / boxHeight) * fill
            // Center the content bbox in the frame on BOTH axes (no eyeballed
            // padding): map bbox-centre → frame-centre.
            let originX = (geo.size.width - boxWidth * scale) / 2 - bMinX * scale
            let originY = (geo.size.height - boxHeight * scale) / 2 - bMinY * scale
            let mapPoint = { (pointX: CGFloat, pointY: CGFloat) in
                CGPoint(x: originX + pointX * scale, y: originY + pointY * scale)
            }

            let dotRadius: CGFloat = 11 * scale          // small circles
            let topC = mapPoint(30, 18), botC = mapPoint(30, 82)
            let start = mapPoint(40, 26), end = mapPoint(40, 74)
            // A TRUE circular arc (constant radius) bulging right: its centre
            // sits to the LEFT of the vertical start→end chord, so the arc bows
            // out to the right — smoother than a Bézier.
            let arcCenter = mapPoint(30, 50)
            let arcR = hypot(start.x - arcCenter.x, start.y - arcCenter.y)
            let arcStartAngle = atan2(start.y - arcCenter.y, start.x - arcCenter.x)
            let arcEndAngle = atan2(end.y - arcCenter.y, end.x - arcCenter.x)

            ZStack {
                Path { path in
                    path.addEllipse(in: CGRect(x: topC.x - dotRadius, y: topC.y - dotRadius,
                                               width: 2 * dotRadius, height: 2 * dotRadius))
                    path.addEllipse(in: CGRect(x: botC.x - dotRadius, y: botC.y - dotRadius,
                                               width: 2 * dotRadius, height: 2 * dotRadius))
                }
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                Path { path in
                    path.addArc(center: arcCenter, radius: arcR,
                                startAngle: .radians(arcStartAngle),
                                endAngle: .radians(arcEndAngle), clockwise: false)
                    // Arrowhead at the arrival: tangent to the arc at `end`
                    // (perpendicular to the end radius), pointing south-west into
                    // the bottom circle.
                    let travelX = -(end.y - arcCenter.y), travelY = (end.x - arcCenter.x)
                    let len = max(0.001, (travelX * travelX + travelY * travelY).squareRoot())
                    let backX = -travelX / len, backY = -travelY / len  // unit vector back along arc
                    let barb = 12 * scale
                    let halfSpread: CGFloat = 0.55  // ~31° half-spread
                    let cosSpread = cos(halfSpread), sinSpread = sin(halfSpread)
                    let barbLeft = CGPoint(x: end.x + barb * (backX * cosSpread - backY * sinSpread),
                                           y: end.y + barb * (backX * sinSpread + backY * cosSpread))
                    let barbRight = CGPoint(x: end.x + barb * (backX * cosSpread + backY * sinSpread),
                                            y: end.y + barb * (-backX * sinSpread + backY * cosSpread))
                    path.move(to: barbLeft); path.addLine(to: end); path.addLine(to: barbRight)
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
