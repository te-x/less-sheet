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
//   grid (default) · overlay · pills · progress · configure   (error uses its
// own entry). Every scene renders EAGERLY (no ScrollView/LazyVStack, which
// ImageRenderer cannot capture off-screen) and bounded to the loaded window, so
// a dump stays O(viewport) on any file size.
//
// Inert (zero cost) when the env var is absent, and always invoked AFTER the
// cold-start marker fires, so it never pollutes the < 500 ms measurement.
enum FrameDump {
    private static let pathKey = "LESSSHEET_DUMP_FRAME"
    private static let sceneKey = "LESSSHEET_DUMP_SCENE"
    private static let gridSize = CGSize(width: 900, height: 600)
    private static let configureSize = CGSize(width: 420, height: 460)

    @MainActor
    static func dumpIfRequested(for model: DocumentModel) {
        guard let path = dumpPath else { return }

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
        case "pills":
            render(overlayScene(model, expandedPill: .separator, jumpFlow: .idle), size: gridSize, to: path)
        case "progress":
            let flow = JumpFlow.scanning(target: model.rowCountInfo.count, preJumpFirstRow: 0, progress: 0.42)
            render(overlayScene(model, expandedPill: nil, jumpFlow: flow), size: gridSize, to: path)
        case "configure":
            // The live Configure window uses a native Form (NSView-backed),
            // which ImageRenderer cannot snapshot; render a plain-view mirror of
            // the same state for headless verification.
            render(DumpConfigure(model: model), size: configureSize, to: path)
        default:
            render(DumpGrid(model: model), size: gridSize, to: path)
        }
    }

    @MainActor
    static func dumpError(error: DocumentOpenError, path filePath: String) {
        guard let path = dumpPath else { return }
        render(ErrorPanel(error: error, path: filePath), size: gridSize, to: path)
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
    private static func overlayScene(_ model: DocumentModel, expandedPill: PillKind?, jumpFlow: JumpFlow) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, revealed: true, expandedPill: expandedPill, jumpFlow: jumpFlow
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
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
/// dump so `ImageRenderer` can capture it off-screen. Renders the header, the
/// currently loaded window rows (bounded), and the spreadsheet fill to both
/// edges — the same `SheetRow` the live grid uses.
struct DumpGrid: View {
    let model: DocumentModel
    private static let maxRows = 40

    var body: some View {
        let widths = model.visibleWidths()
        let dataWidth = widths.reduce(0, +)
        let fillerCols = fillerColumnCount(dataWidth: dataWidth)
        let loaded = min(model.window.rows.count, Self.maxRows)
        let firstRow = Int(model.window.firstRow)
        let usedRows = loaded + 1 // + header
        let capacity = Int(ceil(FrameDump_gridHeight / GridMetrics.rowHeight))
        let fillerRows = max(0, capacity - usedRows)

        VStack(alignment: .leading, spacing: 0) {
            SheetRow(cells: model.headerLabels(), widths: widths, fillerColumns: fillerCols, isHeader: true)
            ForEach(0..<loaded, id: \.self) { i in
                SheetRow(
                    cells: model.visibleBodyCells(forRow: firstRow + i),
                    widths: widths, fillerColumns: fillerCols, isHeader: false
                )
            }
            ForEach(0..<fillerRows, id: \.self) { _ in
                SheetRow(cells: [], widths: widths, fillerColumns: fillerCols, isHeader: false)
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

    private func fillerColumnCount(dataWidth: CGFloat) -> Int {
        let width: CGFloat = 900
        guard width > dataWidth else { return 0 }
        return Int(ceil((width - dataWidth) / GridMetrics.fillerColumnWidth))
    }
}

private let FrameDump_gridHeight: CGFloat = 600

/// A plain-view mirror of the Configure window for headless dumps: the same
/// parse parameters (current values) and per-column visibility state, with the
/// last visible column marked disabled. Uses only ImageRenderer-capturable
/// views (Text + SF Symbols), unlike the live native Form.
struct DumpConfigure: View {
    let model: DocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure").font(.title3.weight(.semibold))

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
