import AppKit
import Contracts
import Foundation
import SwiftUI

// The sort slice's frame-dump scenes, split out of FrameDumpScenes.swift to keep
// each file within the length budget. Both force a sort PHASE on a detached
// snapshot model rather than racing a real pass, so the capture is deterministic.
extension FrameDump {
    /// A sort in a chosen PHASE over the grid: the overlay's sort banner in its
    /// building (progress + Cancel) or failed (error + retry target) presentation.
    /// The phase is forced rather than raced, so the capture is deterministic.
    @MainActor
    static func sortScene(_ model: DocumentModel, phase: SortPhase) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, expandedPill: nil, jumpFlow: .idle,
            sortSnapshot: SortSnapshot(phase: phase, column: 0, direction: .ascending)
        )
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }

    /// The slow-sorted-window state: the loading capsule that stands in for the
    /// seconds a sorted `.csv.gz` window costs, so it is verifiable off-screen.
    @MainActor
    static func sortLoadingScene(_ model: DocumentModel) -> some View {
        let snapshot = DocumentModel.dumpSnapshot(
            from: model, expandedPill: nil, jumpFlow: .idle,
            sortSnapshot: SortSnapshot(phase: .active, column: 0, direction: .ascending)
        )
        snapshot.windowLoading = true
        return ZStack(alignment: .bottomTrailing) {
            DumpGrid(model: model)
            OverlayView(model: snapshot)
        }
        .environment(\.overlayDumpChrome, true)
    }
}
