import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — column visibility (hidden-column reflow), the Settings panel
// lifecycle + inspector edits (override / null-sentinel / format / width), and
// the targeted column-configuration redraw log. Pure code motion.

extension DocumentModel {
    // MARK: - Column visibility (pure model; grid reflows)

    /// The ascending indices of the non-hidden columns, in render order —
    /// `visibilityManager.visibleColumns(visibility)`, memoized (see
    /// `cachedVisibleColumns`). Semantics UNCHANGED (find/filter column
    /// scoping keeps reading exactly this); only the cost of a read changed.
    var visibleColumns: [Int] { cachedVisibleColumns }

    func canHide(_ column: Int) -> Bool { visibilityManager.canHide(visibility, column: column) }

    func toggleColumn(_ column: Int) {
        setVisibility(visibilityManager.toggling(visibility, column: column))
        var settings = columnUserSettings[column] ?? .default
        settings.hidden = visibility.isHidden(column)
        storeColumnSettings(settings, column: column)
        // See the matching poke + comment in `refreshAfterColumnConfiguration`:
        // a visibility edit from the Settings window hits the same unreliable
        // cross-window SwiftUI bridge.
        NativeGridController.live?.apply()
    }

    func showAllColumns() {
        setVisibility(visibilityManager.allVisible(columnCount: columnCount))
        for column in Array(columnUserSettings.keys) {
            var settings = columnUserSettings[column] ?? .default
            settings.hidden = false
            storeColumnSettings(settings, column: column)
        }
        columnPresentationRevision += 1
        NativeGridController.live?.apply()
    }

    func beginSettings(selecting target: Int? = nil) {
        let reducer = SettingsLifecycleReducer()
        if !settingsOpen {
            settingsLifecycle = reducer.opened(
                columnCount: columnCount, restoring: settingsLifecycle.selection
            )
            settingsDiscoveryRows = []
        }
        settingsOpen = true
        if let target {
            let targetInCurrentRows = ColumnDiscovery().mode(columnCount: columnCount) == .fullList
                || settingsDiscoveryRows.contains(target)
            settingsLifecycle = reducer.headerAction(
                settingsLifecycle, target: target, columnCount: columnCount,
                targetInCurrentRows: targetInCurrentRows
            )
        }
        setPanelSelection(settingsLifecycle.selection)
    }

    func endSettings() {
        guard settingsOpen else { return }
        settingsLifecycle = SettingsLifecycleReducer().closed(settingsLifecycle)
        settingsDiscoveryRows = []
        settingsOpen = false
        closeColumnPanel()
    }

    func setSettingsQuery(_ query: String) {
        guard settingsLifecycle.query != query else { return }
        settingsLifecycle.query = query
        settingsDiscoveryRows = []
    }

    func selectSettingsColumn(_ column: Int?) {
        settingsLifecycle = SettingsLifecycleReducer().columnSelected(
            settingsLifecycle, column: column
        )
        setPanelSelection(column)
    }

    func setSettingsDisclosure(_ disclosure: SettingsDisclosure, expanded: Bool) {
        settingsLifecycle = SettingsLifecycleReducer().disclosureSet(
            settingsLifecycle, disclosure, expanded: expanded
        )
    }

    func setSettingsDiscoveryRows(_ rows: [Int]) {
        settingsDiscoveryRows = Array(rows.prefix(columnDiscoveryResultMax))
    }

    var settingsRequestIDCount: Int {
        var ids = Set(panelInferenceIDs)
        if let panelSelectedColumn { ids.insert(panelSelectedColumn) }
        return ids.count
    }

    var settingsDiscoveryRowCount: Int { settingsDiscoveryRows.count }

    func columnPanelCore() -> CoreDocumentSession? { session as? CoreDocumentSession }

    func userSettings(for column: Int) -> ColumnUserSettings {
        columnUserSettings[column] ?? .default
    }

    func panelLabel(for column: Int) -> PanelColumnLabel {
        panelLabels[column] ?? PanelColumnLabel(text: columnLabel(column),
                                                truncated: windowTruncatedLabels.contains(column))
    }

