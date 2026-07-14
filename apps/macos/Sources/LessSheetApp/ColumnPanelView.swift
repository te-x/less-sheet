import AppKit
import Contracts
import LessSheetKit
import SwiftUI

private enum PanelRowSource: Equatable {
    case all(Int)
    case matches([UInt32])

    var count: Int {
        switch self { case .all(let count): count; case .matches(let ids): ids.count }
    }

    func column(at row: Int) -> Int? {
        guard row >= 0, row < count else { return nil }
        switch self {
        case .all: return row
        case .matches(let ids): return Int(ids[row])
        }
    }
}

/// The embedded Columns section of the normal Settings window. The legacy
/// `panel` names below describe the bounded caches/contracts, not another
/// user-visible surface.
struct ColumnSettingsSection: View {
    @Bindable var model: DocumentModel
    @State private var matches: [UInt32] = []
    @State private var overflow = false
    @State private var noSuchColumn = false
    @State private var searching = false

    private var mode: ColumnDiscoveryMode { ColumnDiscovery().mode(columnCount: model.columnCount) }
    private var query: String { model.settingsLifecycle.query }
    private var selection: Int? { model.settingsLifecycle.selection }

    private var source: PanelRowSource {
        switch mode {
        case .empty, .searchOnly: .matches(matches)
        case .fullList: .all(model.columnCount)
        }
    }

