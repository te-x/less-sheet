import AppKit
import Contracts
import Foundation
import SwiftUI

// Opt-in, self-rendering frame dump for HEADLESS visual verification without any
// screen-capture / TCC-prompting API. When `LESSSHEET_DUMP_FRAME=<path>` is set,
// a view is rendered OFF-SCREEN with `ImageRenderer` to a PNG at `<path>`, then
// `lesssheet.frame_dumped=<path>` is logged to stderr.
//
// `LESSSHEET_DUMP_SCENE` selects which presentation state to capture:
//   grid (default) · overlay · titlebar · overscroll · separator · quote ·
//   jump · progress · settings   (error uses its own entry). "pills" stays as
// an alias of "separator". Every scene renders EAGERLY (no ScrollView/LazyVStack, which
// ImageRenderer cannot capture off-screen) and bounded to the loaded window, so
// a dump stays O(viewport) on any file size.
//
// `LESSSHEET_DUMP_FIRSTROW=<n>` (verification-only) pages the window to row n
// first, so a grid dump can exhibit larger row numbers / the widened gutter.
//
// Inert (zero cost) when the env var is absent, and always invoked AFTER the
// cold-start marker fires, so it never pollutes the < 500 ms measurement.
enum FrameDump {
    private static let pathKey = "LESSSHEET_DUMP_FRAME"
    private static let sceneKey = "LESSSHEET_DUMP_SCENE"
    private static let gridSize = CGSize(width: 900, height: 600)
    private static let settingsSize = CGSize(width: 420, height: 460)

    @MainActor
    static func dumpIfRequested(for model: DocumentModel) {
        guard let path = dumpPath else { return }

        // Verification-only: page to a start row so a grid dump can show larger
        // row numbers and the widened gutter (inert without the env var).
        if let raw = ProcessInfo.processInfo.environment["LESSSHEET_DUMP_FIRSTROW"],
           let start = UInt64(raw) {
            model.dumpMaterialize(startRow: start)
        }

        // An empty document renders the quiet empty-state line, not a grid.
        guard model.columnCount > 0 else {
            render(EmptyStateView(line: "This file is empty."), size: gridSize, to: path)
            terminateIfRequested()
            return
        }

        let scene = ProcessInfo.processInfo.environment[sceneKey] ?? "grid"

        switch scene {
        case "overlay":
            render(overlayScene(model, expandedPill: nil, jumpFlow: .idle), size: gridSize, to: path)
        case "titlebar":
            render(titleBarScene(model), size: gridSize, to: path)
        case "overscroll":
            render(overscrollScene(model), size: gridSize, to: path)
        case "separator", "pills":
            render(overlayScene(model, expandedPill: .separator, jumpFlow: .idle), size: gridSize, to: path)
        case "quote":
            render(overlayScene(model, expandedPill: .quote, jumpFlow: .idle), size: gridSize, to: path)
        case "jump":
            render(overlayScene(model, expandedPill: nil, jumpFlow: .idle, jumpFieldActive: true), size: gridSize, to: path)
        case "reject":
            render(rejectScene(model), size: gridSize, to: path)
        case "progress":
            let flow = JumpFlow.scanning(target: model.rowCountInfo.count, preJumpFirstRow: 0, progress: 0.42)
            render(overlayScene(model, expandedPill: nil, jumpFlow: flow), size: gridSize, to: path)
        case "configure", "settings":
            // The live Settings window uses a native Form (NSView-backed), which
            // ImageRenderer cannot snapshot; render a plain-view mirror of the
            // same state for headless verification.
            render(DumpSettings(model: model), size: settingsSize, to: path)
        case "find", "findtext":
            render(findScene(model, findSession: FindScenes.textState, fieldActive: true), size: gridSize, to: path)
        case "findwhere":
            render(findScene(model, findSession: FindScenes.whereState, fieldActive: true), size: gridSize, to: path)
        case "findcounts":
            render(findScene(model, findSession: FindScenes.countsState, fieldActive: true), size: gridSize, to: path)
        case "findnomatches":
            render(findScene(model, findSession: FindScenes.noMatchesState, fieldActive: true), size: gridSize, to: path)
        case "findwrapped":
            render(findScene(model, findSession: FindScenes.wrappedState, fieldActive: true), size: gridSize, to: path)
        case "highlights":
            // Grid with subtle + strong highlights, popup closed so they read
            // clearly (the Find button carries its active accent ring).
            render(findScene(model, findSession: FindScenes.highlightsState, fieldActive: false), size: gridSize, to: path)
        default:
            render(DumpGrid(model: model), size: gridSize, to: path)
        }
    }

