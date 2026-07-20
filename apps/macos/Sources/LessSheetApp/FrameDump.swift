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
    private static let settingsSize = CGSize(width: 420, height: 500)

    @MainActor
    static func dumpIfRequested(for model: DocumentModel) {
        guard let path = dumpPath else { return }

        pageToFirstRowIfRequested(model)

        // An empty document renders the quiet empty-state line, not a grid.
        guard model.columnCount > 0 else {
            render(EmptyStateView(line: "This file is empty."), size: gridSize, to: path)
            terminateIfRequested()
            return
        }

        let scene = ProcessInfo.processInfo.environment[sceneKey] ?? "grid"
        renderScene(scene, model: model, path: path)
    }

    /// Verification-only: page to a start row so a grid dump can show larger
    /// row numbers and the widened gutter (inert without the env var).
    @MainActor
    private static func pageToFirstRowIfRequested(_ model: DocumentModel) {
        if let raw = ProcessInfo.processInfo.environment["LESSSHEET_DUMP_FIRSTROW"],
           let start = UInt64(raw) {
            model.dumpMaterialize(startRow: start)
        }
    }

    /// Dispatches `scene` to the matching render. Grouped into small helpers so
    /// no single function carries the whole switch; the groups match disjoint
    /// scene sets (find* / chrome / flow), so order between them is irrelevant,
    /// and an unmatched scene falls through to the plain grid — identical to the
    /// original single `switch`'s `default`.
    @MainActor
    private static func renderScene(_ scene: String, model: DocumentModel, path: String) {
        if renderFindScene(scene, model: model, path: path) { return }
        if renderChromeScene(scene, model: model, path: path) { return }
        if renderFlowScene(scene, model: model, path: path) { return }
        render(DumpGrid(model: model), size: gridSize, to: path)
    }

    /// The find-family scenes (ARCH req. 9). Returns false if `scene` is not one.
    @MainActor
    private static func renderFindScene(_ scene: String, model: DocumentModel, path: String) -> Bool {
        switch scene {
        case "find", "findtext":
            render(findScene(model, findSession: FindScenes.textState, fieldActive: true), size: gridSize, to: path)
        case "findwhere":
            render(findScene(model, findSession: FindScenes.whereState, fieldActive: true), size: gridSize, to: path)
        case "findcounts":
            render(findScene(model, findSession: FindScenes.countsState, fieldActive: true), size: gridSize, to: path)
        case "findnomatches":
            render(
                findScene(model, findSession: FindScenes.noMatchesState, fieldActive: true),
                size: gridSize, to: path
            )
        case "findwrapped":
            render(findScene(model, findSession: FindScenes.wrappedState, fieldActive: true), size: gridSize, to: path)
        case "highlights":
            // Grid with subtle + strong highlights, popup closed so they read
            // clearly (the Find button carries its active accent ring).
            render(
                findScene(model, findSession: FindScenes.highlightsState, fieldActive: false),
                size: gridSize, to: path
            )
        default:
            return false
        }
        return true
    }

    /// The chrome scenes (overlay / title bar / overscroll / separator pills).
    /// Returns false if `scene` is not one.
    @MainActor
    private static func renderChromeScene(_ scene: String, model: DocumentModel, path: String) -> Bool {
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
        default:
            return false
        }
        return true
    }

    /// The jump / reject / progress / settings scenes. Returns false otherwise.
    @MainActor
    private static func renderFlowScene(_ scene: String, model: DocumentModel, path: String) -> Bool {
        switch scene {
        case "jump":
            render(
                overlayScene(model, expandedPill: nil, jumpFlow: .idle, jumpFieldActive: true),
                size: gridSize, to: path
            )
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
        default:
            return false
        }
        return true
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
    // The pure scene builders (overlayScene / rejectScene / titleBarScene /
    // findScene / overscrollScene) live in `extension FrameDump` in
    // FrameDumpScenes.swift (pure code motion). `dumpFindResult` stays here
    // because it drives the private `render` / `captureLiveGrid`.

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

    // MARK: - Rendering

    private static var dumpPath: String? {
        guard let path = ProcessInfo.processInfo.environment[pathKey], !path.isEmpty else { return nil }
        return path
    }

    @MainActor
    private static func render(_ content: some View, size: CGSize, to path: String) {
        let framed = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipped()

        // Verification-only: pin the appearance so the light+dark dump pair
        // actually differs (LESSSHEET_DUMP_APPEARANCE=dark|light) — mirrors the
        // live-grid capture. Inject the SwiftUI colorScheme (for semantic
        // ShapeStyles like .primary/.secondary) AND resolve dynamic catalog
        // NSColors under the matching NSAppearance while ImageRenderer rasterizes.
        // Absent env var => the ambient default (unchanged behavior).
        let appearance: NSAppearance?
        let rendered: AnyView
        switch ProcessInfo.processInfo.environment["LESSSHEET_DUMP_APPEARANCE"]?.lowercased() {
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
            rendered = AnyView(framed.environment(\.colorScheme, .dark))
        case "light":
            appearance = NSAppearance(named: .aqua)
            rendered = AnyView(framed.environment(\.colorScheme, .light))
        default:
            appearance = nil
            rendered = AnyView(framed)
        }

        let renderer = ImageRenderer(content: rendered)
        renderer.scale = 2

        let cgImage: CGImage?
        if let appearance {
            var image: CGImage?
            appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
            cgImage = image
        } else {
            cgImage = renderer.cgImage
        }

        guard
            let cgImage,
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