    var body: some View {
        let _ = model.columnPresentationRevision
        let _ = model.columnConfigurationRevision
        let _ = model.columnPanelRevision
        VStack(spacing: 0) {
            HStack {
                Text("Columns").font(.headline)
                Spacer()
                Button("Show All") { model.showAllColumns() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HSplitView {
                VStack(spacing: 8) {
                    if mode == .searchOnly {
                        TextField("Search columns or enter #N", text: queryBinding)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search columns by name or exact number")
                            .background(SettingsProbeMarker(name: "search_field"))
                    }
                    if mode == .empty {
                        ContentUnavailableView("No Columns", systemImage: "rectangle.split.3x1")
                    } else {
                        ColumnPanelTable(model: model, source: source, selection: selectionBinding)
                    }
                    if noSuchColumn {
                        Label("No such column", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No such column")
                    } else if overflow {
                        Label("More matches—refine your search", systemImage: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("More matches; refine your search")
                    } else if searching {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Searching column labels")
                    } else if let progress = model.columnInferenceProgress {
                        ProgressView(value: progress)
                            .accessibilityLabel("Guessing column types")
                            .accessibilityValue("\(Int(progress * 100)) percent")
                    }
                }
                .padding(10)
                .frame(minWidth: 130, idealWidth: 150)
                .background(SettingsProbeMarker(name: "discovery"))

                if let selection {
                    ColumnInspector(model: model, column: selection)
                        .id("\(selection):\(model.openGeneration)")
                        .frame(minWidth: 310, idealWidth: 350)
                        .background(SettingsProbeMarker(name: "inspector"))
                } else {
                    ContentUnavailableView("Select a Column", systemImage: "rectangle.split.3x1")
                        .frame(minWidth: 310)
                        .background(SettingsProbeMarker(name: "inspector"))
                }
            }
        }
        .frame(minWidth: 460, minHeight: 330)
        .task(id: "\(model.openGeneration):\(model.settingsOpen):\(query)") { await search() }
    }

    private var queryBinding: Binding<String> {
        Binding(get: { model.settingsLifecycle.query }, set: { model.setSettingsQuery($0) })
    }

    private var selectionBinding: Binding<Int?> {
        Binding(get: { model.settingsLifecycle.selection }, set: { model.selectSettingsColumn($0) })
    }

    /// Each fixed-size batch is copied and matched off-main. Between batches
    /// only the first ten IDs plus one overflow bit survive.
    private func search() async {
        matches = []
        overflow = false
        noSuchColumn = false
        model.setSettingsDiscoveryRows(mode == .fullList ? Array(0..<model.columnCount) : [])
        guard model.settingsOpen, mode == .searchOnly, !query.isEmpty else {
            searching = false
            return
        }

        switch ColumnDiscovery().resolveDirectAddress(query, columnCount: model.columnCount) {
        case .some(.column(let column)):
            matches = [UInt32(column)]
            model.setSettingsDiscoveryRows([column])
            model.selectSettingsColumn(column)
            searching = false
            return
        case .some(.noSuchColumn):
            noSuchColumn = true
            searching = false
            return
        case .none:
            break
        }

        guard let core = model.columnPanelCore() else { searching = false; return }
        searching = true
        let needle = query
        let count = model.columnCount
        let locale = model.sessionLocale
        let searcher = ColumnLabelSearch()
        let discovery = ColumnDiscovery()
        var accumulation = ColumnMatchAccumulation.empty
        var start = 0
        while start < count, !Task.isCancelled,
              model.settingsOpen, model.settingsLifecycle.query == needle,
              !accumulation.stop {
            let end = min(count, start + searcher.batchSize)
            let ids = (start..<end).map { UInt32($0) }
            let batch = await Task.detached(priority: .userInitiated) {
                let values = core.columnLabels(ids)
                let candidates = zip(ids, values).map { id, value in
                    ColumnLabelCandidate(column: id,
                                         label: value.map { String(decoding: $0.bytes, as: UTF8.self) })
                }
                return searcher.matches(query: needle, in: candidates, locale: locale)
            }.value
            guard !Task.isCancelled, model.settingsOpen,
                  model.settingsLifecycle.query == needle else { return }
            accumulation = discovery.accumulate(accumulation, matches: batch)
            matches = accumulation.retained
            overflow = accumulation.overflow
            model.setSettingsDiscoveryRows(matches.map(Int.init))
            start = end
            await Task.yield()
        }
        if model.settingsLifecycle.query == needle { searching = false }
    }
}

/// Native reusable-row list. NSTableView asks for views only for live rows;
/// `visibleRowsChanged` feeds the pure `ColumnPanelLayout` plan into the model,
/// so label/metadata/inference requests are viewport+overscan bounded too.
private struct ColumnPanelTable: NSViewRepresentable {
    let model: DocumentModel
    let source: PanelRowSource
    @Binding var selection: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("column"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.visibleRowsChanged() }
        }
        DispatchQueue.main.async { context.coordinator.visibleRowsChanged() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let sourceChanged = context.coordinator.parent.source != source
        context.coordinator.parent = self
        if sourceChanged { context.coordinator.table?.reloadData() }
        context.coordinator.reloadVisibleRows()
        context.coordinator.selectColumn(selection)
        DispatchQueue.main.async { context.coordinator.visibleRowsChanged() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observer = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ColumnPanelTable
        weak var table: NSTableView?
        var observer: NSObjectProtocol?

        init(parent: ColumnPanelTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.source.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = parent.source.column(at: row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("ColumnPanelRow")
            let view = (tableView.makeView(withIdentifier: id, owner: self) as? ColumnPanelCellView)
                ?? ColumnPanelCellView(identifier: id)
            configure(view, column: column)
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, let column = parent.source.column(at: table.selectedRow) else {
                parent.selection = nil
                return
            }
            parent.selection = column
        }

        func visibleRowsChanged() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            let plan = ColumnPanelLayout().plan(for: ColumnPanelViewport(
                totalColumns: parent.source.count,
                firstVisibleRow: max(visible.location, 0),
                visibleRowCount: max(visible.length, 1)
            ))
            let ids = plan.instantiatedRows.compactMap { row in
                parent.source.column(at: row).flatMap(UInt32.init(exactly:))
            }
            parent.model.updatePanelViewport(ids)
        }

        func reloadVisibleRows() {
            table?.enumerateAvailableRowViews { [weak self] rowView, row in
                guard let self, let view = rowView.view(atColumn: 0) as? ColumnPanelCellView,
                      let column = parent.source.column(at: row) else { return }
                configure(view, column: column)
            }
        }

        func selectColumn(_ column: Int?) {
            guard let table, let column else { return }
            let row: Int?
            switch parent.source {
            case .all(let count): row = column < count ? column : nil
            case .matches(let ids): row = ids.firstIndex(of: UInt32(column))
            }
            guard let row, table.selectedRow != row else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }

        private func configure(_ view: ColumnPanelCellView, column: Int) {
            let model = parent.model
            let label = model.panelLabel(for: column)
            let metadata = model.metadata(for: column)
            view.column = column
            view.checkbox.state = model.visibility.isHidden(column) ? .off : .on
            view.checkbox.isEnabled = model.visibility.isHidden(column) || model.canHide(column)
            view.checkbox.target = self
            view.checkbox.action = #selector(toggleVisibility(_:))
            view.title.stringValue = label.text
            if let metadata {
                let source = metadata.effectiveSource == .override ? "Override" : "Auto · guessed"
                view.subtitle.stringValue = "\(source) · \(metadata.effective.kind.panelName)"
            } else {
                view.subtitle.stringValue = "Loading…"
            }
            var states = [String]()
            if label.truncated { states.append("Label truncated") }
            if metadata?.conflictState != ColumnConflictState.none { states.append("Type conflict") }
            if model.panelColumnHasFormatUnavailable(column) { states.append("Format unavailable") }
            view.status.image = states.isEmpty ? nil : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: states.joined(separator: ", "))
            view.setAccessibilityLabel("Column \(column + 1), \(label.text), \(view.subtitle.stringValue)"
                + (states.isEmpty ? "" : ", \(states.joined(separator: ", "))"))
        }

        @objc private func toggleVisibility(_ sender: NSButton) {
            guard let cell = sender.superview as? ColumnPanelCellView else { return }
            parent.model.toggleColumn(cell.column)
            reloadVisibleRows()
        }
    }
}

private final class ColumnPanelCellView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let status = NSImageView()
    var column = 0

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingTail
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.contentTintColor = .systemOrange
        for view in [checkbox, title, subtitle, status] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 8, y: 11, width: 20, height: 20)
        status.frame = NSRect(x: bounds.width - 26, y: 13, width: 16, height: 16)
        let textWidth = max(0, bounds.width - 66)
        title.frame = NSRect(x: 34, y: 21, width: textWidth, height: 17)
        subtitle.frame = NSRect(x: 34, y: 4, width: textWidth, height: 15)
    }
}