    /// The plain grid-CONTENT scene is captured from the LIVE grid (cacheDisplay
    /// of the real NSTableView — ARCH bonus), self-triggered by the grid
    /// controller once built (deterministic, unlike the first-paint .task which
    /// races the representable's makeNSView). Returns the dump path when that
    /// applies; overlay/find/settings/overscroll keep the SwiftUI mirror, and
    /// probe runs (jump/find/landing) own their terminal dumps.
    static var liveGridInitialDumpPath: String? {
        guard let path = dumpPath else { return nil }
        let env = ProcessInfo.processInfo.environment
        let scene = env[sceneKey]
        guard scene == nil || scene == "grid" else { return nil }
        guard env["LESSSHEET_JUMP"] == nil, env["LESSSHEET_FIND"] == nil,
              env["LESSSHEET_LANDING_STALL"] == nil else { return nil }
        return path
    }

    /// Renders the LIVE grid container (real NSTableView rows, gutter, header,
    /// hairlines, highlights, spreadsheet fill, EOF overscroll) into a PNG via
    /// `NSView.cacheDisplay` — no screen capture, no TCC prompt. The glass band
    /// composites in the live compositor only, so it reads as its backdrop here
    /// (same limitation as ImageRenderer); everything the grid DRAWS is captured.
    /// Returns false when there is no live grid to capture.
    @MainActor
    static func captureLiveGrid(to path: String) -> Bool {
        // The representable's makeNSView (which registers the live grid) can lag
        // the first-paint .task by a render tick; pump the main runloop briefly
        // so the REAL grid exists and is sized before we capture it.
        let deadline = Date().addingTimeInterval(0.6)
        while (NativeGridController.live?.container.bounds.width ?? 0) < 1, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard let controller = NativeGridController.live, controller.container.bounds.width > 0 else {
            return false
        }
        let container = controller.container
        // Appearance: honor the SYSTEM/inherited appearance by default (so a dark
        // system captures dark, matching what the user sees and avoiding a
        // forced-light flash), and let LESSSHEET_DUMP_APPEARANCE=dark|light pin
        // either for the deterministic light+dark verification pair (ARCH
        // criterion 5). Only set when forced — never override the live default.
        switch ProcessInfo.processInfo.environment["LESSSHEET_DUMP_APPEARANCE"]?.lowercased() {
        case "dark": container.appearance = NSAppearance(named: .darkAqua)
        case "light": container.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // Flush any pending model-driven update (e.g. a jump/find landing scroll
        // set just before this capture) and let it settle so the visible rows and
        // gutter reflect the landed position, not the pre-landing top.
        controller.apply()
        let settle = Date().addingTimeInterval(0.2)
        while Date() < settle { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return false }
        controller.compositeCapture(into: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            log("lesssheet.frame_dump_failed=\(path)")
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log("lesssheet.frame_dumped=\(path)")
            return true
        } catch {
            log("lesssheet.frame_dump_failed=\(path)")
            return false
        }
    }

    @MainActor
    static func dumpError(error: DocumentOpenError, path filePath: String) {
        guard let path = dumpPath else { return }
        render(ErrorPanel(error: error, path: filePath), size: gridSize, to: path)
    }

    /// Renders the grid at the currently materialized window — used by the
    /// jump verification hook to capture the arrival frame (the landed row's
    /// distinctive content) once a jump completes. The model has already paged
    /// its window to the landed row, so `DumpGrid` shows the target at top.
    @MainActor
    static func dumpArrival(for model: DocumentModel) {
        guard let path = dumpPath else { return }
        // The live grid has already landed the target row (jump path); capture
        // the REAL table so the arrival frame — including EOF overscroll on a
        // jump-to-end — is the shipping render, not the mirror.
        if !captureLiveGrid(to: path) {
            render(DumpGrid(model: model), size: gridSize, to: path)
        }
    }

    /// Renders the jump field in its REJECTED (red) state over the grid — the
    /// jump verification hook uses this to capture the rejection moment (item 4).
    @MainActor
    static func dumpReject(for model: DocumentModel) {
        guard let path = dumpPath else { return }
        render(rejectScene(model), size: gridSize, to: path)
    }

    /// Headless run aid: when `LESSSHEET_DUMP_EXIT` is set, quit shortly after the
    /// first frame so a launched instance self-closes (works with OR without a
    /// dump path — the latter lets `time -l` measure RSS with the dump hook off).
    /// Absent in normal use — the viewer never self-terminates.
    @MainActor
    static func terminateIfRequested() {
        guard ProcessInfo.processInfo.environment["LESSSHEET_DUMP_EXIT"] != nil else { return }
        // Layout-logging runs need the elastic scroll + safe-area to fully
        // settle before we read the final frames; other runs quit promptly.
        let delay = ScrollProbe.layoutEnabled ? 1.5 : 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSApp.terminate(nil) }
    }

