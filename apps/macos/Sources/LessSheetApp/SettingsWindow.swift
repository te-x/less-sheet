import Contracts
import SwiftUI

// The Settings window's content (ARCH req. 9): a normal titled window with the
// SAME three parse parameters as the overlay controls — bound to the same
// session state, so a change here re-opens the document exactly as a popup would
// — plus per-column visibility checkboxes (the last visible column's box
// disabled). The parameter terms are identical to the popups' ("First row is
// header", "Separator", "Quote character"). The form leaves obvious room for
// future datatype/formatting sections and ships no dead controls.
//
// csv-hardening (ARCH req. 11/12) adds a fourth Parsing control, "Text
// encoding": Automatic + the five forced encodings, routed through the SAME
// `applyDialectChange` re-open path as the other three — it is deliberately
// NOT an overlay pill (per the ARCH), so it lives only here.

struct SettingsView: View {
    @Bindable var model: DocumentModel

    // Custom separator/quote entry (parity with the overlay pills, which offer a
    // "Custom…" single-ASCII-character field). The fixed pickers can only PICK a
    // preset or echo an already-forced custom byte; selecting "Custom…" reveals
    // an inline one-character field routed through the SAME `applyDialectChange`
    // funnel, so the frozen `DialectComposer` still owns validation (ASCII
    // 0x01–0x7F, not CR/LF, separator ≠ quote — an invalid byte is a no-op).
    @State private var showSeparatorCustom = false
    @State private var showQuoteCustom = false
    @State private var separatorCustomText = ""
    @State private var quoteCustomText = ""
    @FocusState private var customFocus: CustomField?

    private enum CustomField { case separator, quote }
    private enum SeparatorChoice: Hashable { case byte(UInt8); case custom }
    private enum QuoteChoice: Hashable { case byte(UInt8); case none; case custom }

