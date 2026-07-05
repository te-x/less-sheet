import AppKit
import Contracts
import LessSheetKit
import Observation
import SwiftUI

// MARK: - View model

/// Owns presentation state: the immutable head snapshot from the core, the
/// "First Row Is Header" override (initialized to the core's suggestion), and
/// the derived `DisplayTable`. Every open — dialog, launch-with-file, and CLI —
/// funnels through `open(path:)`; the header toggle re-derives from the SAME
/// snapshot without touching the core.
///
/// A single shared instance is referenced by both the SwiftUI scene and the
/// `AppDelegate`, so launch-time opens routed by the delegate reach the same
/// state the window renders.
@MainActor
@Observable
final class DocumentModel {
    static let shared = DocumentModel()

    enum Content: Equatable {
        case launch // nothing opened yet
        case table(DisplayTable) // may be DisplayTable.empty for an empty file
        case failure(DocumentOpenError, path: String)
    }

    private(set) var content: Content = .launch
    private(set) var canToggleHeader = false
    private(set) var firstRowIsHeader = false
    /// Bumped on every completed open; keys the first-frame timing marker.
    private(set) var openGeneration = 0

    private var markedGeneration = -1
    private var snapshot: HeadSnapshot = .empty
    private let opener: any DocumentOpening
    private let deriver: any TableDisplayDeriving

    init(
        opener: any DocumentOpening = CoreDocumentOpener(),
        deriver: any TableDisplayDeriving = TableDisplayDeriver()
    ) {
        self.opener = opener
        self.deriver = deriver
    }

    /// The single internal open path shared by dialog, launch-with-file, and CLI.
    func open(path: String) async {
        do {
            apply(try await opener.openHead(path: path))
        } catch {
            snapshot = .empty
            firstRowIsHeader = false
            canToggleHeader = false
            content = .failure(error, path: path)
            openGeneration += 1
        }
    }

    /// Applies the "First Row Is Header" override; re-derives immediately.
    func setFirstRowIsHeader(_ on: Bool) {
        guard firstRowIsHeader != on else { return }
        firstRowIsHeader = on
        rederive()
    }

    /// Emits the cold-start marker for the first frame that actually shows data.
    /// Called from the data table's `.task` (view attached to the hierarchy);
    /// guarded so exactly one marker is emitted per open that reaches the table.
    func markFirstRowsVisible() {
        guard markedGeneration != openGeneration else { return }
        markedGeneration = openGeneration
        LaunchTiming.markFirstRowsVisible()
    }

    private func apply(_ snap: HeadSnapshot) {
        snapshot = snap
        firstRowIsHeader = snap.headerSuggested
        canToggleHeader = snap.columnCount > 0
        rederive()
        openGeneration += 1
    }

