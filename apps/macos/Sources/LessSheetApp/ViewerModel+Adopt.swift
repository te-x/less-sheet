import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The network open funnel, the session-adoption tail both funnels share, and
// the launch document's prewarmed open (which enters that same tail).

extension DocumentModel {
    /// Opens a CSV or .csv.gz served over HTTP(S) — the network twin of
    /// `open(path:)`. Shows the URL as-is in the title, keeps no recents entry,
    /// and never emits the cold-start marker: no budget applies to a network
    /// open. A disallowed scheme is rejected synchronously, with no network at
    /// all. A dialect change on a network document re-opens the SAME url through
    /// here, never through the local funnel.
    func openURL(
        _ url: String, forcing override: DialectOverride = .sniffAll, carrying previous: ColumnVisibility? = nil
    ) async {
        openRequestSequence += 1
        let request = openRequestSequence
        await stopPolling()
        cancelCopy()
        let oldSession = session
        let oldDialect = dialect
        let authoredSettings = columnUserSettings
        let authoredManualWidths = manualColumnWidths
        networkOpenError = nil
        networkOpenProgress = NetworkOpenProgress(
            state: .pending, fraction: nil, bytesFetched: 0, bytesTotal: 0, error: nil
        )
        currentOpenKind = .network
        // A fresh token per open, so a late fire from a superseded one no longer
        // matches `networkCancelToken` and is a no-op.
        let token = NetworkOpenCancelToken()
        networkCancelToken = token
        do {
            let candidate = try await fetchNetworkCandidate(url: url, forcing: override, token: token)
            guard request == openRequestSequence else { candidate.close(); return }
            networkOpenProgress = nil
            networkCancelToken = nil
            guard let resolved = resolveReopen(
                candidate: candidate, oldSession: oldSession, oldDialect: oldDialect,
                previous: previous, authoredSettings: authoredSettings
            ) else {
                candidate.close()
                startPolling()
                return
            }
            adoptSession(SessionAdoption(
                candidate: candidate, path: url, kind: .network, previous: previous,
                replayAuthoredSettings: resolved.replayAuthoredSettings,
                reopenDecision: resolved.reopenDecision, oldSession: oldSession,
                authoredSettings: authoredSettings, authoredManualWidths: authoredManualWidths
            ))
        } catch {
            guard request == openRequestSequence else { return }
            failNetworkOpen(error, url: url, previous: previous, oldSession: oldSession)
        }
        openGeneration += 1
        NativeGridController.live?.apply()
    }

    /// A network open that threw. A dialect re-open keeps the working document
    /// rather than tearing it down over a transient network error, mirroring
    /// `open(path:)`'s carry-over branch; a first open surfaces the failure
    /// panel. `phase` is `DocumentOpenError`-typed (frozen) and the network
    /// taxonomy has no analogue, so the distinct detail rides in
    /// `networkOpenError`, which `ContentView` renders as a `NetworkErrorPanel`.
    private func failNetworkOpen(
        _ error: NetworkOpenError, url: String,
        previous: ColumnVisibility?, oldSession: (any DocumentSession)?
    ) {
        networkOpenProgress = nil
        networkCancelToken = nil
        if previous != nil, let oldSession {
            self.session = oldSession
            self.currentOpenKind = .network
            startPolling()
            return
        }
        networkOpenError = error
        oldSession?.close()
        self.session = nil
        self.phase = .failure(.ioFailure, path: url)
    }

