import AppKit
import Contracts
import SwiftUI

/// Jump-to-row: a button opening a popup with a digits-only field that shows
/// the current row-count knowledge. While a scan runs the popup shows progress
/// with an Esc-cancel affordance.
struct JumpControlView: View {
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @Environment(\.overlayJumpRejected) private var dumpRejected
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var shake: CGFloat = 0        // 0…1 drives the reject shake
    @State private var rejectedFlash = false     // red blink while true

    private var popupVisible: Bool {
        if model.jumpFieldActive { return true }
        if case .scanning = model.jumpFlow { return true }
        return false
    }

    /// Red on a live blink, or when a dump forces it.
    private var rejected: Bool { rejectedFlash || dumpRejected }

    var body: some View {
        Button {
            model.openJumpField()
            DispatchQueue.main.async { fieldFocused = true }
        } label: {
            // A custom glyph: SF Symbols had nothing that reads as "jump from
            // this row to that one".
            JumpArrowGlyph(lineWidth: 1.1)
                .foregroundStyle(.primary)
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(.regular.interactive(), in: Circle())
        .overlay(alignment: .top) {
            if popupVisible {
                // `fixedSize` so the popup uses its own width, not the button's
                // small frame. The shake sits here, so a rejection nudges it all.
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
            case .landed, .cancelled: model.jumpFieldActive = false
            // A rejection also lands on .idle, but the field must STAY open for
            // correction — so .idle deliberately does not close it.
            case .idle: break
            case .scanning:
                JumpProbe.noteScanningShown()
            }
        }
        .onChange(of: model.jumpRejections) { _, _ in reject() }
        .onChange(of: model.jumpFocusRequests) { _, _ in
            if case .scanning = model.jumpFlow { return }
            model.openJumpField()
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    /// Keep the field open with its text selected for correction, blink it red,
    /// and — unless Reduce Motion — shake it.
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
                // The progress bar surfaces only past the shared threshold, so a
                // scan that lands sooner never flickers it. Esc still cancels the
                // REAL scan either way, so gating the visual never weakens
                // cancellability.
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

    /// `onExit` differs by context: Esc dismisses the popup when idle, but while
    /// a sub-threshold scan is quietly running underneath it must CANCEL that
    /// real scan, not merely hide UI that was never shown.
    private func field(onExit: @escaping () -> Void) -> some View {
        let rowSummary = RowCountText.summary(
            model.jumpRowCountInfo, unknownTotal: model.documentTotalUnknown)
        return HStack(spacing: 8) {
            Group {
                if dumpChrome {
                    // A dump cannot capture a live TextField, so mirror its state.
                    let typed = model.jumpFieldText
                    Text(typed.isEmpty ? "Row" : typed)
                        .foregroundStyle(rejected ? Color.red : (typed.isEmpty ? Color.secondary : Color.primary))
                        .frame(width: 84, alignment: .leading)
                } else {
                    TextField("Row", text: $model.jumpFieldText)
                        .textFieldStyle(.plain)
                        .frame(width: 84)
                        .foregroundStyle(rejected ? Color.red : Color.primary)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                        // ↑/↓ only EDIT the field; nothing travels until Enter.
                        // Attached to the field itself, so a closed popup leaves
                        // the arrows to the grid. `.repeat` is what makes HOLDING
                        // an arrow keep stepping, as every stepper does; `.up` is
                        // what ends the hold, so the acceleration cannot carry
                        // into the user's next single tap.
                        .onKeyPress(.upArrow, phases: [.down, .repeat, .up]) { stepped(.towardStart, $0) }
                        .onKeyPress(.downArrow, phases: [.down, .repeat, .up]) { stepped(.towardEnd, $0) }
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
            // A dump cannot capture a live ProgressView; draw a static bar.
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
        if model.submitJump(model.jumpFieldText) {
            model.jumpFieldText = ""
            if case .scanning = model.jumpFlow {} else { model.jumpFieldActive = false }
        }
        // Invalid input keeps the field open for correction.
    }

    /// A press or auto-repeat steps the field's number; a RELEASE ends the hold.
    /// Either way the key is consumed, so the field editor never also moves the
    /// caret.
    private func stepped(_ direction: JumpFieldStep, _ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.phase.contains(.up) {
            model.endJumpFieldHold()
        } else {
            model.stepJumpField(direction)
        }
        return .handled
    }
}

/// Two stacked circles with an arrow arcing from the top one into the bottom —
/// "jump from this row to that row". Stroked paths with no fill, so it adapts to
/// light and dark through the inherited foreground style.
struct JumpArrowGlyph: View {
    var lineWidth: CGFloat = 2
    /// Fraction of the square frame the glyph height fills.
    var fill: CGFloat = 0.43
    // The TRUE content bounding box, not an outer design box: centering THIS
    // centers the visible glyph exactly, since the stroke outsets symmetrically.
    private let bMinX: CGFloat = 19, bMaxX: CGFloat = 56
    private let bMinY: CGFloat = 7, bMaxY: CGFloat = 93

    var body: some View {
        GeometryReader { geo in
            let boxWidth = bMaxX - bMinX, boxHeight = bMaxY - bMinY
            let scale = min(geo.size.width / boxWidth, geo.size.height / boxHeight) * fill
            let originX = (geo.size.width - boxWidth * scale) / 2 - bMinX * scale
            let originY = (geo.size.height - boxHeight * scale) / 2 - bMinY * scale
            let mapPoint = { (pointX: CGFloat, pointY: CGFloat) in
                CGPoint(x: originX + pointX * scale, y: originY + pointY * scale)
            }

            let dotRadius: CGFloat = 11 * scale
            let topC = mapPoint(30, 18), botC = mapPoint(30, 82)
            let start = mapPoint(40, 26), end = mapPoint(40, 74)
            // A true circular arc rather than a Bézier — constant radius reads
            // smoother — with its centre left of the chord so it bows right.
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
