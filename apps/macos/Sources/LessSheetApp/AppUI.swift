import AppKit
import Contracts
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

        // No document on launch: immediately present the native open panel; a
        // cancel leaves the empty window with the menu bar available (ARCH req 3).
        if !routedLaunchOpen {
            DispatchQueue.main.async { AppDelegate.openViaPanel() }
        }
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
        // Traffic lights hidden at rest; revealed with the overlay.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 0
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

    /// The Settings gear opens a separate, normal titled window bound to the
    /// same document state (ARCH req 9).
    func presentSettings() {
        if let window = settingsWindow {
            DocumentModel.shared.settingsOpen = true
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: .shared))
        window.center()
        window.delegate = SettingsWindowObserver.shared
        DocumentModel.shared.settingsOpen = true
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }
}

/// Clears `settingsOpen` when the Settings window closes (so the overlay can
/// resume its idle fade).
@MainActor
final class SettingsWindowObserver: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowObserver()
    func windowWillClose(_ notification: Notification) {
        DocumentModel.shared.settingsOpen = false
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
        content
            .background(WindowConfigurator(revealed: model.overlayRevealed, title: windowTitle))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launch:
            EmptyStateView(line: "Open a file to view it — ⌘O")

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
            ErrorPanel(error: error, path: path)
                .task(id: model.openGeneration) {
                    FrameDump.dumpError(error: error, path: path)
                    FrameDump.terminateIfRequested()
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
            // The filtered banner (ARCH req. 11) is independent of the
            // floating overlay's hover reveal/fade — it stays up the whole
            // time a filter is active, top-leading past the row gutter.
            FilterBannerView(model: model)
                .padding(.top, GridMetrics.titleBarInset + 8)
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(model.filterBanner != nil)
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
            if JumpProbe.active {
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
            } else if FrameDump.liveGridInitialDumpPath == nil {
                // Overlay / find / settings / overscroll etc. render off a SwiftUI
                // mirror here; the plain grid-content scene instead self-captures
                // the LIVE table from the grid controller (see NativeGrid).
                FrameDump.dumpIfRequested(for: model)
                FrameDump.terminateIfRequested()
            }
        }
    }

    private var windowTitle: String {
        if case .document = model.phase, !model.path.isEmpty {
            return (model.path as NSString).lastPathComponent
        }
        return "LessSheet"
    }
}

/// A single quiet line, centered — the launch prompt and the empty-file state.
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

// MARK: - Window chrome (reactive)

/// Reveals/hides the traffic lights with the overlay and keeps the window's
/// document title current. Static chrome (transparent title bar, hidden title)
/// is set once by the delegate at window creation.
struct WindowConfigurator: NSViewRepresentable {
    let revealed: Bool
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
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.animator().alphaValue = revealed ? 1 : 0
        }
    }
}