    private func rederive() {
        content = .table(deriver.derive(from: snapshot, firstRowIsHeader: firstRowIsHeader))
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
/// not by a SwiftUI `WindowGroup`. A `WindowGroup` reacts to file/CLI launches
/// non-deterministically (0, 1, or even 2 windows depending on whether AppKit
/// delivers the file via `openFiles`, an open-URL event, or plain argv), which
/// made CLI launch (`open --args` / direct exec) flaky — sometimes no window at
/// all. So the app uses a windowless `Settings` scene (menu only) and this
/// delegate owns exactly one `NSHostingView`-backed window. All open paths —
/// argv (CLI), `open <file>` / Finder / drag (open events) — funnel into the one
/// shared model that the single window renders.
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
    // These fire before applicationDidFinishLaunching; they only route (the
    // window is created there). Opening a file while running reuses the window.
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
        // Restore the saved frame if one exists; only center on first-ever launch
        // (centering unconditionally would discard the restored position).
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
    @State private var model = DocumentModel.shared

    var body: some Scene {
        // No WindowGroup: the main window is created deterministically by the
        // delegate. `Settings` adds no window at launch — it only carries the
        // app's menu commands into the menu bar.
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Open…") { AppDelegate.openViaPanel() }
                        .keyboardShortcut("o", modifiers: .command)
                }
                CommandMenu("View") {
                    Toggle("First Row Is Header", isOn: Binding(
                        get: { model.firstRowIsHeader },
                        set: { model.setFirstRowIsHeader($0) }
                    ))
                    .disabled(!model.canToggleHeader)
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
                    // marker, then (opt-in) dump the frame for headless verification.
                    // The dump uses an eager copy (ImageRenderer cannot capture a
                    // ScrollView/LazyVStack off-screen); same cells, same rule.
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
/// Data is anchored top-left; columns keep their fixed natural width; empty
/// filler cells (same grid lines) extend right and down to the window edges,
/// and re-extend on resize (onGeometryChange re-reports the viewport). Big
/// files that overflow the viewport scroll instead (no filler in that axis).
/// Slice 1: no virtual scrolling — the head window (≤ N rows) renders directly.
struct DataTableView: View {
    let table: DisplayTable
    // The ScrollView's own size (the viewport). Read via onGeometryChange rather
    // than a root GeometryReader: a GeometryReader at the window-content root
    // prevents the WindowGroup window from materializing on an openFiles/CLI
    // launch. Starts .zero (grid renders at content size); the first geometry
    // callback fills it out, and each resize re-extends the filler.
    @State private var viewport: CGSize = .zero

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            SpreadsheetGrid(table: table, viewport: viewport, lazy: true)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
    }
}

/// Eager (non-lazy, no ScrollView) grid used ONLY by the opt-in frame dump so
/// `ImageRenderer` can capture it off-screen (it cannot render a
/// ScrollView/LazyVStack). Same cells, grid lines, and fill as `DataTableView`,
/// sized to the dump canvas.
struct DumpTableView: View {
    let table: DisplayTable
    static let dumpSize = CGSize(width: 900, height: 600)

    var body: some View {
        SpreadsheetGrid(table: table, viewport: Self.dumpSize, lazy: false)
            .frame(width: Self.dumpSize.width, height: Self.dumpSize.height, alignment: .topLeading)
    }
}

/// Spreadsheet grid shared by the on-screen and dump paths. Renders the header
/// row plus data rows, then pads with empty filler columns/rows so the grid
/// always covers at least `viewport`. Filler cells are pure UI — no core calls.
///
/// Rows are DIRECT children of the `LazyVStack` (a `ForEach`, not one wrapping
/// container), so only the visible rows materialize — O(viewport) memory even
/// for the full head window. Grid lines are drawn PER ROW: each row owns one
/// full-width bottom hairline plus per-column vertical hairlines. Because every
/// row's geometry is identical, the per-row lines stack into a seamless grid
/// (including the data→filler boundary) with no full-height Canvas backing store.
struct SpreadsheetGrid: View {
    let table: DisplayTable
    let viewport: CGSize
    var lazy: Bool = true

    private let cellWidth: CGFloat = 150
    private let rowHeight: CGFloat = 28

    /// Total columns = real columns, extended to cover the viewport width.
    private var columnCount: Int {
        let fit = viewport.width > 0 ? Int(ceil(viewport.width / cellWidth)) : 0
        return max(table.columnNames.count, fit)
    }

    /// Empty rows appended below the data to cover the viewport height (0 when
    /// the content — header + data — already overflows it).
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

    // Data rows then empty filler rows, emitted as direct lazy children.
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
/// bottom line (so the horizontal line can never seam, unlike per-cell segments)
/// and per-column vertical lines. Self-contained, so it works as a lazy child.
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
                    // Per-column vertical hairline on the trailing edge.
                    .overlay(alignment: .trailing) { line.frame(width: 1) }
            }
        }
        .background(isHeader ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        // One full-width bottom hairline for the whole row (seamless).
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
        case .io: "Could not read the file"
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
