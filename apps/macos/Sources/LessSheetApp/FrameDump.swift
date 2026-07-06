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
        case "progress":
            let flow = JumpFlow.scanning(target: model.rowCountInfo.count, preJumpFirstRow: 0, progress: 0.42)
            render(overlayScene(model, expandedPill: nil, jumpFlow: flow), size: gridSize, to: path)
        case "configure", "settings":
            // The live Settings window uses a native Form (NSView-backed), which
            // ImageRenderer cannot snapshot; render a plain-view mirror of the
            // same state for headless verification.
            render(DumpSettings(model: model), size: settingsSize, to: path)
        default:
            render(DumpGrid(model: model), size: gridSize, to: path)
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
        render(DumpGrid(model: model), size: gridSize, to: path)
    }

    /// Headless run aid: when `LESSSHEET_DUMP_EXIT` is set, quit shortly after the
    /// first frame so a launched instance self-closes (works with OR without a
    /// dump path — the latter lets `time -l` measure RSS with the dump hook off).
    /// Absent in normal use — the viewer never self-terminates.
    @MainActor
    static func terminateIfRequested() {
        guard ProcessInfo.processInfo.environment["LESSSHEET_DUMP_EXIT"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
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

    /// The revealed title-bar state (req. 1): the grid with the document title +
    /// traffic lights shown, plus the bottom-right control row. The real title
    /// bar is NSWindow chrome ImageRenderer can't capture, so it is simulated
    /// here (like the glass/Form dump mirrors) purely for verification.
    @MainActor
    private static func titleBarScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(from: model, revealed: true, expandedPill: nil, jumpFlow: .idle)
        return ZStack(alignment: .top) {
            DumpGrid(model: model)
            DumpTitleBar(title: (model.path as NSString).lastPathComponent)
        }
        .overlay(alignment: .bottomTrailing) { OverlayView(model: snapshot) }
        .environment(\.overlayDumpChrome, true)
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
        let capacity = Int(ceil(FrameDump_gridHeight / GridMetrics.rowHeight))
        let fillerRows = max(0, capacity - usedRows)

        VStack(alignment: .leading, spacing: 0) {
            SheetRow(rowNumber: nil, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                     cells: model.headerLabels(), widths: widths, fillerColumns: fillerCols, isHeader: true)
            ForEach(0..<loaded, id: \.self) { i in
                SheetRow(
                    rowNumber: firstRow + i + 1, rowNumberWidth: gutterWidth, stickyRowNumber: false,
                    cells: model.visibleBodyCells(forRow: firstRow + i),
                    widths: widths, fillerColumns: fillerCols, isHeader: false
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
                    widths: widths, fillerColumns: fillerCols, isHeader: false
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
        .frame(height: 28)
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
