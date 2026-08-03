import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the overlay reveal/fade presentation, the cold-start timing
// marker, the headless dump snapshot, and the off-main progress poll loop.
// Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {

    /// The find match-scan is running (progress % showing) — its popup stays
    /// reachable (cancel affordance) independent of the click-away scrim.
    var findScanning: Bool { findSession.display.progress != nil }

    // MARK: - Overlay popups (single active popup; Esc / click-away dismiss)

    /// A dialect popup, the jump field, or the find field is open — drives the
    /// click-away scrim. A running scan keeps its popup up independently, so a
    /// scanning find field is excluded (like a running jump scan).
    var anyPopupOpen: Bool {
        expandedPill != nil || jumpFieldActive || (findFieldActive && !findScanning)
    }

    /// Dismiss the open dialect popup / jump field / find field (Esc or
    /// click-away). Closing the find popup clears its highlights (retaining the
    /// query). A running jump scan is left alone: its popup stays reachable.
    func dismissPopups() {
        expandedPill = nil
        jumpFieldActive = false
        if findFieldActive { closeFind() }
    }

    /// Open (or re-close) a dialect popup, closing the other popups so at most
    /// one is ever open at a time.
    func toggleExpandedPill(_ kind: PillKind) {
        expandedPill = (expandedPill == kind) ? nil : kind
        jumpFieldActive = false
        if findFieldActive { closeFind() }
    }

    /// Open the jump field, closing any dialect popup / the find field.
    func openJumpField() {
        jumpFieldActive = true
        expandedPill = nil
        if findFieldActive { closeFind() }
    }

    /// Open the find field, closing any dialect popup / the jump field.
    func openFindField() {
        findFieldActive = true
        expandedPill = nil
        jumpFieldActive = false
    }

    /// Keyboard reveal (⌘J): ask the jump field to open.
    func requestJumpFocus() {
        jumpFocusRequests += 1
    }

    /// Keyboard reveal (⌘F): ask the find field to open.
    func requestFindFocus() {
        findFocusRequests += 1
    }

    // MARK: - Timing marker

    /// Emits the cold-start marker for the first data-bearing frame of an open,
    /// exactly once per open generation. Error / empty frames never call this.
    func markFirstRowsVisible() {
        guard markedGeneration != openGeneration else { return }
        markedGeneration = openGeneration
        // AC10: a NETWORK open never emits the cold-start marker — the <500 ms
        // budget does not apply. Route through the frozen policy so the marker
        // still fires for local opens (regression-guarded).
        guard TimingMarker.emitsFirstRowsMarker(for: currentOpenKind) else { return }
        LaunchTiming.markFirstRowsVisible()
    }

    // MARK: - Dump snapshot (headless rendering of overlay/pill/progress states)

    /// A detached, session-less model carrying this document's facts + current
    /// window plus forced overlay state, for the `LESSSHEET_DUMP_FRAME` hook to
    /// render specific presentation states off-screen. It never opens or pages
    /// (no core session), so rendering it is side-effect-free.
    static func dumpSnapshot(
        from live: DocumentModel,
        expandedPill: PillKind?,
        jumpFlow: JumpFlow,
        jumpFieldActive: Bool = false,
        findSession: FindSession = FindControl().initial(),
        findFieldActive: Bool = false
    ) -> DocumentModel {
        let snapshot = DocumentModel(opener: live.opener)
        snapshot.path = live.path
        snapshot.columnCount = live.columnCount
        snapshot.headerCells = live.headerCells
        snapshot.windowColumnLabels = live.windowColumnLabels
        snapshot.windowColumnMetadata = live.windowColumnMetadata
        snapshot.dialect = live.dialect
        snapshot.columnWidths = live.columnWidths
        snapshot.window = live.window
        snapshot.rowCountInfo = live.rowCountInfo
        snapshot.indexProgress = live.indexProgress
        snapshot.setVisibility(live.visibility)
        snapshot.phase = .document
        snapshot.expandedPill = expandedPill
        snapshot.jumpFlow = jumpFlow
        snapshot.jumpFieldActive = jumpFieldActive
        snapshot.findSession = findSession
        snapshot.findFieldActive = findFieldActive
        return snapshot
    }

    /// Verification-only: page the live window to `startRow` before a headless
    /// dump so a grid dump can exhibit larger row numbers / the widened gutter
    /// (mirrors the `LESSSHEET_HIDE_COLS` pre-hide hook). Inert in normal use.
    func dumpMaterialize(startRow: UInt64) {
        firstVisibleRow = Int(min(startRow, UInt64(Int.max)))
        lastVisibleCount = 40
        materialize(start: startRow, count: 120)
    }

    /// Verification-only (MatchFlagsFetchProbe): re-materialize the CURRENT window
    /// with the SAME first row + row count, so the window geometry is byte-identical
    /// but a new materialization occurred (the content epoch bumps). Proves a
    /// same-geometry materialization still refetches the match-flags mask (AC5 /
    /// Round-2 finding 1 — geometry alone must not gate the cache). Inert in normal
    /// use. No-op with no session / empty window.
    func rematerializeSameWindowForProbe() {
        guard session != nil, !window.rows.isEmpty else { return }
        materialize(start: window.firstRow, count: window.rows.count)
    }

    // MARK: - Polling (off the main actor; stops when idle)

    func startPolling() {
        guard let session else { return }
        // Hand the new task the old one and let it cancel + join before polling,
        // so two poll loops never fold snapshots concurrently (the join happens
        // off the main actor; the prior task exits within one poll interval).
        let previous = pollTask
        pollTask = Task.detached(priority: .utility) { [weak self, session] in
            previous?.cancel()
            _ = await previous?.value
            while !Task.isCancelled {
                let rowCount = session.rowCount()
                let progress = session.indexProgress()
                let jump = session.jumpStatus()
                let search = session.searchStatus()
                let filter = session.filterStatus()
                let columns = (session as? CoreDocumentSession)?.columnInferenceState()
                let columnProgress = (session as? CoreDocumentSession)?.columnInferenceProgress()
                let keepGoing = await self?.applyPoll(PollSnapshot(
                    rowCount: rowCount, progress: progress, jump: jump, search: search,
                    filter: filter, columns: columns, columnProgress: columnProgress)) ?? false
                if !keepGoing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// One poll tick's snapshot (was a 7-parameter `applyPoll` call), built off
    /// the main actor and handed to `applyPoll` on it — hence `Sendable`.
    private struct PollSnapshot: Sendable {
        let rowCount: RowCountInfo
        let progress: ScanProgress
        let jump: JumpStatus
        let search: SearchSnapshot?
        let filter: FilterSnapshot?
        let columns: (active: Bool, generation: UInt64)?
        let columnProgress: Double?
    }

    /// Fold one poll snapshot into state; returns whether polling should
    /// continue (stops once the desired window is resolved and neither the
    /// index, a jump, a search, nor a filter-scan is active, so idle documents
    /// cost nothing).
    private func applyPoll(_ snapshot: PollSnapshot) -> Bool {
        rowCountInfo = snapshot.rowCount
        indexProgress = snapshot.progress
        filterSnapshot = snapshot.filter
        columnInferenceProgress = snapshot.columnProgress
        foldJump(snapshot.jump)
        foldSearch(snapshot.search)
        if let columns = snapshot.columns, columns.generation != columnMetadataGeneration,
           let core = session as? CoreDocumentSession {
            columnMetadataGeneration = columns.generation
            var changedColumns = Set<Int>()
            for metadata in core.columnMetadata(coordinatedInferenceIDs()) {
                if gridInferenceIDs.contains(UInt32(metadata.column)) {
                    if windowColumnMetadata[metadata.column] != metadata {
                        changedColumns.insert(metadata.column)
                    }
                    windowColumnMetadata[metadata.column] = metadata
                }
                if panelInferenceIDs.contains(UInt32(metadata.column))
                    || panelSelectedColumn == UInt32(metadata.column) {
                    if panelMetadata[metadata.column] != metadata {
                        changedColumns.insert(metadata.column)
                    }
                    panelMetadata[metadata.column] = metadata
                }
            }
            requestColumnConfigurationRedraw(changedColumns)
        }

        let filterOngoing = snapshot.filter.map { !$0.totalIsFinal } ?? false
        let jumpScanning: Bool = { if case .scanning = jumpFlow { return true } else { return false } }()
        let decision = windowPoll.decide(WindowPollInputs(
            window: desiredWindow,
            indexComplete: snapshot.progress.isComplete,
            jumpScanning: jumpScanning,
            searchActive: Self.searchActive(snapshot.search),
            filterOngoing: filterOngoing
        ))
        if decision.reissueWindow {
            materialize(start: desiredStart, count: desiredCount)
        }

        return decision.continuePolling || (snapshot.columns?.active ?? false)
    }

    /// A search still needs polling while its match-scan runs or a navigation
    /// is being served (counts grow / a landing is pending).
    private static func searchActive(_ snapshot: SearchSnapshot?) -> Bool {
        guard let snapshot else { return false }
        if case .scanning = snapshot.phase { return true }
        if case .searching = snapshot.nav { return true }
        return false
    }

    func stopPolling() async {
        pollTask?.cancel()
        await pollTask?.value      // ensure no poll runs concurrently with ls_close
        pollTask = nil
    }
}