    func metadata(for column: Int) -> ColumnMetadata? {
        panelMetadata[column] ?? windowColumnMetadata[column]
    }

    func panelColumnHasFormatUnavailable(_ column: Int) -> Bool {
        let columns = windowColumns()
        guard let offset = columns.firstIndex(of: column) else { return false }
        let start = Int(window.firstRow)
        for row in start..<(start + window.rows.count) {
            let presentations = windowCellPresentations(forRow: row)
            if offset < presentations.count, presentations[offset].formatUnavailable { return true }
        }
        return false
    }

    func columnWidth(_ column: Int) -> Double { Double(effectiveWidth(column)) }

    func setPanelColumnWidth(_ width: Double, column: Int) {
        guard column >= 0, column < columnCount else { return }
        manualColumnWidths[column] = max(width, Double(GridMetrics.minColumnWidth))
        var settings = userSettings(for: column)
        settings.manualWidth = manualColumnWidths[column]
        storeColumnSettings(settings, column: column)
        markLayoutWidthsStale()
        columnWidthRevision += 1
        columnPanelRevision += 1
        // Cross-window poke (same bridge as toggleColumn / showAllColumns /
        // refreshAfterColumnConfiguration): this width edit originates in the
        // separate (key) Settings window, where the @Observable -> updateNSView
        // -> apply() bridge does not reliably re-fire, so the grid would keep its
        // stale width until a click/scroll. apply()'s columnWidthRevision branch
        // handles the reflow; it just needs invoking. Idempotent and O(viewport).
        NativeGridController.live?.apply()
    }

    func autoFitPanelColumn(_ column: Int) {
        guard column >= 0, column < columnCount else { return }
        let fitted = columnSizer.autoFit(
            contentWidths: measuredContentWidths(forColumn: column),
            minWidth: Double(GridMetrics.minColumnWidth), maxWidth: Double(GridMetrics.maxColumnWidth)
        )
        manualColumnWidths = columnSizer.cleared(manual: manualColumnWidths, column: column)
        columnWidths[column] = CGFloat(fitted)
        var settings = userSettings(for: column)
        settings.manualWidth = nil
        storeColumnSettings(settings, column: column)
        markLayoutWidthsStale()
        columnWidthRevision += 1
        columnPanelRevision += 1
        // Cross-window poke (same bridge as toggleColumn / showAllColumns /
        // refreshAfterColumnConfiguration): auto-fit invoked from the separate
        // (key) Settings window would otherwise leave the grid at its stale
        // width until a click/scroll (the @Observable -> updateNSView bridge does
        // not reliably re-fire cross-window). apply()'s columnWidthRevision branch
        // does the reflow. Idempotent and O(viewport).
        NativeGridController.live?.apply()
    }

    func setColumnOverride(_ type: ColumnType?, column: Int) {
        guard let id = UInt32(exactly: column), let core = session as? CoreDocumentSession,
              core.setColumnOverride(type, column: id) else { return }
        var settings = userSettings(for: column)
        settings.overrideType = type
        storeColumnSettings(settings, column: column)
        refreshAfterColumnConfiguration(column, remeasure: true)
    }

    func setColumnNullSentinel(_ sentinel: String?, column: Int) {
        let bytes = sentinel.map { Array($0.utf8) }
        guard bytes?.count ?? 0 <= 256, let id = UInt32(exactly: column),
              let core = session as? CoreDocumentSession,
              core.setColumnNullSentinel(bytes, column: id) else { return }
        var settings = userSettings(for: column)
        settings.nullSentinel = bytes
        storeColumnSettings(settings, column: column)
        refreshAfterColumnConfiguration(column, remeasure: true)
    }

    func setColumnFormat(_ format: ColumnFormatOptions, column: Int) {
        var settings = userSettings(for: column)
        settings.format = format
        storeColumnSettings(settings, column: column)
        refreshAfterColumnConfiguration(column, remeasure: true)
    }