    // MARK: - Scene composition

    @MainActor
    private static func overlayScene(
        _ model: DocumentModel, expandedPill: PillKind?, jumpFlow: JumpFlow, jumpFieldActive: Bool = false
    ) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, revealed: true, expandedPill: expandedPill, jumpFlow: jumpFlow, jumpFieldActive: jumpFieldActive
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }

    /// The rejected-jump state (item 4): the jump field re-armed and styled red
    /// (blink), showing the exact total in its copy so the user sees the valid
    /// range. The live blink+shake is animated; the dump captures the red field.
    @MainActor
    private static func rejectScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, revealed: true, expandedPill: nil, jumpFlow: .idle, jumpFieldActive: true
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
        .environment(\.overlayJumpRejected, true)
    }

    /// The revealed title-bar state (req. 1): the grid with the document title +
    /// traffic lights shown, plus the bottom-right control row. The real title
    /// bar is NSWindow chrome ImageRenderer can't capture, so it is simulated
    /// here (like the glass/Form dump mirrors) purely for verification.
    @MainActor
    private static func titleBarScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(from: model, revealed: true, expandedPill: nil, jumpFlow: .idle)
        // Mirror the live chrome (item 1): the grid content is inset by the
        // title-bar height, so at rest the header + row 1 sit fully BELOW the
        // title-bar region (never hidden under it); scrolled content travels
        // under the region and frosts (the native scroll-edge effect — live
        // only, can't be captured off-screen).
        return ZStack(alignment: .top) {
            DumpGrid(model: model, topInset: DumpTitleBar.height)
            DumpTitleBar(title: (model.path as NSString).lastPathComponent)
        }
        .overlay(alignment: .bottomTrailing) { OverlayView(model: snapshot) }
        .environment(\.overlayDumpChrome, true)
    }

    /// A find scene (ARCH req. 9): the grid (with the search's viewport
    /// highlights) plus the overlay's find popup in a chosen state, rendered
    /// with the opaque dump chrome. The synthetic `findSession` drives both the
    /// popup copy and the grid highlights (via the snapshot's CellMatcher).
    @MainActor
    private static func findScene(_ model: DocumentModel, findSession: FindSession, fieldActive: Bool) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, revealed: true, expandedPill: nil, jumpFlow: .idle,
            findSession: findSession, findFieldActive: fieldActive
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: snapshot)          // highlights read from snapshot.findSession
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }

    /// The find verification hook's terminal dump: the LIVE model already holds
    /// the resolved search (popup open, results + highlights), rendered with the
    /// opaque dump chrome.
    @MainActor
    static func dumpFindResult(for model: DocumentModel) {
        guard let path = dumpPath else { return }
        let scene = ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: model)
        }
        .environment(\.overlayDumpChrome, true)
        render(scene, size: gridSize, to: path)
        // Also capture the LIVE grid (its SheetRowView highlights) alongside the
        // popup mirror, so the shipping highlight render is verifiable too.
        _ = captureLiveGrid(to: (path as NSString).deletingPathExtension + ".live.png")
    }

    /// The scrolled-to-end state (req. 8): the last data rows anchored so the
    /// final row sits above the floating controls, with the end-of-file
    /// overscroll strip of empty grid below it — proving the last row stays
    /// legible instead of hiding under the buttons.
    @MainActor
    private static func overscrollScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(from: model, revealed: true, expandedPill: nil, jumpFlow: .idle)
        return ZStack(alignment: .bottomTrailing) {
            DumpEndGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }

    // MARK: - Rendering

    private static var dumpPath: String? {
        guard let path = ProcessInfo.processInfo.environment[pathKey], !path.isEmpty else { return nil }
        return path
    }

    @MainActor
    private static func render(_ content: some View, size: CGSize, to path: String) {
        let renderer = ImageRenderer(content:
            content
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipped()
        )
        renderer.scale = 2

        guard
            let cgImage = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            log("lesssheet.frame_dump_failed=\(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log("lesssheet.frame_dumped=\(path)")
        } catch {
            log("lesssheet.frame_dump_failed=\(path)")
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Eager (non-lazy, no ScrollView) spreadsheet grid used ONLY by the frame
/// dump so `ImageRenderer` can capture it off-screen. Renders the fixed
/// row-number gutter, the header, the currently loaded window rows (bounded),
/// and the spreadsheet fill to both edges — the same `SheetRow` the live grid
/// uses (with stickiness disabled: there is no ScrollView to counter here).
struct DumpGrid: View {
    let model: DocumentModel
    /// A top inset (title-bar height) used by the title-bar scene so the header
    /// + row 1 render BELOW the simulated title bar, mirroring the live safe-area
    /// inset (item 1). Zero for the normal grid dump.
    var topInset: CGFloat = 0
    private static let maxRows = 40

    var body: some View {
        let widths = model.visibleWidths()
        let dataWidth = widths.reduce(0, +)
        let loaded = min(model.window.rows.count, Self.maxRows)
        let firstRow = Int(model.window.firstRow)
        let gutterWidth = DocumentModel.rowNumberWidth(
            digits: DocumentModel.rowNumberDigits(forMaxNumber: firstRow + loaded)
        )
        let fillerCols = fillerColumnCount(dataWidth: dataWidth, gutterWidth: gutterWidth)
        let usedRows = loaded + 1 // + header
        let capacity = Int(ceil((FrameDump_gridHeight - topInset) / GridMetrics.rowHeight))
        let fillerRows = max(0, capacity - usedRows)

        VStack(alignment: .leading, spacing: 0) {
            if topInset > 0 { Color.clear.frame(height: topInset) }
            SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                     cells: model.headerLabels(), widths: widths, fillerColumns: fillerCols, isHeader: true)
            ForEach(0..<loaded, id: \.self) { i in
                SheetRow(
                    rowNumber: firstRow + i + 1, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                    cells: model.visibleBodyCells(forRow: firstRow + i),
                    widths: widths, fillerColumns: fillerCols, isHeader: false,
                    highlights: model.cellHighlights(forRow: firstRow + i)
                )
            }
            ForEach(0..<fillerRows, id: \.self) { _ in
                SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                         cells: [], widths: widths, fillerColumns: fillerCols, isHeader: false)
            }
            Spacer(minLength: 0)
        }
        // Pinned to the dump size and clipped: fill rows overflow to the right
        // edge (last cell clipped) without widening the view, so an overlay
        // composited over this stays correctly inset from the window edge.
        .frame(width: 900, height: 600, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .environment(\.overlayDumpChrome, true)   // header uses its opaque fallback off-screen
    }

    private func fillerColumnCount(dataWidth: CGFloat, gutterWidth: CGFloat) -> Int {
        let available: CGFloat = 900 - gutterWidth
        guard available > dataWidth else { return 0 }
        return Int(ceil((available - dataWidth) / GridMetrics.fillerColumnWidth))
    }
}

private let FrameDump_gridHeight: CGFloat = 600

/// End-anchored eager grid for the overscroll dump (req. 8): the last loaded
/// data rows, then the end-of-file overscroll strip of empty grid, so the final
/// data row lands above where the floating controls sit. Mirrors the live
/// scrolled-to-end state (header pinned at top, earlier rows scrolled off).
struct DumpEndGrid: View {
    let model: DocumentModel

    var body: some View {
        let widths = model.visibleWidths()
        let dataWidth = widths.reduce(0, +)
        let n = model.window.rows.count
        let firstRow = Int(model.window.firstRow)
        let gutterWidth = DocumentModel.rowNumberWidth(
            digits: DocumentModel.rowNumberDigits(forMaxNumber: firstRow + n)
        )
        let fillerCols = fillerColumnCount(dataWidth: dataWidth, gutterWidth: gutterWidth)
        // Rows that fit above the overscroll strip (minus the header row).
        let usable = max(0, Int(FrameDump_gridHeight / GridMetrics.rowHeight) - 1 - GridMetrics.overscrollRows)
        let show = min(n, usable)
        let start = n - show

        VStack(alignment: .leading, spacing: 0) {
            SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                     cells: model.headerLabels(), widths: widths, fillerColumns: fillerCols, isHeader: true)
            ForEach(start..<n, id: \.self) { i in
                SheetRow(
                    rowNumber: firstRow + i + 1, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                    cells: model.visibleBodyCells(forRow: firstRow + i),
                    widths: widths, fillerColumns: fillerCols, isHeader: false,
                    highlights: model.cellHighlights(forRow: firstRow + i)
                )
            }
            ForEach(0..<GridMetrics.overscrollRows, id: \.self) { _ in
                SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                         cells: [], widths: widths, fillerColumns: fillerCols, isHeader: false)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 900, height: 600, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .environment(\.overlayDumpChrome, true)   // header uses its opaque fallback off-screen
    }

    private func fillerColumnCount(dataWidth: CGFloat, gutterWidth: CGFloat) -> Int {
        let available: CGFloat = 900 - gutterWidth
        guard available > dataWidth else { return 0 }
        return Int(ceil((available - dataWidth) / GridMetrics.fillerColumnWidth))
    }
}

/// A simulated macOS title bar for the headless title-bar dump (req. 1): traffic
/// lights at the leading edge and the document title centered, over a
/// translucent band standing in for the real chrome's top-of-window blur.
struct DumpTitleBar: View {
    let title: String
    /// Title-bar band height — matches the window's top safe area (item 1).
    static let height: CGFloat = 32

    var body: some View {
        ZStack {
            Text(title.isEmpty ? "LessSheet" : title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                dot(Color(red: 1.00, green: 0.37, blue: 0.34))
                dot(Color(red: 1.00, green: 0.74, blue: 0.19))
                dot(Color(red: 0.22, green: 0.79, blue: 0.30))
                Spacer()
            }
            .padding(.leading, 20)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
    }
}

/// A plain-view mirror of the Settings window for headless dumps: the same parse
/// parameters (current values) and per-column visibility state, with the last
/// visible column marked disabled. Uses only ImageRenderer-capturable views
/// (Text + SF Symbols), unlike the live native Form.
struct DumpSettings: View {
    let model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.title3.weight(.semibold))

            Text("Parsing").font(.caption).foregroundStyle(.secondary)
            labeled("First row is header", model.dialect.hasHeader ? "On" : "Off")
            labeled("Separator", DialectGlyph.separatorName(model.dialect.separator))
            labeled("Quote character", model.dialect.quote.map(DialectGlyph.quoteName) ?? "None")

            Divider().padding(.vertical, 4)

            Text("Columns").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<model.columnCount, id: \.self) { column in
                let hidden = model.visibility.isHidden(column)
                let lastVisible = !hidden && !model.canHide(column)
                HStack(spacing: 8) {
                    Image(systemName: hidden ? "square" : "checkmark.square.fill")
                        .foregroundStyle(lastVisible ? Color.secondary : (hidden ? Color.secondary : Color.accentColor))
                    Text(model.columnLabel(column))
                        .foregroundStyle(lastVisible ? .secondary : .primary)
                    if lastVisible {
                        Text("last visible").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 460, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary)
        }
    }
}

