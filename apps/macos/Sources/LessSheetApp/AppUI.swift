import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

// The viewer-ui app shell. KEEPS the walking-skeleton's hard-won launch
// architecture — a single window created deterministically by the app delegate
// (never a SwiftUI WindowGroup, which routes argv/file launches
// non-deterministically) — and layers on the real chromeless viewer: a
// full-window spreadsheet grid, the floating Liquid Glass overlay, dialect
// controls, a separate Settings window, jump-to-row, and the timing marker +
// frame-dump hooks. All opens (panel, launch, CLI, drag, dialect re-open) funnel
// through DocumentModel.open(path:).

// MARK: - Launch argument parsing

enum LaunchArguments {
    /// Extracts a document path from process arguments, skipping argv[0] and any
    /// `-flag value` pairs AppKit / NSUserDefaults inject at launch. A flag
    /// value is never mistaken for a path. (The frame-dump hook uses an ENV var,
    /// not argv, so it can never be picked up here.)
    static func documentPath(from arguments: [String]) -> String? {
        var previousWasFlag = false
        for arg in arguments.dropFirst() {
            if arg.hasPrefix("-") {
                previousWasFlag = true
                continue
            }
            if previousWasFlag {
                previousWasFlag = false
                continue
            }
            return arg
        }
        return nil
    }
}

