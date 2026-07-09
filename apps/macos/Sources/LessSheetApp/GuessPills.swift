import Contracts
import SwiftUI

// The dialect controls that sit in the bottom-right overlay bar: a header toggle
// and two dialect popups (separator, quote). All three are consistent-size glass
// circles showing the CURRENT effective value and visually distinguishing a
// guessed value from a user-overridden one (accent ring).
//
// - Header (req. 4): NO popup — a click toggles the header on/off immediately;
//   the glyph swaps "H" ↔ "H with a slash"; the tooltip (also the VoiceOver
//   hint) reads "File contains header" / "File contains no header".
// - Separator / Quote (req. 5): a click opens a small pill-shaped popup the same
//   width as the button, expanding UPWARD — a vertical stack of candidate glyphs
//   (plus Custom…), the current one marked. Selecting one applies immediately
//   through the existing re-open flow; Esc / click-away dismisses.
//
// Shared vocabulary with the Settings window is pinned in `DialectGlyph`
// ("First row is header", "Separator", "Quote character").

/// The header toggle (req. 4): immediate on/off, no popup.
struct HeaderButton: View {
    @Bindable var model: DocumentModel

    private var on: Bool { model.dialect.hasHeader }
    private var tooltip: String {
        on ? "First row is a header — click to treat it as data"
           : "First row is data — click to treat it as a header"
    }

    var body: some View {
        Button {
            model.applyDialectChange(.header(!on))
            model.revealOverlay()
        } label: {
            HeaderGlyph(on: on)
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(model.dialect.headerForced ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Circle())
        .overlay { if model.dialect.headerForced { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .help(tooltip)
        .accessibilityLabel(DialectGlyph.pillLabel(.header))
        .accessibilityValue(on ? "on" : "off")
        .accessibilityHint(tooltip)
    }
}

/// A solid "H" when the file has a header; in the NO-HEADER state the H fades
/// back and a full-strength diagonal slash crosses it, so the control reads as
/// "H negated" — the slash, not the H, carries the meaning. Semantic colors, so
/// the slash is full white in dark mode / full black in light mode either way.
struct HeaderGlyph: View {
    let on: Bool

    var body: some View {
        Text("H")
            .font(.callout.weight(.semibold))
            // Header ON: solid label color. Header OFF: faint (~0.3 of label
            // color) so the crossing slash dominates.
            .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.3)))
            .overlay {
                if !on {
                    // Full-strength (labelColor) and thicker than the H's stroke,
                    // so the negation is unmistakable in both appearances.
                    Capsule()
                        .fill(.primary)
                        .frame(width: 3, height: 24)
                        .rotationEffect(.degrees(45))
                }
            }
    }
}

/// A separator / quote control (req. 5): a glass button showing the current
/// value that opens a narrow pill popup of candidates above it.
struct DialectPopupButton: View {
    let kind: PillKind          // .separator or .quote
    @Bindable var model: DocumentModel

    private var isOpen: Bool { model.expandedPill == kind }

    private var glyph: String {
        switch kind {
        case .separator: return DialectGlyph.separator(model.dialect.separator)
        case .quote: return DialectGlyph.quote(model.dialect.quote)
        case .header: return ""
        }
    }

    private var overridden: Bool {
        switch kind {
        case .separator: return model.dialect.separatorForced
        case .quote: return model.dialect.quoteForced
        case .header: return model.dialect.headerForced
        }
    }