    var body: some View {
        Form {
            Section("Parsing") {
                Toggle("First row is header", isOn: headerBinding)

                Picker("Separator", selection: separatorChoiceBinding) {
                    ForEach(separatorOptions, id: \.self) { byte in
                        Text(DialectGlyph.separatorName(byte)).tag(SeparatorChoice.byte(byte))
                    }
                    Text("Custom…").tag(SeparatorChoice.custom)
                }
                if showSeparatorCustom {
                    customCharField(text: $separatorCustomText, field: .separator) { byte in
                        if model.applyDialectChange(.separator(byte)) { showSeparatorCustom = false }
                        separatorCustomText = ""
                    }
                }

                Picker("Quote character", selection: quoteChoiceBinding) {
                    Text("Double quote  \"").tag(QuoteChoice.byte(0x22))
                    Text("Single quote  '").tag(QuoteChoice.byte(0x27))
                    Text("None").tag(QuoteChoice.none)
                    if let custom = customQuote {
                        Text(DialectGlyph.quoteName(custom)).tag(QuoteChoice.byte(custom))
                    }
                    Text("Custom…").tag(QuoteChoice.custom)
                }
                if showQuoteCustom {
                    customCharField(text: $quoteCustomText, field: .quote) { byte in
                        if model.applyDialectChange(.quote(byte)) { showQuoteCustom = false }
                        quoteCustomText = ""
                    }
                }

                // `EncodingOverride` (Contracts) isn't Hashable, so the picker
                // binds an INDEX into the pinned `EncodingPicker.options` order
                // rather than the enum itself; the labels + re-open semantics
                // still come straight from the Contracts view-model.
                Picker("Text encoding", selection: encodingIndexBinding) {
                    ForEach(Array(EncodingPicker.options.enumerated()), id: \.offset) { index, option in
                        Text(DialectGlyph.encodingOptionLabel(option, detected: detectedEncoding)).tag(index)
                    }
                }
            }

            if model.columnCount > 0 {
                Section("Columns") {
                    ForEach(0..<model.columnCount, id: \.self) { column in
                        Toggle(model.columnLabel(column), isOn: visibilityBinding(column))
                            .disabled(isLastVisible(column))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 340, minHeight: 320)
    }

    // MARK: Parse-parameter bindings (write == a dialect re-open)

    private var headerBinding: Binding<Bool> {
        Binding(get: { model.dialect.hasHeader },
                set: { model.applyDialectChange(.header($0)) })
    }

    /// Separator picker selection. While the "Custom…" field is open the picker
    /// reads as `.custom` (so it stays highlighted); otherwise it reflects the
    /// effective byte. Picking a preset closes any open custom field and
    /// re-opens; picking "Custom…" reveals the inline field and focuses it.
    private var separatorChoiceBinding: Binding<SeparatorChoice> {
        Binding(
            get: { showSeparatorCustom ? .custom : .byte(model.dialect.separator) },
            set: { choice in
                switch choice {
                case .byte(let b):
                    showSeparatorCustom = false
                    model.applyDialectChange(.separator(b))
                case .custom:
                    showSeparatorCustom = true
                    customFocus = .separator
                }
            }
        )
    }

    private var quoteChoiceBinding: Binding<QuoteChoice> {
        Binding(
            get: {
                if showQuoteCustom { return .custom }
                guard let q = model.dialect.quote else { return .none }
                return .byte(q)
            },
            set: { choice in
                switch choice {
                case .byte(let b):
                    showQuoteCustom = false
                    model.applyDialectChange(.quote(b))
                case .none:
                    showQuoteCustom = false
                    model.applyDialectChange(.quote(nil))
                case .custom:
                    showQuoteCustom = true
                    customFocus = .quote
                }
            }
        )
    }

    /// One-character ASCII entry, mirroring the overlay pills' custom field:
    /// keep only the last ASCII character typed; commit on Enter. Validation
    /// (byte range, CR/LF, separator≠quote) is the composer's job — a rejected
    /// byte simply doesn't re-open.
    private func customCharField(
        text: Binding<String>,
        field: CustomField,
        onCommit: @escaping (UInt8) -> Void
    ) -> some View {
        LabeledContent("Custom character") {
            TextField("", text: text)
                .frame(width: 90)
                .multilineTextAlignment(.center)
                .focused($customFocus, equals: field)
                .onChange(of: text.wrappedValue) { _, value in
                    if let last = value.unicodeScalars.last, last.isASCII {
                        text.wrappedValue = String(last)
                    } else {
                        text.wrappedValue = ""
                    }
                }
                .onSubmit {
                    if let scalar = text.wrappedValue.unicodeScalars.first, scalar.isASCII {
                        onCommit(UInt8(scalar.value))
                    }
                }
        }
    }

    /// The report's resolved encoding (ARCH req. 11's "detected: …" subtitle),
    /// surfaced whether Automatic is active or a forced choice is confirmed.
    private var detectedEncoding: TextEncoding { EncodingPicker.detected(in: model.dialect) }

    /// The Settings picker's selection as an index into `EncodingPicker.options`
    /// (that pinned order is exactly what the `ForEach` above renders). Reading
    /// re-derives the selected option from the live report every time (so a
    /// re-open from elsewhere stays in sync); writing composes + re-opens
    /// through the SAME path as every other dialect control (ARCH req. 12).
    private var encodingIndexBinding: Binding<Int> {
        Binding(
            get: { EncodingPicker.options.firstIndex(of: EncodingPicker.selection(for: model.dialect)) ?? 0 },
            set: { index in
                guard EncodingPicker.options.indices.contains(index) else { return }
                model.applyDialectChange(.encoding(EncodingPicker.options[index]))
            }
        )
    }

    /// Standard separator candidates, plus the current effective value when it
    /// is a custom byte (so the Picker always shows the effective separator).
    private var separatorOptions: [UInt8] {
        var options = DialectCandidates.separators
        if !options.contains(model.dialect.separator) { options.append(model.dialect.separator) }
        return options
    }

    private var customQuote: UInt8? {
        guard let q = model.dialect.quote, !DialectCandidates.quotes.contains(q) else { return nil }
        return q
    }

    // MARK: Column visibility

    private func visibilityBinding(_ column: Int) -> Binding<Bool> {
        Binding(
            get: { !model.visibility.isHidden(column) },
            set: { _ in model.toggleColumn(column) }
        )
    }

    /// The last visible column's checkbox is disabled — it is checked (visible)
    /// but cannot be hidden.
    private func isLastVisible(_ column: Int) -> Bool {
        !model.visibility.isHidden(column) && !model.canHide(column)
    }
}
