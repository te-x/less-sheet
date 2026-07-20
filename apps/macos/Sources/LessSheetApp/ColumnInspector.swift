import AppKit
import Contracts
import LessSheetKit
import SwiftUI

struct ColumnInspector: View {
    @Bindable var model: DocumentModel
    let column: Int
    @State private var nullEnabled = false
    @State private var nullText = ""

    private var metadata: ColumnMetadata? { model.metadata(for: column) }

    var body: some View {
        Form {
            Section("Column") {
                Toggle("Visible", isOn: Binding(
                    get: { !model.visibility.isHidden(column) },
                    set: { _ in model.toggleColumn(column) }
                ))
                .disabled(!model.visibility.isHidden(column) && !model.canHide(column))
            }

            Section("Type") {
                Picker("Type", selection: typeSelection) {
                    Text("Auto").tag(0)
                    ForEach([ColumnKind.text, .boolean, .integer, .decimal, .date, .datetime], id: \.rawValue) {
                        Text($0.panelName).tag($0.rawValue + 1)
                    }
                }
                if effectiveKind == .datetime {
                    Picker("Datetime values", selection: datetimeSemantics) {
                        Text("Naive wall time").tag(ColumnDatetimeSemantics.naive.rawValue)
                        Text("Offset required").tag(ColumnDatetimeSemantics.zoned.rawValue)
                    }
                }
                if model.userSettings(for: column).overrideType != nil {
                    Button("Reset to Auto") { model.setColumnOverride(nil, column: column) }
                }
                if let metadata, metadata.effectiveSource == .inferred {
                    LabeledContent("Guessed", value: metadata.effective.kind.panelName)
                }
            }

            if metadata?.conflictState != ColumnConflictState.none
                || model.panelColumnHasFormatUnavailable(column) {
                Section("Status") {
                    if metadata?.conflictState != ColumnConflictState.none {
                        Label("Some values conflict with this type", systemImage: "exclamationmark.triangle")
                            .accessibilityLabel("Type conflict in this column")
                    }
                    if model.panelColumnHasFormatUnavailable(column) {
                        Label("Some exact values are shown raw because formatting is unavailable",
                              systemImage: "number.circle")
                            .accessibilityLabel("Format unavailable; affected exact values are shown raw")
                    }
                }
            }

            formatControls

            Section("Advanced") {
                DisclosureGroup("Null values", isExpanded: nullDisclosureBinding) {
                    Toggle("Use sentinel", isOn: Binding(
                        get: { nullEnabled },
                        set: { enabled in
                            nullEnabled = enabled
                            model.setColumnNullSentinel(enabled ? nullText : nil, column: column)
                        }
                    ))
                    if nullEnabled {
                        TextField("Exact value", text: $nullText)
                            .onSubmit { model.setColumnNullSentinel(nullText, column: column) }
                    }
                }

                DisclosureGroup("Width and Auto-fit", isExpanded: widthDisclosureBinding) {
                    Slider(
                        value: widthBinding,
                        in: Double(GridMetrics.minColumnWidth)...Double(GridMetrics.maxColumnWidth)
                    ) {
                        Text("Column width")
                    }
                    LabeledContent("Width", value: "\(Int(model.columnWidth(column))) pt")
                    Button("Auto-fit Width") { model.autoFitPanelColumn(column) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(column):\(model.openGeneration)") {
            let setting = model.userSettings(for: column)
            nullEnabled = setting.nullSentinel != nil
            nullText = setting.nullSentinel.map { String(lossyUTF8: $0) } ?? ""
            model.setPanelSelection(column)
        }
    }

    private var effectiveKind: ColumnKind {
        model.userSettings(for: column).overrideType?.kind ?? metadata?.effective.kind ?? .unknown
    }

    @ViewBuilder
    private var formatControls: some View {
        let settings = model.userSettings(for: column)
        if effectiveKind == .integer || effectiveKind == .decimal {
            Section("Number format") {
                Toggle("Thousands grouping", isOn: formatBinding(\.grouping))
                if effectiveKind == .decimal {
                    Toggle("Fixed fraction digits", isOn: Binding(
                        get: { model.userSettings(for: column).format.fractionDigits != nil },
                        set: { enabled in
                            var value = model.userSettings(for: column).format
                            value.fractionDigits = enabled ? (value.fractionDigits ?? 2) : nil
                            model.setColumnFormat(value, column: column)
                        }
                    ))
                    if settings.format.fractionDigits != nil {
                        Stepper(
                            "Fraction digits: \(settings.format.fractionDigits ?? 0)",
                            value: fractionBinding, in: 0...38)
                    }
                }
            }
        } else if effectiveKind == .date || effectiveKind == .datetime {
            Section("Date format") {
                Picker("Preset", selection: datePresetBinding) {
                    Text("Original").tag(0)
                    Text("Localized Short").tag(1)
                    Text("Localized Medium").tag(2)
                    Text("Localized Long").tag(3)
                }
            }
        }
    }

    private var typeSelection: Binding<Int> {
        Binding(
            get: { model.userSettings(for: column).overrideType.map { $0.kind.rawValue + 1 } ?? 0 },
            set: { value in
                if value == 0 { model.setColumnOverride(nil, column: column); return }
                guard let kind = ColumnKind(rawValue: value - 1) else { return }
                let existing = model.userSettings(for: column).overrideType?.datetimeSemantics
                model.setColumnOverride(
                    ColumnType(
                        kind: kind,
                        datetimeSemantics: kind == .datetime
                            ? (existing == .zoned ? .zoned : .naive) : .none),
                    column: column)
            }
        )
    }

    private var datetimeSemantics: Binding<Int> {
        Binding(
            get: { model.userSettings(for: column).overrideType?.datetimeSemantics.rawValue
                ?? metadata?.effective.datetimeSemantics.rawValue ?? ColumnDatetimeSemantics.naive.rawValue },
            set: { raw in
                let semantics = ColumnDatetimeSemantics(rawValue: raw) ?? .naive
                model.setColumnOverride(ColumnType(kind: .datetime, datetimeSemantics: semantics), column: column)
            }
        )
    }

    private var widthBinding: Binding<Double> {
        Binding(get: { model.columnWidth(column) },
                set: { model.setPanelColumnWidth($0, column: column) })
    }

    private var nullDisclosureBinding: Binding<Bool> {
        Binding(
            get: { model.settingsLifecycle.nullValuesExpanded },
            set: { model.setSettingsDisclosure(.nullValues, expanded: $0) }
        )
    }

    private var widthDisclosureBinding: Binding<Bool> {
        Binding(
            get: { model.settingsLifecycle.widthAutoFitExpanded },
            set: { model.setSettingsDisclosure(.widthAutoFit, expanded: $0) }
        )
    }

    private func formatBinding(_ keyPath: WritableKeyPath<ColumnFormatOptions, Bool>) -> Binding<Bool> {
        Binding(get: { model.userSettings(for: column).format[keyPath: keyPath] }, set: { newValue in
            var format = model.userSettings(for: column).format
            format[keyPath: keyPath] = newValue
            model.setColumnFormat(format, column: column)
        })
    }

    private var fractionBinding: Binding<Int> {
        Binding(get: { model.userSettings(for: column).format.fractionDigits ?? 0 }, set: { value in
            var format = model.userSettings(for: column).format
            format.fractionDigits = value
            model.setColumnFormat(format, column: column)
        })
    }

    private var datePresetBinding: Binding<Int> {
        Binding(get: {
            switch model.userSettings(for: column).format.datePreset {
            case .original: 0
            case .localizedShort: 1
            case .localizedMedium: 2
            case .localizedLong: 3
            }
        }, set: { value in
            var format = model.userSettings(for: column).format
            format.datePreset = [.original, .localizedShort, .localizedMedium, .localizedLong][min(max(value, 0), 3)]
            model.setColumnFormat(format, column: column)
        })
    }
}