private struct ColumnInspector: View {
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
                    Slider(value: widthBinding, in: Double(GridMetrics.minColumnWidth)...Double(GridMetrics.maxColumnWidth)) {
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
            nullText = setting.nullSentinel.map { String(decoding: $0, as: UTF8.self) } ?? ""
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
                        Stepper("Fraction digits: \(settings.format.fractionDigits ?? 0)", value: fractionBinding, in: 0...38)
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
                model.setColumnOverride(ColumnType(kind: kind,
                    datetimeSemantics: kind == .datetime ? (existing == .zoned ? .zoned : .naive) : .none), column: column)
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
            case .original: 0; case .localizedShort: 1; case .localizedMedium: 2; case .localizedLong: 3
            }
        }, set: { value in
            var format = model.userSettings(for: column).format
            format.datePreset = [.original, .localizedShort, .localizedMedium, .localizedLong][min(max(value, 0), 3)]
            model.setColumnFormat(format, column: column)
        })
    }
}

extension ColumnKind {
    var panelName: String {
        switch self {
        case .unknown: "Unknown"; case .unsupported: "Unsupported"; case .text: "Text"
        case .boolean: "Boolean"; case .integer: "Integer"; case .decimal: "Decimal"
        case .date: "Date"; case .datetime: "Date & Time"
        }
    }
}
