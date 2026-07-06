import Contracts
import SwiftUI

// The Settings window's content (ARCH req. 9): a normal titled window with the
// SAME three parse parameters as the overlay controls — bound to the same
// session state, so a change here re-opens the document exactly as a popup would
// — plus per-column visibility checkboxes (the last visible column's box
// disabled). The parameter terms are identical to the popups' ("First row is
// header", "Separator", "Quote character"). The form leaves obvious room for
// future datatype/formatting sections and ships no dead controls.

struct SettingsView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        Form {
            Section("Parsing") {
                Toggle("First row is header", isOn: headerBinding)

                Picker("Separator", selection: separatorBinding) {
                    ForEach(separatorOptions, id: \.self) { byte in
                        Text(DialectGlyph.separatorName(byte)).tag(byte)
                    }
                }

                Picker("Quote character", selection: quoteBinding) {
                    Text("Double quote  \"").tag(UInt8?.some(0x22))
                    Text("Single quote  '").tag(UInt8?.some(0x27))
                    Text("None").tag(UInt8?.none)
                    if let custom = customQuote {
                        Text(DialectGlyph.quoteName(custom)).tag(UInt8?.some(custom))
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

    private var separatorBinding: Binding<UInt8> {
        Binding(get: { model.dialect.separator },
                set: { model.applyDialectChange(.separator($0)) })
    }

    private var quoteBinding: Binding<UInt8?> {
        Binding(get: { model.dialect.quote },
                set: { model.applyDialectChange(.quote($0)) })
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