    /// The tracking overload when the opener is the real one, so the affordance
    /// gets live progress and an explicit cancel; otherwise the plain protocol
    /// open (a test double).
    private func fetchNetworkCandidate(
        url: String, forcing override: DialectOverride, token: NetworkOpenCancelToken
    ) async throws(NetworkOpenError) -> any DocumentSession {
        if let core = opener as? CoreSessionOpener {
            return try await core.openURL(url, forcing: override, onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.networkCancelToken === token else { return }
                    self.networkOpenProgress = progress
                }
            }, cancelToken: token)
        }
        return try await opener.openURL(url, forcing: override)
    }

    /// The affordance's Cancel button. A no-op once the open has settled.
    func cancelNetworkOpen() {
        networkCancelToken?.cancel()
    }

    /// Adopts the launch document's prewarmed open: `open(path:)`'s fresh-open
    /// tail with everything that cannot apply at launch removed.
    ///
    /// The shortcut is safe only on a virgin launch — no prior session to close,
    /// no poll to stop, no copy to cancel, no visibility to replay, no re-open
    /// decision — so the guard below PROVES that state rather than assuming it.
    func adoptLaunchOpen(_ outcome: Result<any DocumentSession, DocumentOpenError>, path: String) {
        guard session == nil, phase == .launch else {
            // Something already opened a document — a multi-document launch whose
            // second path took the normal funnel and won. The prewarm loses.
            if case let .success(candidate) = outcome { candidate.close() }
            return
        }
        switch outcome {
        case let .success(candidate):
            adoptSession(SessionAdoption(
                candidate: candidate, path: path, kind: .local, previous: nil,
                replayAuthoredSettings: false, reopenDecision: nil, oldSession: nil,
                authoredSettings: [:], authoredManualWidths: [:]
            ))
        case let .failure(error):
            self.session = nil
            self.phase = .failure(error, path: path)
        }
        openGeneration += 1
        // A guarded no-op at launch (no grid yet), kept so the two adoption tails
        // stay shape-identical and cannot drift apart.
        NativeGridController.live?.apply()
        if SettingsRedesignProbe.active {
            DispatchQueue.main.async {
                AppDelegate.shared?.runSettingsProbeAfterFirstPaint(model: self)
            }
        }
    }

    /// The bundled inputs to `adoptSession`.
    struct SessionAdoption {
        let candidate: any DocumentSession
        let path: String
        let kind: DocumentOpenKind
        let previous: ColumnVisibility?
        let replayAuthoredSettings: Bool
        let reopenDecision: ColumnReopenDecision?
        let oldSession: (any DocumentSession)?
        let authoredSettings: [Int: ColumnUserSettings]
        let authoredManualWidths: [Int: Double]
    }

    /// Closes the old handle, installs the new session, and resets every piece
    /// of per-document view state.
    func adoptSession(_ adoption: SessionAdoption) {
        self.currentOpenKind = adoption.kind
        adoption.oldSession?.close()
        let session = adoption.candidate
        self.session = adoption.candidate
        self.path = adoption.path
        self.columnCount = session.columnCount
        self.dialect = session.dialect
        // A different document can present the SAME window geometry — a re-open
        // at row 0 with a matching column count — so the mask's content epoch
        // must move or a stale key would serve the old mask over the new rows.
        invalidateMatchFlags()
        if session is CoreDocumentSession {
            // Never read `headerCells` on a core session: it materializes one
            // String per column.
            self.headerCells = session.dialect.hasHeader ? [] : nil
        } else {
            self.headerCells = session.headerCells
        }
        resetColumnCaches()
        self.rowCountInfo = session.rowCount()
        self.indexProgress = session.indexProgress()
        applyReopenLifecycle(session: session, reopenDecision: adoption.reopenDecision)
        applyAdoptedVisibility(session: session, adoption: adoption)
        // The horizontal window is a function of the widths this open is about to
        // establish; the grid re-derives it on the next layout pass.
        setColumnWindow(ColumnWindow(first: 0, count: 0, firstX: 0))
        establishInitialWindow(session: session)
        self.setJumpFlow(.idle)
        resetFindFilterSelectionState()
        applyAdoptedManualWidths(adoption: adoption)
        self.phase = .document
        startPolling()
    }

    private func resetColumnCaches() {
        self.windowColumnLabels = [:]
        self.windowTruncatedLabels = []
        self.windowColumnMetadata = [:]
        self.gridInferenceIDs = []
        self.panelInferenceIDs = []
        self.panelSelectedColumn = nil
        self.panelLabels = [:]
        self.panelMetadata = [:]
        self.panelFetchTask?.cancel()
        self.panelFetchTask = nil
        self.columnMetadataGeneration = 0
        self.columnInferenceProgress = nil
        self.columnPresentationRevision += 1
    }

    private func applyReopenLifecycle(session: any DocumentSession, reopenDecision: ColumnReopenDecision?) {
        if let reopenDecision {
            self.settingsLifecycle = SettingsLifecycleReducer().parsingReopened(
                self.settingsLifecycle, decision: reopenDecision, columnCount: session.columnCount
            )
        } else {
            self.settingsLifecycle = SettingsLifecycleReducer().documentOpened(columnCount: session.columnCount)
        }
        self.settingsDiscoveryRows = []
        if self.settingsOpen {
            self.panelSelectedColumn = self.settingsLifecycle.selection.flatMap(UInt32.init(exactly:))
        }
    }

    private func applyAdoptedVisibility(session: any DocumentSession, adoption: SessionAdoption) {
        // Hidden columns carry across a re-open when the column count is
        // unchanged, and reset to all-visible otherwise.
        if let previous = adoption.previous, adoption.replayAuthoredSettings {
            setVisibility(visibilityManager.carriedOver(previous, toColumnCount: session.columnCount))
        } else {
            setVisibility(visibilityManager.allVisible(columnCount: session.columnCount))
            self.columnUserSettings = [:]
            if adoption.previous == nil { self.sessionLocale = .current }
            if adoption.previous == nil { self.pendingHeaderShift = nil } // a fresh open never re-anchors
        }

        // Verification-only: pre-hide columns (comma-separated indices) so a
        // headless dump can show hidden-column reflow. Absent in normal use.
        if adoption.previous == nil, let raw = ProcessInfo.processInfo.environment["LESSSHEET_HIDE_COLS"] {
            for token in raw.split(separator: ",") {
                if let column = Int(token.trimmingCharacters(in: .whitespaces)) {
                    setVisibility(visibilityManager.toggling(self.visibility, column: column))
                }
            }
        }
    }

    private func establishInitialWindow(session: any DocumentSession) {
        // First window from the top; frozen column widths from that head
        // sample (O(head), measured once for the session).
        self.firstVisibleRow = 0
        self.lastVisibleCount = 40   // sensible default until the first geometry callback
        materialize(start: 0, count: GridMetrics.scrollBufferRows)
        // The header width must be part of the column widths AT OPEN, not
        // applied by a later refine that races the first-paint marker —
        // otherwise it pops in on the user's first interaction (a top-edge
        // scroll bounce, say). The real header labels are already available:
        // the `materialize` above ran `refreshWindowLabels`, fetching them
        // synchronously into `windowColumnLabels` for the just-fetched column
        // range (core sessions); a legacy session carries them in
        // `headerCells`. Feed those to the measurement so it sizes each
        // header in the semibold font it is drawn in.
        self.columnWidths = Self.measureColumnWidths(
            headerLabels: openHeaderLabels(for: session),
            sample: window.rows,
            columnCount: session.columnCount
        )
        markLayoutWidthsStale()
    }

    private func resetFindFilterSelectionState() {
        // The core's search and filter state died with the old handle. Results
        // and highlights go; the typed query stays, so re-running is one Enter.
        self.cancelWrapNav()
        self.userStopped = false
        self.findSession = findControl.invalidated(self.findSession)
        self.searchNavDirection = .forward
        self.filterSnapshot = nil
        self.filterDocumentRows = nil
        self.filterScanStartedAt = nil
        self.pendingScrollRow = nil
        // Row/column indices from the previous document are meaningless here.
        // The copy itself was already cancelled at the top of the open, before
        // the old handle closed.
        self.selection = nil
    }

    private func applyAdoptedManualWidths(adoption: SessionAdoption) {
        if !adoption.replayAuthoredSettings {
            self.manualColumnWidths = [:]
            self.columnUserSettings = [:]
        } else {
            self.manualColumnWidths = adoption.authoredManualWidths
            self.columnUserSettings = adoption.authoredSettings
        }
    }
}
