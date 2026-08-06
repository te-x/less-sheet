import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

// The app delegate, Settings-window plumbing, and the headless Settings-redesign
// verification probe, split out of AppUI.swift to keep each file within the length
// budget. Pure code motion — no behavior change.

// MARK: - App delegate (deterministic single window + open routing + Settings)

struct SettingsProbeSnapshot {
    let configureColumnsCommand: Bool
    let columnSheet: Bool
    let parsingAbove: Bool
    let listPresent: Bool
    let inspectorPresent: Bool
    let searchField: Bool
    let discoveryRows: Int
    let requestIDs: Int
    let raised: Bool
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var routedLaunchOpen = false
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTiming.phase("did_finish_launching")
        // PRIMARY CLI path: a document path in argv (direct exec / `open --args`).
        if !routedLaunchOpen, let path = LaunchArguments.documentPath(from: CommandLine.arguments) {
            routedLaunchOpen = true
            route(path)
        }
        LaunchTiming.phase("before_show_window")
        showMainWindow()
        LaunchTiming.phase("after_show_window")
        NSApp.activate(ignoringOtherApps: true)
        LaunchTiming.phase("after_activate")

        // No document on launch: rest on the launch state (LaunchStateView),
        // which spells out both entry points (⌘O local file, ⌘⇧O Open URL).
        // Auto-popping the open panel predated network support and now wrongly
        // assumes "open" means a local file — the user picks the entry point.
    }

    // `open -a LessSheet file.csv`, Finder double-click, drag-onto-icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        routedLaunchOpen = true
        for url in urls { route(url.path(percentEncoded: false)) }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        routedLaunchOpen = true
        for filename in filenames { route(filename) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(); mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func route(_ path: String) {
        LaunchTiming.phase("route_enqueued")
        Task {
            LaunchTiming.phase("open_begin")
            await DocumentModel.shared.open(path: path, forcing: launchForcedOverride())
            LaunchTiming.phase("open_done")
        }
    }

    /// Creates the single chromeless main window (idempotent) hosting the
    /// SwiftUI content. The title bar is transparent and the title hidden, so
    /// the grid fills the whole frame; the window still carries the document
    /// title for Mission Control / the Window menu / the Dock (ARCH req 1).
    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LessSheet"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 360)
        // Native chromeless content (as the first viewer-ui build had it): the
        // transparent full-size-content title bar lets grid content scroll UNDER
        // it, and macOS 26's ScrollView scroll-edge effect frosts that content
        // through the title-bar region — the look the author liked. NO custom
        // opaque strip (that was the regression). The grid insets its top by the
        // title-bar height (see GridView) so at rest row 1 sits fully below the
        // title-bar region while scrolled content still travels under it.
        LaunchTiming.phase("before_hosting_view")
        window.contentView = NSHostingView(rootView: ContentView(model: .shared))
        LaunchTiming.phase("after_hosting_view")
        window.setFrameAutosaveName("LessSheetMain")
        if !window.setFrameUsingName("LessSheetMain") {
            window.center()
        }
        // Screenshot-capture affordance: deterministic size/appearance when the
        // LESSSHEET_CAPTURE_* env vars are set; inert otherwise (CaptureProbe).
        CaptureProbe.configure(window: window)
        // Traffic lights always visible (no fade).
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
        LaunchTiming.phase("before_order_front")
        window.makeKeyAndOrderFront(nil)
        LaunchTiming.phase("after_order_front")
        mainWindow = window
    }

    /// File › Open… — the shared open-panel entry.
    static func openViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await DocumentModel.shared.open(
                    path: url.path(percentEncoded: false), forcing: launchForcedOverride())
            }
        }
    }

    /// File › Open URL… (⌘⇧O) — a small sheet with a URL field, funneling into
    /// `DocumentModel.openURL` (ARCH-network-source req 9). ⌘O's local panel is
    /// unaffected. The URL is opened as typed; no recents entry.
    static func openURLViaSheet() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Enter the http:// or https:// address of a CSV or .csv.gz file."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com/data.csv"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            Task { await DocumentModel.shared.openURL(url, forcing: launchForcedOverride()) }
        }
    }

    /// Raises the sole normal Settings surface, optionally deep-linked from a
    /// grid header to one logical column.
    func presentSettings(selecting column: Int? = nil) {
        DocumentModel.shared.beginSettings(selecting: column)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 500, height: 620)
        window.contentView = NSHostingView(rootView: SettingsView(model: .shared))
        window.center()
        window.delegate = SettingsWindowObserver.shared
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    /// Reads acceptance facts from the live Settings/AppKit hierarchy and the
    /// discovery model state that hierarchy renders. Missing markers are false,
    /// so a composition regression cannot be hidden by the probe.
    func settingsProbeSnapshot(model: DocumentModel) -> SettingsProbeSnapshot {
        settingsWindow?.contentView?.layoutSubtreeIfNeeded()
        settingsWindow?.contentView?.displayIfNeeded()
        guard let root = settingsWindow?.contentView else {
            return SettingsProbeSnapshot(
                configureColumnsCommand: containsConfigureColumnsMenuItem(NSApp.mainMenu),
                columnSheet: mainWindow?.attachedSheet != nil,
                parsingAbove: false, listPresent: false, inspectorPresent: false,
                searchField: false, discoveryRows: model.settingsDiscoveryRowCount,
                requestIDs: model.settingsRequestIDCount, raised: false
            )
        }

        let views = descendantViews(root)
        let parsing = marker("parsing", in: views)
        let discovery = marker("discovery", in: views)
        let inspector = marker("inspector", in: views)
        let parsingAbove: Bool
        if let parsing, let discovery, let inspector {
            let parsingY = parsing.convert(parsing.bounds, to: root).midY
            let lowerY = [discovery, inspector].map { $0.convert($0.bounds, to: root).midY }
            parsingAbove = root.isFlipped ? lowerY.allSatisfy { parsingY < $0 }
                : lowerY.allSatisfy { parsingY > $0 }
        } else {
            parsingAbove = false
        }

        let configureButton = views.compactMap { $0 as? NSButton }
            .contains { $0.title.hasPrefix("Configure Columns") }
        let configureAccessibility = containsConfigureColumnsAccessibility(root)
        return SettingsProbeSnapshot(
            configureColumnsCommand: configureButton || configureAccessibility
                || containsConfigureColumnsMenuItem(NSApp.mainMenu),
            columnSheet: mainWindow?.attachedSheet != nil,
            parsingAbove: parsingAbove,
            listPresent: discovery != nil,
            inspectorPresent: inspector != nil,
            searchField: marker("search_field", in: views) != nil,
            discoveryRows: model.settingsDiscoveryRowCount,
            requestIDs: model.settingsRequestIDCount,
            raised: settingsWindow?.isVisible == true
        )
    }

    private func descendantViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendantViews)
    }

    private func marker(_ name: String, in views: [NSView]) -> NSView? {
        let identifier = "lesssheet.settings.\(name)"
        return views.first { $0.identifier?.rawValue == identifier }
    }

    private func containsConfigureColumnsMenuItem(_ menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        return menu.items.contains { item in
            item.title.hasPrefix("Configure Columns") || containsConfigureColumnsMenuItem(item.submenu)
        }
    }

    private func containsConfigureColumnsAccessibility(_ element: Any, depth: Int = 0) -> Bool {
        guard depth < 32 else { return false }
        let label: String?
        let title: String?
        let children: [Any]
        if let view = element as? NSView {
            label = view.accessibilityLabel()
            title = view.accessibilityTitle()
            children = view.accessibilityChildren() ?? []
        } else if let accessibilityElement = element as? NSAccessibilityElement {
            label = accessibilityElement.accessibilityLabel()
            title = accessibilityElement.accessibilityTitle()
            children = accessibilityElement.accessibilityChildren() ?? []
        } else {
            return false
        }
        if label?.hasPrefix("Configure Columns") == true
            || title?.hasPrefix("Configure Columns") == true { return true }
        return children.contains { containsConfigureColumnsAccessibility($0, depth: depth + 1) }
    }

    /// Verification-only fallback for off-screen launches where SwiftUI may not
    /// schedule the content `.task`: force the opened document view through its
    /// first display pass before driving a Settings probe.
    func runSettingsProbeAfterFirstPaint(model: DocumentModel) {
        guard SettingsRedesignProbe.active else { return }
        showMainWindow()
        mainWindow?.contentView?.layoutSubtreeIfNeeded()
        mainWindow?.contentView?.displayIfNeeded()
        model.markFirstRowsVisible()
        SettingsRedesignProbe.run(model: model)
    }
}

/// Clears `settingsOpen` when the Settings window closes (so the overlay can
/// resume its idle fade).
@MainActor
final class SettingsWindowObserver: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowObserver()
    func windowWillClose(_ notification: Notification) {
        DocumentModel.shared.endSettings()
    }
}

/// Opt-in end-to-end hooks for the frozen Settings redesign probes. The
/// implementation lives in this existing promoted source file so it cannot be
/// dropped as an untracked standalone file. Production is inert unless a pinned
/// `LESSSHEET_SETTINGS_*` variable is present.
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
