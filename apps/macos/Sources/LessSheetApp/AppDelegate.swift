import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

// The app delegate: the deterministic single window, open routing, and the
// Settings window.

/// What the headless Settings probes read back off the live hierarchy.
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
        LaunchTiming.phase("will_finish_launching")
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTiming.phase("did_finish_launching")
        if !routedLaunchOpen, let path = LaunchArguments.documentPath(from: CommandLine.arguments) {
            routedLaunchOpen = true
            route(path)
        }
        // ⌘⇧O is a MODAL sheet, so the network funnel would otherwise have no
        // scriptable entry and no headless coverage at all. This supplies the URL
        // exactly as the sheet does. argv wins when both are present, so it can
        // never divert a real document.
        if !routedLaunchOpen,
           let url = ProcessInfo.processInfo.environment["LESSSHEET_OPEN_URL"],
           !url.isEmpty {
            routedLaunchOpen = true
            Task { await DocumentModel.shared.openURL(url, forcing: launchForcedOverride()) }
        }
        showMainWindow()
        LaunchTiming.phase("after_show_window")
        NSApp.activate(ignoringOtherApps: true)

        // With no document we rest on the launch state, which spells out both
        // entry points. Auto-popping the file panel would assume "open" means a
        // local file, which stopped being true when URLs landed.
    }

    // `open -a`, Finder double-click, drag onto the icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        LaunchTiming.phase("launch_event")
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
        // The FIRST path routed at launch belongs to the prewarm, whose core open
        // is already running off-main; every later one takes the normal funnel.
        if LaunchOpenPrewarm.handleLaunchRoute(path, forcing: launchForcedOverride()) { return }
        Task { await DocumentModel.shared.open(path: path, forcing: launchForcedOverride()) }
    }

    /// Creates the single chromeless main window, idempotently. The title bar is
    /// transparent and the title hidden, so the grid fills the whole frame; the
    /// window still carries the document title for Mission Control, the Window
    /// menu and the Dock.
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
        // Adopt the prewarmed launch open if it has ALREADY landed, so SwiftUI's
        // first pass renders the grid rather than rendering the launch state and
        // then re-rendering. Never blocks: if the open is still running this does
        // nothing and the prewarm adopts from its own completion.
        LaunchOpenPrewarm.adoptIfReady()
        // The frame FIRST: the window is born at the placeholder size above, and
        // giving it the restored one after the content view is in place makes
        // SwiftUI lay the whole tree out twice.
        window.setFrameAutosaveName("LessSheetMain")
        if !window.setFrameUsingName("LessSheetMain") {
            window.center()
        }
        CaptureProbe.configure(window: window)   // inert without LESSSHEET_CAPTURE_*
        LaunchTiming.phase("before_hosting_view")
        window.contentView = NSHostingView(rootView: ContentView(model: .shared))
        LaunchTiming.phase("after_hosting_view")
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

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

    /// A small sheet with a URL field. The URL is opened as typed, with no
    /// recents entry.
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

    /// Raises the Settings window, optionally deep-linked from a grid header to
    /// one column.
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

    /// Reads facts from the LIVE Settings hierarchy, not from the model alone.
    /// A missing marker reads false, so a composition regression cannot hide
    /// behind the probe.
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

    /// Off-screen, SwiftUI may never schedule the content `.task`, so force the
    /// document view through a first display pass before driving the probe.
    func runSettingsProbeAfterFirstPaint(model: DocumentModel) {
        guard SettingsRedesignProbe.active else { return }
        showMainWindow()
        mainWindow?.contentView?.layoutSubtreeIfNeeded()
        mainWindow?.contentView?.displayIfNeeded()
        model.markFirstRowsVisible()
        SettingsRedesignProbe.run(model: model)
    }
}

/// Clears `settingsOpen` when the Settings window closes.
@MainActor
final class SettingsWindowObserver: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowObserver()
    func windowWillClose(_ notification: Notification) {
        DocumentModel.shared.endSettings()
    }
}
