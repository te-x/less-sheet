import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

// The app shell. The single main window is created deterministically by the app
// delegate, NOT by a SwiftUI `WindowGroup`, which routes argv and file launches
// non-deterministically.

// MARK: - Launch argument parsing

enum LaunchArguments {
    /// The document path from argv, skipping argv[0] and any `-flag value` pairs
    /// AppKit and NSUserDefaults inject at launch, so a flag's value is never
    /// mistaken for a path.
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

/// Verification-only: forces the initial dialect from the environment, so a
/// headless run can set up a deliberately wrong guess with no interaction.
/// Absent, everything is sniffed as on a normal first open.
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

// MARK: - Root content

struct ContentView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            // Rides above whatever `content` shows, the pre-open launch state
            // included: a network open can be the very first thing the user does.
            if let progress = model.networkOpenProgress {
                NetworkOpenBanner(model: model, progress: progress)
                    .padding(.trailing, 24)
                    // Clear the control row when a document is already showing.
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
                .task { FrameDump.dumpLaunchIfRequested() }

        case .document:
            if model.columnCount == 0 {
                EmptyStateView(line: "This file is empty.")
                    .task(id: model.openGeneration) {
                        // Not data-bearing, so no timing marker.
                        FrameDump.dumpIfRequested(for: model)
                        FrameDump.terminateIfRequested()
                    }
            } else {
                documentContent
            }

        case let .failure(error, path):
            // A network failure has its own taxonomy — a 404, a timeout, a DNS
            // failure and a redirect loop must each read distinctly — and `phase`
            // cannot carry it, so the detail rides alongside in the model.
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
            // A filter that matched nothing: a centered message over the empty
            // grid, mirroring the empty-file state. The banner says so too.
            if model.filterBanner?.isEmptyResult == true {
                EmptyStateView(line: "No rows match the filter.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            DeferredOverlay(model: model)
            // Our own filename label, since the native title stays hidden to
            // preserve the under-titlebar frost and the header alignment.
            // Truncated at the START: for a network document the tail of a URL is
            // the informative part, and the default mode would keep the scheme
            // and host and hide exactly that.
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
        // Extend the grid UNDER the transparent title bar, so content scrolls
        // beneath it and frosts; the grid re-insets its own content so row 1 rests
        // below the region at rest.
        .ignoresSafeArea(.container, edges: .top)
        .contentShape(Rectangle())
        .task(id: model.openGeneration) {
            // The first data-bearing frame: emit the cold-start marker, then hand
            // off to whichever verification hook is armed. Each probe drives a
            // real user path after first paint and terminates itself, so at most
            // one can run — hence the chain rather than independent checks.
            LaunchTiming.phase("first_rows_task")
            model.markFirstRowsVisible()
            CaptureProbe.announce(model: model)
            if SettingsRedesignProbe.active {
                SettingsRedesignProbe.run(model: model)
            } else if JumpProbe.active {
                JumpProbe.run(model: model)
            } else if JumpStepProbe.active {
                JumpStepProbe.run(model: model)
            } else if LandingStallProbe.active {
                LandingStallProbe.run(model: model)
            } else if FindProbe.active {
                FindProbe.run(model: model)
            } else if HeaderToggleProbe.active {
                HeaderToggleProbe.run(model: model)
            } else if SelectCopyProbe.active {
                SelectCopyProbe.run(model: model)
            } else if StreamCopyOutcomeProbe.active {
                StreamCopyOutcomeProbe.run()
            } else if ConfigRepaintProbe.active {
                ConfigRepaintProbe.run(model: model)
            } else if FilterRepaintProbe.active {
                FilterRepaintProbe.run(model: model)
            } else if FindEscapeProbe.active {
                FindEscapeProbe.run(model: model)
            } else if RepaintAuditProbe.active {
                RepaintAuditProbe.run(model: model)
            } else if MatchFlagsFetchProbe.active {
                MatchFlagsFetchProbe.run(model: model)
            } else if FrameDump.liveGridInitialDumpPath == nil {
                // Overlay, find and settings scenes render off the SwiftUI mirror
                // here; the plain grid scene self-captures the LIVE table instead.
                FrameDump.dumpIfRequested(for: model)
                FrameDump.terminateIfRequested()
            }
        }
    }

    /// Clearance on each side of the centered title, so it never overlaps the
    /// traffic lights. Symmetric, because the title is centered.
    private static let titleTrafficLightReserve: CGFloat = 78

    private var windowTitle: String {
        if case .document = model.phase, !model.path.isEmpty {
            // A network document shows its URL as-is; a local file its basename.
            if model.currentOpenKind == .network { return model.path }
            return (model.path as NSString).lastPathComponent
        }
        return "LessSheet"
    }
}