    private func refreshAfterColumnConfiguration(_ column: Int, remeasure: Bool) {
        if let id = UInt32(exactly: column), let core = session as? CoreDocumentSession {
            if let metadata = core.columnMetadata([id]).first {
                if windowColumnMetadata[column] != nil { windowColumnMetadata[column] = metadata }
                if panelMetadata[column] != nil { panelMetadata[column] = metadata }
            }
            requestCoordinatedInference(core)
        }
        if remeasure { remeasureConfiguredColumn(column) }
        requestColumnConfigurationRedraw([column])
        startPolling()
        // The revision bump above is an `@Observable` write meant to reach the
        // grid via GridView.body -> updateNSView -> apply(). That SwiftUI bridge
        // does NOT reliably re-fire when the mutation originates in the separate
        // (key) Settings window: apply() went uncalled after the edit, so
        // already-visible rows kept their stale formatted text until something
        // else (e.g. a scroll that recycles the row) forced a fresh pull. Poke
        // the live controller directly — the same explicit bridge every other
        // cross-window mutation in this app already uses (jump / find / header
        // toggle). apply() is idempotent and O(viewport).
        NativeGridController.live?.apply()
    }

    /// Bounded revision log for targeted logical-column redraws. A consumer
    /// that falls more than 32 batches behind receives `nil` and must perform
    /// a conservative global refresh; the normal direct-edit path carries one
    /// column from the inspector to the grid without an all-window revision.
    func requestColumnConfigurationRedraw(_ columns: Set<Int>) {
        guard !columns.isEmpty else { return }
        columnConfigurationRevision += 1
        columnConfigurationEvents.append(ColumnConfigurationEvent(
            revision: columnConfigurationRevision, columns: columns
        ))
        if columnConfigurationEvents.count > 32 {
            columnConfigurationEvents.removeFirst(columnConfigurationEvents.count - 32)
        }
    }

    func columnConfigurationChanges(after revision: Int) -> (revision: Int, columns: Set<Int>?) {
        guard revision != columnConfigurationRevision else {
            return (columnConfigurationRevision, [])
        }
        guard let first = columnConfigurationEvents.first,
              revision >= first.revision - 1 else {
            return (columnConfigurationRevision, nil)
        }
        var columns = Set<Int>()
        for event in columnConfigurationEvents where event.revision > revision {
            columns.formUnion(event.columns)
        }
        return (columnConfigurationRevision, columns)
    }

    private func remeasureConfiguredColumn(_ column: Int) {
        guard manualColumnWidths[column] == nil, column >= 0, column < columnWidths.count else { return }
        let candidate = measuredContentWidths(forColumn: column).max() ?? Double(columnWidths[column])
        let grown = min(max(CGFloat(candidate), columnWidths[column]), GridMetrics.maxColumnWidth)
        if grown > columnWidths[column] {
            columnWidths[column] = grown
            markLayoutWidthsStale()
            columnWidthRevision += 1
        }
    }

    func storeColumnSettings(_ settings: ColumnUserSettings, column: Int) {
        if settings.isDefault {
            columnUserSettings.removeValue(forKey: column)
        } else {
            columnUserSettings[column] = settings
        }
    }

    /// Assigns `visibility` and its memoized `visibleColumns` in lockstep —
    /// the ONLY place `visibility` is set, so the cache can never drift from
    /// it (ARCH-column-windowing).
    func setVisibility(_ newValue: ColumnVisibility) {
        visibility = newValue
        cachedVisibleColumns = visibilityManager.visibleColumns(newValue)
        markLayoutWidthsStale()   // the render-order widths depend on visibleColumns too
    }

    /// The label for a column (effective header name, else generic A/B/C…),
    /// used by the grid header and the Settings checkboxes.
    func columnLabel(_ column: Int) -> String {
        if let label = windowColumnLabels[column], !label.isEmpty { return label }
        if let headerCells, column < headerCells.count, !headerCells[column].isEmpty {
            return headerCells[column]
        }
        return GenericColumnName.name(at: column)
    }
}
