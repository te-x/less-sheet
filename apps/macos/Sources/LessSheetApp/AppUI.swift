import AppKit
import Contracts
import LessSheetKit
import Observation
import SwiftUI

// STATUS: viewer-ui SEED shell. The walking-skeleton table UI was superseded
// by the windowed session contract; this file keeps the pinned launch
// architecture (delegate-owned single window, argv/open-event routing, timing
// marker, LESSSHEET_DUMP_FRAME hook, in-window error panel) compiling over
// the new `DocumentSession` API with a naive fixed head window. The build
// cell replaces the shell with the real chromeless UI: full-file virtual
// scrolling, hover overlay (Liquid Glass), guess-pills, Configure window,
// jump-to-row with progress, scrollbar estimation (ARCH-viewer-ui reqs 1–16).

// MARK: - Grid content (presentation value)

struct GridContent: Equatable {
    let columnNames: [String]
    let rows: [[String]]

    static let empty = GridContent(columnNames: [], rows: [])
}

// MARK: - View model

/// Owns presentation state over one live `DocumentSession`. Every open —
/// dialog, launch-with-file, CLI, drag & drop — funnels through `open(path:)`.
@MainActor
@Observable
final class DocumentModel {
    static let shared = DocumentModel()

    enum Content: Equatable {
        case launch // nothing opened yet
        case table(GridContent) // may be .empty for an empty file
        case failure(DocumentOpenError, path: String)
    }

    private(set) var content: Content = .launch
    /// Bumped on every completed open; keys the first-frame timing marker.
    private(set) var openGeneration = 0

    private var markedGeneration = -1
    private var session: (any DocumentSession)?
    private let opener: any DocumentSessionOpening

    init(opener: any DocumentSessionOpening = CoreSessionOpener()) {
        self.opener = opener
    }

    /// The single internal open path shared by dialog, launch-with-file, CLI.
    func open(path: String) async {
        session?.close()
        session = nil
        do {
            let session = try await opener.open(path: path, forcing: .sniffAll)
            self.session = session
            // SEED: one fixed head window; the build cell replaces this with
            // viewport-driven paging over the whole file.
            let window = session.setWindow(firstRow: 0, rowCount: 200)
            let names = session.headerCells ?? GenericColumnName.names(count: session.columnCount)
            content = .table(session.columnCount == 0
                ? .empty
                : GridContent(columnNames: names, rows: window.rows))
        } catch {
            content = .failure(error, path: path)
        }
        openGeneration += 1
    }

    /// Emits the cold-start marker for the first frame that actually shows
    /// data; guarded so exactly one marker is emitted per open that reaches
    /// the table.
    func markFirstRowsVisible() {
        guard markedGeneration != openGeneration else { return }
        markedGeneration = openGeneration
        LaunchTiming.markFirstRowsVisible()
    }
}

// MARK: - Launch argument parsing

enum LaunchArguments {
    /// Extracts a document path from process arguments, skipping argv[0] and any
    /// `-flag value` pairs AppKit / NSUserDefaults inject at launch (e.g.
    /// `-NSDocumentRevisionsDebugMode YES`). A flag value is never mistaken for a
    /// path: only a standalone token whose predecessor is not a flag is treated
    /// as the document path. (The frame-dump hook uses an ENV var, not argv, so
    /// it can never be picked up here.)
    static func documentPath(from arguments: [String]) -> String? {
        var previousWasFlag = false
        for arg in arguments.dropFirst() {
            if arg.hasPrefix("-") {
                previousWasFlag = true
                continue
            }
            if previousWasFlag {
                previousWasFlag = false // this token is the preceding flag's value
                continue
            }
            return arg
        }
        return nil
    }
}

// MARK: - App delegate (deterministic single window + open routing)

/// The main window is created HERE, deterministically, for every launch mode —
/// not by a SwiftUI `WindowGroup` (which routes file/CLI launches
/// non-deterministically). All open paths — argv (CLI), `open <file>` /
/// Finder / drag (open events) — funnel into the one shared model that the
/// single window renders.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var routedLaunchOpen = false
    private var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // PRIMARY CLI path: a document path carried in argv (direct exec or
        // `open --args <path>`). Route it unless an open event already did.
        if !routedLaunchOpen, let path = LaunchArguments.documentPath(from: CommandLine.arguments) {
            routedLaunchOpen = true
            route(path)
        }
        showMainWindow() // exactly one window, every launch mode
        NSApp.activate(ignoringOtherApps: true)
    }

    // `open -a LessSheet file.csv`, Finder double-click, and drag-onto-icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        routedLaunchOpen = true
        for url in urls { route(url.path(percentEncoded: false)) }
    }

    // The legacy launch path a bare file argument may take on some OS versions.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        routedLaunchOpen = true
        for filename in filenames { route(filename) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Re-open (Dock click / `open -a` with no doc while running) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(); mainWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func route(_ path: String) {
        Task { await DocumentModel.shared.open(path: path) }
    }

    /// Creates the single main window (idempotent) hosting the SwiftUI content.
    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LessSheet"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.contentView = NSHostingView(rootView: ContentView(model: .shared))
        window.setFrameAutosaveName("LessSheetMain")
        // Restore the saved frame if one exists; only center on first-ever launch.
        if !window.setFrameUsingName("LessSheetMain") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    /// File › Open… — invoked from the menu command.
    static func openViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await DocumentModel.shared.open(path: url.path(percentEncoded: false)) }
        }
    }
}

