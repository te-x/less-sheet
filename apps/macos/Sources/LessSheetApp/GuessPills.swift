import Contracts
import SwiftUI

// The guess-pills: one compact circular glass control per guessed parameter
// (header · separator · quote), each showing the CURRENT effective value and
// visually distinguishing guessed from user-overridden. Clicking a pill
// expands a vertical list of candidate values (plus a single-ASCII "custom…"
// entry for separator/quote); selecting one re-opens with the forced dialect.

struct PillsCluster: View {
    @Bindable var model: DocumentModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                GuessPill(kind: .header, glyph: DialectGlyph.header(model.dialect.hasHeader),
                          overridden: model.dialect.headerForced, model: model)
                GuessPill(kind: .separator, glyph: DialectGlyph.separator(model.dialect.separator),
                          overridden: model.dialect.separatorForced, model: model)
                GuessPill(kind: .quote, glyph: DialectGlyph.quote(model.dialect.quote),
                          overridden: model.dialect.quoteForced, model: model)
            }
            if let kind = model.expandedPill {
                PillOptions(kind: kind, model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.expandedPill)
    }
}

/// One circular guess-pill. Overridden pills are tinted (accent) so a glance
/// separates "the core guessed this" from "I set this".
struct GuessPill: View {
    let kind: PillKind
    let glyph: String
    let overridden: Bool
    @Bindable var model: DocumentModel

    var body: some View {
        Button {
            model.expandedPill = (model.expandedPill == kind) ? nil : kind
            model.revealOverlay()
        } label: {
            Text(glyph)
                .font(.callout.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassChrome(overridden ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Circle())
        .overlay {
            // Overridden pills carry a persistent accent ring ("you set this");
            // an expanded, still-guessed pill gets a neutral selection ring.
            // The ring also renders in frame dumps, where glass tint cannot.
            if overridden {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
            } else if model.expandedPill == kind {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            }
        }
        .accessibilityLabel(DialectGlyph.pillLabel(kind))
        .accessibilityValue(DialectGlyph.pillValue(kind, model.dialect))
        .accessibilityHint(overridden ? "Set by you" : "Guessed")
    }
}

/// The vertical candidate list for the expanded pill; selecting a value applies
/// it immediately (a dialect re-open). A checkmark marks the effective value.
struct PillOptions: View {
    let kind: PillKind
    @Bindable var model: DocumentModel
    @Environment(\.overlayDumpChrome) private var dumpChrome
    @State private var custom = ""
    @FocusState private var customFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch kind {
            case .header:
                row("First row is header", selected: model.dialect.hasHeader) { apply(.header(true)) }
                row("No header", selected: !model.dialect.hasHeader) { apply(.header(false)) }

            case .separator:
                ForEach(DialectCandidates.separators, id: \.self) { byte in
                    row(DialectGlyph.separatorName(byte),
                        selected: model.dialect.separator == byte) { apply(.separator(byte)) }
                }
                customField(placeholder: "Custom…") { byte in apply(.separator(byte)) }

            case .quote:
                ForEach(DialectCandidates.quotes, id: \.self) { byte in
                    row(DialectGlyph.quoteName(byte),
                        selected: model.dialect.quote == byte) { apply(.quote(byte)) }
                }
                row("None", selected: model.dialect.quote == nil) { apply(.quote(nil)) }
                customField(placeholder: "Custom…") { byte in apply(.quote(byte)) }
            }
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .glassChrome(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.callout)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func customField(placeholder: String, apply: @escaping (UInt8) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "character.cursor.ibeam").font(.caption).foregroundStyle(.secondary)
            if dumpChrome {
                // ImageRenderer can't snapshot a live TextField; show its label.
                Text(placeholder).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                TextField(placeholder, text: $custom)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .focused($customFocused)
                    .onChange(of: custom) { _, value in
                        // Exactly one ASCII character.
                        if let last = value.unicodeScalars.last, last.isASCII {
                            custom = String(last)
                        } else {
                            custom = ""
                        }
                    }
                    .onSubmit {
                        if let scalar = custom.unicodeScalars.first, scalar.isASCII {
                            apply(UInt8(scalar.value))
                        }
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .accessibilityLabel("Custom single character")
    }

    private func apply(_ change: DialectChange) {
        // A valid selection re-opens and collapses the pill; an invalid custom
        // byte (out of domain / colliding) leaves the list open for correction.
        if model.applyDialectChange(change) {
            custom = ""
            model.expandedPill = nil
        }
    }
}

/// Compact glyphs + user-vocabulary names for dialect values (identical terms
/// in pill, expanded list, and Configure — "Separator", "Quote character").
enum DialectGlyph {
    static func separator(_ byte: UInt8) -> String { charGlyph(byte) }
    static func quote(_ byte: UInt8?) -> String { byte.map(charGlyph) ?? "∅" }
    static func header(_ on: Bool) -> String { on ? "H" : "—" }

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

    static func pillValue(_ kind: PillKind, _ dialect: DialectReport) -> String {
        switch kind {
        case .header: return dialect.hasHeader ? "on" : "off"
        case .separator: return separatorName(dialect.separator)
        case .quote: return dialect.quote.map(quoteName) ?? "None"
        }
    }
}