    var body: some View {
        Button {
            model.toggleExpandedPill(kind)
            model.revealOverlay()
        } label: {
            Text(glyph)
                .font(.callout.weight(.semibold))
                .frame(width: OverlayMetrics.controlSize, height: OverlayMetrics.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(overridden ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Circle())
        .overlay {
            if overridden {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isOpen {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .overlay(alignment: .top) {
            if isOpen {
                DialectPopup(kind: kind, model: model)
                    .fixedSize()   // size to content, not the button's frame
                    // Float the popup fully above the button — it expands upward
                    // (offset, so it never disturbs the button-row layout).
                    .offset(y: -(DialectPopup.height(for: kind) + OverlayMetrics.popupGap))
            }
        }
        .help(DialectGlyph.pillTooltip(kind))
        .accessibilityLabel(DialectGlyph.pillLabel(kind))
        .accessibilityValue(DialectGlyph.pillValue(kind, model.dialect))
        .accessibilityHint(overridden ? "Set by you" : "Guessed")
    }
}

/// The narrow (button-width) pill of candidate values for a separator / quote
/// control, stacked vertically and expanding upward. The current value is
/// marked; selecting one applies immediately (a dialect re-open). Esc dismisses.
struct DialectPopup: View {
    let kind: PillKind
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @State private var custom = ""
    @FocusState private var customFocused: Bool

    /// The popup's exact rendered height, so the button can float it a fixed
    /// distance above itself (no measure-then-reflow). Kept in step with the
    /// body's row count, `optionSize`, VStack spacing (4) and padding (4).
    static func height(for kind: PillKind) -> CGFloat {
        let rows: Int
        switch kind {
        case .separator: rows = DialectCandidates.separators.count + 1  // candidates + Custom
        case .quote: rows = DialectCandidates.quotes.count + 2           // candidates + None + Custom
        case .header: rows = 0
        }
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * OverlayMetrics.optionSize
            + CGFloat(rows - 1) * 4   // inter-row spacing
            + 2 * 4                   // top + bottom padding
    }

    var body: some View {
        VStack(spacing: 4) {
            switch kind {
            case .separator:
                ForEach(DialectCandidates.separators, id: \.self) { byte in
                    option(DialectGlyph.charGlyph(byte),
                           label: DialectGlyph.separatorName(byte),
                           selected: model.dialect.separator == byte) { apply(.separator(byte)) }
                }
                customEntry { apply(.separator($0)) }

            case .quote:
                ForEach(DialectCandidates.quotes, id: \.self) { byte in
                    option(DialectGlyph.charGlyph(byte),
                           label: DialectGlyph.quoteName(byte),
                           selected: model.dialect.quote == byte) { apply(.quote(byte)) }
                }
                option("∅", label: "None", selected: model.dialect.quote == nil) { apply(.quote(nil)) }
                customEntry { apply(.quote($0)) }

            case .header:
                EmptyView()
            }
        }
        .padding(4)
        .frame(width: OverlayMetrics.controlSize)
        .glassChrome(.regular, in: RoundedRectangle(cornerRadius: OverlayMetrics.controlSize / 2, style: .continuous))
        .onExitCommand { model.dismissPopups() }        // Esc dismisses
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(DialectGlyph.pillLabel(kind)) options")
    }

    private func option(_ glyph: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.callout.monospaced())
                .frame(width: OverlayMetrics.optionSize, height: OverlayMetrics.optionSize)
                .background { if selected { Circle().fill(Color.accentColor.opacity(0.25)) } }
                .overlay { if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// A single-ASCII-character custom entry. In frame dumps (where a live
    /// TextField can't be snapshotted) it renders as a static "＋".
    @ViewBuilder
    private func customEntry(apply: @escaping (UInt8) -> Void) -> some View {
        if dumpChrome {
            Text("＋")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: OverlayMetrics.optionSize, height: OverlayMetrics.optionSize)
                .help("Custom character")
                .accessibilityLabel("Custom single character")
        } else {
            TextField("", text: $custom)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .multilineTextAlignment(.center)
                .frame(width: OverlayMetrics.optionSize, height: OverlayMetrics.optionSize)
                .focused($customFocused)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)) }
                .onChange(of: custom) { _, value in
                    // Keep at most one ASCII character.
                    if let last = value.unicodeScalars.last, last.isASCII {
                        custom = String(last)
                    } else {
                        custom = ""
                    }
                }
                .onSubmit {
                    if let scalar = custom.unicodeScalars.first, scalar.isASCII { apply(UInt8(scalar.value)) }
                }
                .help("Custom character")
                .accessibilityLabel("Custom single character")
        }
    }

    private func apply(_ change: DialectChange) {
        // A valid selection re-opens and dismisses; an invalid custom byte
        // (out of domain / colliding) leaves the popup open for correction.
        if model.applyDialectChange(change) {
            custom = ""
            model.dismissPopups()
        }
    }
}

/// Compact glyphs + user-vocabulary names for dialect values (identical terms
/// in the popups and the Settings window — "First row is header", "Separator",
/// "Quote character").
enum DialectGlyph {
    static func separator(_ byte: UInt8) -> String { charGlyph(byte) }
    static func quote(_ byte: UInt8?) -> String { byte.map(charGlyph) ?? "∅" }

    static func charGlyph(_ byte: UInt8) -> String {
        switch byte {
        case 0x09: return "⇥"   // TAB
        case 0x20: return "␣"   // space
        default: return String(UnicodeScalar(byte))
        }
    }

    static func separatorName(_ byte: UInt8) -> String {
        switch byte {
        case 0x2C: return "Comma  ,"
        case 0x3B: return "Semicolon  ;"
        case 0x09: return "Tab"
        case 0x7C: return "Pipe  |"
        default: return "Character  \(charGlyph(byte))"
        }
    }

    static func quoteName(_ byte: UInt8) -> String {
        switch byte {
        case 0x22: return "Double quote  \""
        case 0x27: return "Single quote  '"
        default: return "Character  \(charGlyph(byte))"
        }
    }

    static func pillLabel(_ kind: PillKind) -> String {
        switch kind {
        case .header: return "First row is header"
        case .separator: return "Separator"
        case .quote: return "Quote character"
        }
    }

    /// The overlay tooltip for a separator/quote pill button (fuller than
    /// `pillLabel`, explaining what a click does); unused by the pills for
    /// `.header` (which has its own tooltip), kept here so the switch stays
    /// exhaustive.
    static func pillTooltip(_ kind: PillKind) -> String {
        switch kind {
        case .separator: return "Column separator — click to change (comma, tab, semicolon, …)"
        case .quote: return "Quote character — click to change"
        case .header: return "First row is a header (toggle)"
        }
    }

    static func pillValue(_ kind: PillKind, _ dialect: DialectReport) -> String {
        switch kind {
        case .header: return dialect.hasHeader ? "on" : "off"
        case .separator: return separatorName(dialect.separator)
        case .quote: return dialect.quote.map(quoteName) ?? "None"
        }
    }

    /// Plain name of a resolved encoding (ARCH req. 11 vocabulary).
    static func textEncodingName(_ encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return "ISO-8859-1 (Latin-1)"
        case .windows1252: return "Windows-1252"
        }
    }

    /// Plain name of one "Text encoding" picker option, not accounting for the
    /// Automatic subtitle (see `encodingOptionLabel`).
    static func encodingOverrideName(_ option: EncodingOverride) -> String {
        switch option {
        case .automatic: return "Automatic"
        case .utf8: return textEncodingName(.utf8)
        case .utf16LE: return textEncodingName(.utf16LE)
        case .utf16BE: return textEncodingName(.utf16BE)
        case .latin1: return textEncodingName(.latin1)
        case .windows1252: return textEncodingName(.windows1252)
        }
    }

    /// The "Text encoding" picker row label for one `EncodingPicker.options`
    /// entry (ARCH req. 11): Automatic always surfaces the report's resolved
    /// encoding ("Automatic — detected: Latin-1"), mirroring how the
    /// separator/quote pills always show their current effective value; the
    /// five concrete options are their plain name.
    static func encodingOptionLabel(_ option: EncodingOverride, detected: TextEncoding) -> String {
        guard option == .automatic else { return encodingOverrideName(option) }
        return "Automatic — detected: \(textEncodingName(detected))"
    }

    /// The current-selection label for the WHOLE "Text encoding" control (a
    /// collapsed Picker, or the headless Settings dump's read-out): the same
    /// rule as `encodingOptionLabel`, applied to the report's actual selection
    /// (`EncodingPicker.selection`/`.detected`).
    static func encodingValueLabel(_ dialect: DialectReport) -> String {
        encodingOptionLabel(EncodingPicker.selection(for: dialect), detected: EncodingPicker.detected(in: dialect))
    }
}