/// Verification-only initial dialect forcing from the environment (mirrors the
/// pills' overrides). Lets headless runs set up a "wrong guess" via a forced
/// initial dialect (ARCH criterion 11) without any interaction. Absent env =
/// sniff everything (the normal first open). `LESSSHEET_FORCE_SEP` /
/// `LESSSHEET_FORCE_QUOTE` accept one ASCII char (or "TAB" / "NONE");
/// `LESSSHEET_FORCE_HEADER` accepts "on" / "off".
func launchForcedOverride() -> DialectOverride {
    let env = ProcessInfo.processInfo.environment

    var separator: SeparatorOverride = .sniff
    if let raw = env["LESSSHEET_FORCE_SEP"] {
        if raw.uppercased() == "TAB" {
            separator = .forced(0x09)
        } else if let scalar = raw.unicodeScalars.first, scalar.isASCII {
            separator = .forced(UInt8(scalar.value))
        }
    }

    var quote: QuoteOverride = .sniff
    if let raw = env["LESSSHEET_FORCE_QUOTE"] {
        if raw.uppercased() == "NONE" {
            quote = .none
        } else if let scalar = raw.unicodeScalars.first, scalar.isASCII {
            quote = .forced(UInt8(scalar.value))
        }
    }

    var header: HeaderOverride = .sniff
    switch env["LESSSHEET_FORCE_HEADER"]?.lowercased() {
    case "on": header = .on
    case "off": header = .off
    default: break
    }

    return DialectOverride(separator: separator, quote: quote, header: header)
}

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
        // PRIMARY CLI path: a document path in argv (direct exec / `open --args`).
        if !routedLaunchOpen, let path = LaunchArguments.documentPath(from: CommandLine.arguments) {
            routedLaunchOpen = true
            route(path)
        }
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)

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
        Task { await DocumentModel.shared.open(path: path, forcing: launchForcedOverride()) }
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
        window.contentView = NSHostingView(rootView: ContentView(model: .shared))
        window.setFrameAutosaveName("LessSheetMain")
        if !window.setFrameUsingName("LessSheetMain") {
            window.center()
        }
        // Traffic lights always visible (no fade).
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    /// File › Open… — the shared open-panel entry.
    static func openViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await DocumentModel.shared.open(path: url.path(percentEncoded: false), forcing: launchForcedOverride()) }
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
            AppDelegate.shared?.presentSettings()
            Task { @MainActor in
                guard let observed = await settledSnapshot(model: model) else { return }
                log("lesssheet.settings.compose configure_columns_command=\(observed.configureColumnsCommand) column_sheet=\(observed.columnSheet) parsing_above=\(observed.parsingAbove) list_present=\(observed.listPresent) inspector_present=\(observed.inspectorPresent)")
                finish()
            }
            return
        }

        if env["LESSSHEET_SETTINGS_DISCOVERY"] != nil {
            let began = Date()
            AppDelegate.shared?.presentSettings()
            Task { @MainActor in
                guard let observed = await settledSnapshot(model: model) else { return }
                let milliseconds = max(0, Int(Date().timeIntervalSince(began) * 1_000))
                log("lesssheet.settings.discovery total_columns=\(model.columnCount) search_field=\(observed.searchField) unfiltered_rows=\(observed.discoveryRows) settings_request_ids=\(observed.requestIDs) open_ms=\(milliseconds)")
                finish()
            }
            return
        }

        if let raw = env["LESSSHEET_SETTINGS_HEADER_LINK"], let requested = Int(raw) {
            Task { @MainActor in
                await settleLayout()
                let droveHeader = NativeGridController.live?
                    .configureColumnFromHeaderForProbe(requested - 1) ?? false
                guard let observed = await settledSnapshot(model: model) else { return }
                let selected = model.settingsLifecycle.selection ?? -1
                log("lesssheet.settings.header_link requested_col_1based=\(requested) selected_col_0based=\(selected) raised=\(droveHeader && observed.raised)")
                finish()
            }
            return
        }

        if let secondPath = env["LESSSHEET_SETTINGS_RESET"] {
            AppDelegate.shared?.presentSettings()
            model.selectSettingsColumn(model.columnCount > 1 ? 1 : 0)
            model.setSettingsQuery("probe")
            Task { @MainActor in
                await model.open(path: secondPath)
                let selected = model.settingsLifecycle.selection ?? -1
                log("lesssheet.settings.reset selected_col_0based=\(selected) query_empty=\(model.settingsLifecycle.query.isEmpty)")
                finish()
            }
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

// MARK: - App

struct LessSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No WindowGroup: the main window is delegate-owned. This scene carries
        // only the menu commands. The empty Settings window and the temp shell's
        // duplicate View menu are gone (ARCH req 3).
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
                CommandGroup(replacing: .newItem) {
                    Button("Open…") { AppDelegate.openViaPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                    Button("Open URL…") { AppDelegate.openURLViaSheet() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                }
                CommandMenu("Go") {
                    Button("Jump to Row…") { DocumentModel.shared.requestJumpFocus() }
                        .keyboardShortcut("j", modifiers: .command)
                }
                CommandMenu("Find") {
                    Button("Find…") { DocumentModel.shared.requestFindFocus() }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Find Next") { DocumentModel.shared.stepFind(.forward) }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("Find Previous") { DocumentModel.shared.stepFind(.backward) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
            }
    }
}

// MARK: - Root content

struct ContentView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            // The network-open progress affordance rides ABOVE whatever
            // `content` shows — including the pre-open `.launch` empty state,
            // since a network open can be the very FIRST thing the user does
            // (ARCH req 10 / AC9: visible from t0, no phase/document required).
            if let progress = model.networkOpenProgress {
                NetworkOpenBanner(model: model, progress: progress)
                    .padding(.trailing, 24)
                    // Clear the existing control row when a document is ALREADY
                    // showing (a re-open of a new URL over a live document).
                    .padding(.bottom, model.phase == .document ? 24 + OverlayMetrics.controlSize + 10 : 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.networkOpenProgress)
        .background(WindowConfigurator(title: windowTitle))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launch:
            LaunchStateView()

        case .document:
            if model.columnCount == 0 {
                EmptyStateView(line: "This file is empty.")
                    .task(id: model.openGeneration) {
                        // Empty document: not data-bearing — no timing marker.
                        FrameDump.dumpIfRequested(for: model)
                        FrameDump.terminateIfRequested()
                    }
            } else {
                documentContent
            }

        case let .failure(error, path):
            // A NETWORK open's failure carries its OWN distinct taxonomy
            // (`NetworkOpenError`, 7 cases — round-2 review finding 2: a 404,
            // timeout, DNS failure, redirect-loop, invalid scheme, and spool-IO
            // error must each render distinctly, never collapse into one
            // generic message). `phase` itself stays `DocumentOpenError`-typed
            // (frozen), so the network failure detail rides alongside in
            // `model.networkOpenError` and is rendered here instead when present.
            if model.currentOpenKind == .network, let networkError = model.networkOpenError {
                NetworkErrorPanel(error: networkError, path: path)
                    .task(id: model.openGeneration) {
                        FrameDump.dumpError(error: error, path: path)
                        FrameDump.terminateIfRequested()
                    }
            } else {
                ErrorPanel(error: error, path: path)
                    .task(id: model.openGeneration) {
                        FrameDump.dumpError(error: error, path: path)
                        FrameDump.terminateIfRequested()
                    }
            }
        }
    }

    private var documentContent: some View {
        ZStack(alignment: .bottomTrailing) {
            GridView(model: model)
            // A filter that matched nothing (scan complete): a centered message
            // over the empty grid, mirroring the empty-file EmptyStateView
            // (ARCH criterion 18). The banner also says so, top-leading.
            if model.filterBanner?.isEmptyResult == true {
                EmptyStateView(line: "No rows match the filter.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            OverlayView(model: model)
            // Our own always-visible filename, drawn in the title-bar band
            // (the native title stays hidden to preserve the under-titlebar
            // frost + header alignment). Centered, clear of the traffic
            // lights on both edges; when the title is too long to fit, it
            // truncates at the START (keeps the tail) — for a network doc
            // the tail of a URL (…/actual-file.csv) is the informative part,
            // unlike the default `.tail` mode that would keep the scheme/host
            // and hide exactly the part that matters.
            Text(windowTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Self.titleTrafficLightReserve)
                .frame(height: GridMetrics.titleBarInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        // Extend the grid UNDER the transparent title-bar region so content
        // scrolls beneath it and the scroll-edge effect frosts it (item 2). The
        // grid re-insets its own content by the title-bar height so row 1 rests
        // below the region at rest (item 1) — see GridView.contentMargins.
        .ignoresSafeArea(.container, edges: .top)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase { model.revealOverlay() }
        }
        .task(id: model.openGeneration) {
            // First data-bearing frame: emit the cold-start marker (guarded to
            // once per open), briefly reveal the overlay so the controls are
            // discoverable, then dump the requested frame for verification.
            model.markFirstRowsVisible()
            model.revealOverlay()
            if SettingsRedesignProbe.active {
                SettingsRedesignProbe.run(model: model)
            } else if JumpProbe.active {
                // Verification: drive the real jump path AFTER first paint. The
                // arrival dumps + terminates itself, so skip the first-frame
                // dump/terminate (which would quit before the jump completes).
                JumpProbe.run(model: model)
            } else if LandingStallProbe.active {
                // Verification: drive 5 alternating far find/jump landings and
                // report the worst main-thread gap (the < 100 ms no-stall proof).
                LandingStallProbe.run(model: model)
            } else if FindProbe.active {
                // Verification: drive the real find path AFTER first paint (it
                // dumps + terminates itself once the search resolves).
                FindProbe.run(model: model)
            } else if HeaderToggleProbe.active {
                // Verification: park the viewport, toggle the header, and prove the
                // same file record stays in view (it logs + terminates itself).
                HeaderToggleProbe.run(model: model)
            } else if SelectCopyProbe.active {
                // Verification: drive selection/copy/resize directly against the
                // model (ARCH-select-copy) — logs + terminates itself.
                SelectCopyProbe.run(model: model)
            } else if StreamCopyOutcomeProbe.active {
                // Verification: drive DocumentModel.streamCopy with fake sessions and
                // assert the frontend copy OUTCOMES (byte-budget cut, cell-cap map,
                // filtered-stall clean stop w/o spin — Phase-2 findings 1/2) — logs
                // + terminates itself. Ignores `model` (uses deterministic fakes).
                StreamCopyOutcomeProbe.run()
            } else if ConfigRepaintProbe.active {
                // Verification: drive one real model-side column-config edit and
                // prove the live grid controller applied it with no interaction
                // (config-repaint lock) — logs + terminates itself.
                ConfigRepaintProbe.run(model: model)
            } else if FilterRepaintProbe.active {
                // Verification: drive one real "Filter to matches" toggle and
                // prove the live grid controller applied it with no interaction
                // (filter-repaint lock) — logs + terminates itself.
                FilterRepaintProbe.run(model: model)
            } else if FindEscapeProbe.active {
                // Verification: run a search, then drive the grid's Esc handler
                // and prove the find popup closes + clears (search-escape lock)
                // — logs + terminates itself.
                FindEscapeProbe.run(model: model)
            } else if RepaintAuditProbe.active {
                // Audit: measure the apply-tick delta across each cell-painting
                // mutation to classify instant vs defer-to-scroll — logs +
                // terminates itself.
                RepaintAuditProbe.run(model: model)
            } else if MatchFlagsFetchProbe.active {
                // Verification: count real windowMatchFlags ABI fetches across
                // repaints + a same-geometry content change, proving one fetch
                // per materialize (AC5) and no stale mask (finding 1) — logs +
                // terminates itself.
                MatchFlagsFetchProbe.run(model: model)
            } else if FrameDump.liveGridInitialDumpPath == nil {
                // Overlay / find / settings / overscroll etc. render off a SwiftUI
                // mirror here; the plain grid-content scene instead self-captures
                // the LIVE table from the grid controller (see NativeGrid).
                FrameDump.dumpIfRequested(for: model)
                FrameDump.terminateIfRequested()
            }
        }
    }

    /// Horizontal clearance reserved on each side of the centered title so it
    /// never overlaps the traffic lights (~70pt cluster + margin from the
    /// leading edge); applied symmetrically since the title is centered.
    private static let titleTrafficLightReserve: CGFloat = 78

    private var windowTitle: String {
        if case .document = model.phase, !model.path.isEmpty {
            // A network document shows its URL AS-IS (no filename extraction —
            // ARCH-network-source req 11); a local file shows its basename.
            if model.currentOpenKind == .network { return model.path }
            return (model.path as NSString).lastPathComponent
        }
        return "LessSheet"
    }
}

/// A single quiet line, centered — used for the empty-file state.
struct EmptyStateView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The blank launch screen shown when the app starts with no document (i.e. not
/// via a Finder open / argv). It spells out the two ways to open something —
/// a local file (⌘O) and a network URL (⌘⇧O) — instead of the old behavior of
/// immediately popping the file panel, which predated network support and
/// wrongly assumed "open" meant a local file. Same quiet, centered aesthetic as
/// the empty-file state.
struct LaunchStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Open a spreadsheet to view it")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌘O", "Open a local file")
                shortcut("⌘⇧O", "Open a URL")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .frame(minWidth: 44, alignment: .trailing)
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// In-window error panel: the fact, then the fix path (ARCH: errors = fact +
/// fix). Semantic colors; the path is selectable.
struct ErrorPanel: View {
    let error: DocumentOpenError
    let path: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(fact).font(.headline)
            Text(fix).font(.callout).foregroundStyle(.secondary)
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var fact: String {
        switch error {
        case .notFound: "File not found"
        case .permissionDenied: "Permission denied"
        case .io, .invalidArgument: "Can't read this file"
        }
    }

    private var fix: String {
        switch error {
        case .notFound: "Check the path, then open it again."
        case .permissionDenied: "Grant read access to this file, then open it again."
        case .io, .invalidArgument: "It may be a folder or otherwise unreadable. Try another file."
        }
    }
}

/// The network-open analog of `ErrorPanel` (ARCH-network-source AC7 — round-2
/// review finding 2): renders each of the 7 distinct `NetworkOpenError` cases
/// with its own fact + fix, so a 404, a DNS/connect failure, a timeout, a
/// redirect-loop, a disallowed scheme, and a spool-IO error never read as the
/// same generic message.
struct NetworkErrorPanel: View {
    let error: NetworkOpenError
    let path: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(fact).font(.headline)
            Text(fix).font(.callout).foregroundStyle(.secondary)
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var fact: String {
        switch error {
        case .invalidArgument: "Not an http:// or https:// address"
        case .unreachable: "Couldn't reach that host"
        case .timeout: "The connection timed out"
        case let .httpStatus(code): "Server returned \(code)"
        case .tooManyRedirects: "Too many redirects"
        case .io: "Couldn't create the local download"
        case .cancelled: "Open cancelled"
        }
    }

    private var fix: String {
        switch error {
        case .invalidArgument: "Only http:// and https:// URLs are supported. Check the address and try again."
        case .unreachable: "Check the address and your network connection, then try again."
        case .timeout: "The server didn't respond in time. Try again."
        case let .httpStatus(code) where code == 401 || code == 403: "This URL requires authentication, which isn't supported. Try a public URL."
        case .httpStatus: "The server rejected the request. Check the address and try again."
        case .tooManyRedirects: "The URL redirected too many times. Check the address."
        case .io: "Couldn't create the local spool file. Check available disk space and try again."
        case .cancelled: "The open was cancelled before it finished."
        }
    }
}

// MARK: - Window chrome (reactive)

/// Reveals/hides the traffic lights with the overlay and keeps the window's
/// document title current. Static chrome (transparent title bar, hidden title)
/// is set once by the delegate at window creation.
struct WindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        // Keep the document title current for Mission Control / the Window menu
        // / the Dock (ARCH req 1) — but NEVER toggle `titleVisibility`. Making the
        // title visible flips AppKit into "titled" layout: it insets the content
        // view BELOW the title bar (so grid content no longer scrolls under it —
        // killing the scroll-edge frost) and misaligns the pinned header vs row 1
        // (the 6 pt overlap). be86b2a kept it statically `.hidden`; that is what
        // preserved the blur and the clean top edge, so we restore that. Only the
        // traffic lights fade in/out with the overlay reveal.
        window.title = title
        window.titleVisibility = .hidden
        // Traffic lights always visible (no fade); the filename is drawn by our
        // own always-on title label (keeping titleVisibility .hidden preserves
        // the under-titlebar scroll + frost + header alignment).
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
    }
}