/// Synthetic find sessions for the headless find dumps, keyed to the find.csv
/// fixture (header name,qty,note; data rows 0..7 — "needle" folds to rows
/// 0,1,2,3,6,7). Presentation-only fixtures: the counts state uses illustrative
/// numbers to exhibit the growing "Match n of m…" + "Scanning… %" copy.
enum FindScenes {
    private static func draft(
        mode: FindMode, text: String = "", column: Int = 0,
        op: SearchOperator = .equals, value: String = ""
    ) -> FindDraft {
        FindDraft(mode: mode, text: text, column: column, op: op, value: value)
    }

    private static let empty = FindDisplay(
        request: nil, current: nil, position: nil,
        total: 0, totalIsFinal: false, progress: nil, notice: nil
    )

    /// Text popup, nothing run yet.
    static let textState = FindSession(draft: draft(mode: .text, text: "needle"), display: empty)

    /// Where popup, nothing run yet (qty ≤ 2).
    static let whereState = FindSession(
        draft: draft(mode: .predicate, column: 1, op: .lessOrEqual, value: "2"),
        display: empty
    )

    /// Growing count while scanning ("Match 3 of 47…" + "Scanning… 34%"), strong
    /// highlight on the current match + subtle on the rest.
    static let countsState = FindSession(
        draft: draft(mode: .text, text: "needle"),
        display: FindDisplay(
            request: .text(query: "needle", scope: nil),
            current: SearchMatch(row: 2, column: 0),
            position: 3, total: 47, totalIsFinal: false, progress: 0.34, notice: nil
        )
    )

    /// No matches anywhere.
    static let noMatchesState = FindSession(
        draft: draft(mode: .text, text: "zzz"),
        display: FindDisplay(
            request: .text(query: "zzz", scope: nil),
            current: nil, position: nil, total: 0, totalIsFinal: true, progress: nil, notice: .noMatches
        )
    )

    /// Wrapped-to-start notice (Next past the last match).
    static let wrappedState = FindSession(
        draft: draft(mode: .text, text: "needle"),
        display: FindDisplay(
            request: .text(query: "needle", scope: nil),
            current: SearchMatch(row: 0, column: 2),
            position: 1, total: 6, totalIsFinal: true, progress: nil, notice: .wrappedToStart
        )
    )

    /// Highlights only (popup closed): subtle on every "needle" cell, strong on
    /// the current match (row 0, col 2 — "alpha needle").
    static let highlightsState = FindSession(
        draft: draft(mode: .text, text: "needle"),
        display: FindDisplay(
            request: .text(query: "needle", scope: nil),
            current: SearchMatch(row: 0, column: 2),
            position: 1, total: 6, totalIsFinal: true, progress: nil, notice: nil
        )
    )
}