// MARK: - App

struct LessSheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No WindowGroup: the main window is created deterministically by the
        // delegate; this scene only carries the menu commands.
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Open…") { AppDelegate.openViaPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                }
            }
    }
}

// MARK: - Views

struct ContentView: View {
    let model: DocumentModel

    var body: some View {
        switch model.content {
        case .launch:
            MessageView(symbol: "tablecells", title: "Open a CSV file", detail: "File › Open… (⌘O)")
        case let .table(table):
            if table.columnNames.isEmpty {
                MessageView(symbol: "tablecells", title: "Empty document", detail: nil)
            } else {
                DataTableView(table: table)
                    // First frame that shows document data: emit the cold-start
                    // marker, then (opt-in) dump the frame for headless
                    // verification (eager copy: ImageRenderer cannot capture a
                    // ScrollView/LazyVStack off-screen).
                    .task(id: model.openGeneration) {
                        model.markFirstRowsVisible()
                        FrameDump.dumpIfRequested(DumpTableView(table: table))
                    }
            }
        case let .failure(error, path):
            ErrorPanel(error: error, path: path)
                .task(id: model.openGeneration) {
                    FrameDump.dumpIfRequested(ErrorPanel(error: error, path: path))
                }
        }
    }
}

/// The on-screen table: a spreadsheet-style grid that fills the whole window.
/// Data is anchored top-left; empty filler cells (same grid lines) extend
/// right and down to the window edges. SEED: renders the fixed head window
/// only — the build cell replaces this with core-backed virtual scrolling.
struct DataTableView: View {
    let table: GridContent
    @State private var viewport: CGSize = .zero

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            SpreadsheetGrid(table: table, viewport: viewport, lazy: true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
    }
}

/// Eager (non-lazy, no ScrollView) grid used ONLY by the opt-in frame dump so
/// `ImageRenderer` can capture it off-screen.
struct DumpTableView: View {
    let table: GridContent
    static let dumpSize = CGSize(width: 900, height: 600)

    var body: some View {
        SpreadsheetGrid(table: table, viewport: Self.dumpSize, lazy: false)
            .frame(width: Self.dumpSize.width, height: Self.dumpSize.height, alignment: .topLeading)
    }
}

/// Spreadsheet grid shared by the on-screen and dump paths (unchanged
/// walking-skeleton fill: rows own their hairlines; filler cells are pure UI).
struct SpreadsheetGrid: View {
    let table: GridContent
    let viewport: CGSize
    var lazy: Bool = true

    private let cellWidth: CGFloat = 150
    private let rowHeight: CGFloat = 28

    private var columnCount: Int {
        let fit = viewport.width > 0 ? Int(ceil(viewport.width / cellWidth)) : 0
        return max(table.columnNames.count, fit)
    }

    private var fillerRowCount: Int {
        let contentRows = table.rows.count + 1 // + header row
        let fit = viewport.height > 0 ? Int(ceil(viewport.height / rowHeight)) : 0
        return max(0, max(contentRows, fit) - contentRows)
    }

    private var bodyRowCount: Int { table.rows.count + fillerRowCount }

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section { bodyRows } header: { SheetRow(cells: table.columnNames, columns: columnCount, cellWidth: cellWidth, rowHeight: rowHeight, isHeader: true) }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SheetRow(cells: table.columnNames, columns: columnCount, cellWidth: cellWidth, rowHeight: rowHeight, isHeader: true)
                bodyRows
            }
        }
    }

    private var bodyRows: some View {
        let dataCount = table.rows.count
        return ForEach(Array(0 ..< bodyRowCount), id: \.self) { index in
            SheetRow(
                cells: index < dataCount ? table.rows[index] : [],
                columns: columnCount,
                cellWidth: cellWidth,
                rowHeight: rowHeight,
                isHeader: false
            )
        }
    }
}

/// One grid row: cells (text) plus its own hairlines — a single full-width
/// bottom line and per-column vertical lines.
struct SheetRow: View {
    let cells: [String]
    let columns: Int
    let cellWidth: CGFloat
    let rowHeight: CGFloat
    let isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(0 ..< columns), id: \.self) { col in
                Text(col < cells.count ? cells[col] : "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(isHeader ? .headline : .body)
                    .padding(.horizontal, 8)
                    .frame(width: cellWidth, height: rowHeight, alignment: .leading)
                    .overlay(alignment: .trailing) { line.frame(width: 1) }
            }
        }
        .background(isHeader ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    private var line: some View { Rectangle().fill(Color(nsColor: .gridColor)) }
}

struct ErrorPanel: View {
    let error: DocumentOpenError
    let path: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message).font(.headline)
            Text(path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        switch error {
        case .notFound: "File not found"
        case .permissionDenied: "Permission denied"
        case .io, .invalidArgument: "Could not read the file"
        }
    }
}

struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
