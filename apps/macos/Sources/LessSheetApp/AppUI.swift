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
    case "on": header = .forcedOn
    case "off": header = .forcedOff
    default: break
    }

    return DialectOverride(separator: separator, quote: quote, header: header)
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
        .task(id: model.openGeneration) {
            // First data-bearing frame: emit the cold-start marker (guarded to
            // once per open), then dump the requested frame for verification.
            LaunchTiming.phase("first_rows_task")
            model.markFirstRowsVisible()
            // Screenshot capture (CaptureProbe): announce the window id and
            // apply any requested pill reveal ALONGSIDE the probe chain below —
            // a state probe like LESSSHEET_FIND still runs and leaves its
            // popup open for the shot. Inert without LESSSHEET_CAPTURE_*.
            CaptureProbe.announce(model: model)
            if SettingsRedesignProbe.active {
                SettingsRedesignProbe.run(model: model)
            } else if JumpProbe.active {
                // Verification: drive the real jump path AFTER first paint. The
                // arrival dumps + terminates itself, so skip the first-frame
                // dump/terminate (which would quit before the jump completes).
                JumpProbe.run(model: model)
            } else if JumpStepProbe.active {
                // Verification: drive the jump field's ↑/↓ stepping (direction,
                // wrap, seed, no-landing, Enter, real key routing) — logs +
                // terminates itself.
                JumpStepProbe.run(model: model)
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
