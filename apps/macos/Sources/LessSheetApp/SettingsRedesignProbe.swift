import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

/// Opt-in end-to-end hooks for the Settings probes, inert unless one of the
/// pinned `LESSSHEET_SETTINGS_*` variables is present.
@MainActor
enum SettingsRedesignProbe {
    private static let env = ProcessInfo.processInfo.environment
    private static var started = false

    static var active: Bool {
        env["LESSSHEET_SETTINGS_COMPOSE"] != nil
            || env["LESSSHEET_SETTINGS_DISCOVERY"] != nil
            || env["LESSSHEET_SETTINGS_HEADER_LINK"] != nil
            || env["LESSSHEET_SETTINGS_RESET"] != nil
    }

    static func run(model: DocumentModel) {
        guard !started else { return }
        started = true

        if env["LESSSHEET_SETTINGS_COMPOSE"] != nil {
            runCompose(model: model)
        } else if env["LESSSHEET_SETTINGS_DISCOVERY"] != nil {
            runDiscovery(model: model)
        } else if let raw = env["LESSSHEET_SETTINGS_HEADER_LINK"], let requested = Int(raw) {
            runHeaderLink(model: model, requested: requested)
        } else if let secondPath = env["LESSSHEET_SETTINGS_RESET"] {
            runReset(model: model, secondPath: secondPath)
        }
    }

    private static func runCompose(model: DocumentModel) {
        AppDelegate.shared?.presentSettings()
        Task { @MainActor in
            guard let observed = await settledSnapshot(model: model) else { return }
            log("lesssheet.settings.compose "
                + "configure_columns_command=\(observed.configureColumnsCommand) "
                + "column_sheet=\(observed.columnSheet) "
                + "parsing_above=\(observed.parsingAbove) "
                + "list_present=\(observed.listPresent) "
                + "inspector_present=\(observed.inspectorPresent)")
            finish()
        }
    }

    private static func runDiscovery(model: DocumentModel) {
        let began = Date()
        AppDelegate.shared?.presentSettings()
        Task { @MainActor in
            guard let observed = await settledSnapshot(model: model) else { return }
            let milliseconds = max(0, Int(Date().timeIntervalSince(began) * 1_000))
            log("lesssheet.settings.discovery "
                + "total_columns=\(model.columnCount) "
                + "search_field=\(observed.searchField) "
                + "unfiltered_rows=\(observed.discoveryRows) "
                + "settings_request_ids=\(observed.requestIDs) "
                + "open_ms=\(milliseconds)")
            finish()
        }
    }

    private static func runHeaderLink(model: DocumentModel, requested: Int) {
        Task { @MainActor in
            await settleLayout()
            let droveHeader = NativeGridController.live?
                .configureColumnFromHeaderForProbe(requested - 1) ?? false
            guard let observed = await settledSnapshot(model: model) else { return }
            let selected = model.settingsLifecycle.selection ?? -1
            log("lesssheet.settings.header_link "
                + "requested_col_1based=\(requested) "
                + "selected_col_0based=\(selected) "
                + "raised=\(droveHeader && observed.raised)")
            finish()
        }
    }

    private static func runReset(model: DocumentModel, secondPath: String) {
        AppDelegate.shared?.presentSettings()
        model.selectSettingsColumn(model.columnCount > 1 ? 1 : 0)
        model.setSettingsQuery("probe")
        Task { @MainActor in
            await model.open(path: secondPath)
            let selected = model.settingsLifecycle.selection ?? -1
            log("lesssheet.settings.reset "
                + "selected_col_0based=\(selected) "
                + "query_empty=\(model.settingsLifecycle.query.isEmpty)")
            finish()
        }
    }

    private static func settledSnapshot(model: DocumentModel) async -> SettingsProbeSnapshot? {
        await settleLayout()
        return AppDelegate.shared?.settingsProbeSnapshot(model: model)
    }

    private static func settleLayout() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }

    private static func finish() {
        guard env["LESSSHEET_DUMP_EXIT"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
