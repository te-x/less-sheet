import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the network open funnel (`openURL`) and the shared
// session-adoption tail (`adoptSession`) reached by both the local and network
// funnels. Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    /// Open a CSV / .csv.gz served over HTTP(S) (ARCH-network-source req 9) —
    /// the network analog of `open(path:)`, parallel and additive. Drives the
    /// core's async open-job via `DocumentSessionOpening.openURL`, shows the URL
    /// as-is in the title with no recents entry, and never emits the cold-start
    /// marker (AC10 — `currentOpenKind == .network`). A disallowed scheme is
    /// rejected synchronously as `.invalidArgument`, no network. `carrying`
    /// mirrors `open(path:forcing:carrying:)`'s column-visibility carry-over —
    /// a dialect change (separator/quote/header/encoding) on a network document
    /// re-opens the SAME url through this same funnel, not the local one.
    func openURL(
        _ url: String, forcing override: DialectOverride = .sniffAll, carrying previous: ColumnVisibility? = nil
    ) async {
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
        // A fresh cancel token per open (round-2 review finding 1): `cancelNetworkOpen()`
        // signals THIS token; a superseded/earlier open's stale token, if fired
        // late, no longer matches `networkCancelToken` and is a no-op below.
        let token = NetworkOpenCancelToken()
        networkCancelToken = token
        do {
            let candidate = try await fetchNetworkCandidate(url: url, forcing: override, token: token)
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
            // `openURL` is a typed throw (NetworkOpenError only).
            networkOpenProgress = nil
            networkCancelToken = nil
            if previous != nil, oldSession != nil {
                // Mirror open(path:)'s carry-over failure handling: keep the
                // old session alive rather than tearing down a working
                // document just because a dialect re-open over the network
                // failed (transient network error, server hiccup, etc.).
                self.session = oldSession
                self.currentOpenKind = .network
                startPolling()
                return
            }
            networkOpenError = error
            oldSession?.close()
            self.session = nil
            // The network taxonomy has no DocumentOpenError analogue; surface the
            // fact through the failure panel with a stable code, the distinct
            // detail via `networkOpenError` — `ContentView` renders a
            // `NetworkErrorPanel` from it instead of the generic one (AC7 /
            // round-2 review finding 2: each of the 7 cases gets its own text).
            self.phase = .failure(.ioFailure, path: url)
        }
        openGeneration += 1
        NativeGridController.live?.apply()
    }

    /// Drives the core's network open-job: the tracking overload (live progress
    /// snapshots + explicit cancel token) when the opener is a `CoreSessionOpener`,
    /// else the plain protocol open. Extracted from `openURL` verbatim.
    private func fetchNetworkCandidate(
        url: String, forcing override: DialectOverride, token: NetworkOpenCancelToken
    ) async throws(NetworkOpenError) -> any DocumentSession {
        if let core = opener as? CoreSessionOpener {
            // The tracking overload: reports a LIVE snapshot every poll tick,
            // driving the always-visible progress affordance from t0 (AC9),
            // and honors `cancelToken` for the UI's explicit Cancel button.
            return try await core.openURL(url, forcing: override, onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.networkCancelToken === token else { return }
                    self.networkOpenProgress = progress
                }
            }, cancelToken: token)
        }
        return try await opener.openURL(url, forcing: override)
    }

    /// Cancel the in-flight network open (round-2 review finding 1 — the
    /// affordance's Cancel button). No-op once the open has already settled
    /// (`networkCancelToken` is cleared as soon as `openURL` returns/throws).
    func cancelNetworkOpen() {
        networkCancelToken?.cancel()
    }

    /// The bundled inputs to `adoptSession` (was a 9-parameter call): the
    /// session-adoption tail shared by the local and network open funnels.
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

    /// The session-adoption tail shared by the local `open(path:)` and the
    /// network `openURL(_:)` funnels: closes the old handle, installs the new
    /// session, and resets all per-document view state. `kind` records whether
    /// this open is local or network (AC10 marker policy / window title).
    func adoptSession(_ adoption: SessionAdoption) {
        self.currentOpenKind = adoption.kind
        adoption.oldSession?.close()
        let session = adoption.candidate
        self.session = adoption.candidate
        self.path = adoption.path
        self.columnCount = session.columnCount
        self.dialect = session.dialect
        // New document identity: a different file/dialect can present the
        // SAME window geometry (e.g. a re-open at firstRow 0 with a matching
        // column count), so bump the mask's content epoch — otherwise a stale
        // key would short-circuit and serve the previous document's mask over
        // the new rows until a scroll self-healed it.
        invalidateMatchFlags()
        if session is CoreDocumentSession {
            // Do not touch the compatibility `headerCells` property here:
            // it intentionally materializes all labels for legacy callers.
            self.headerCells = session.dialect.hasHeader ? [] : nil
        } else {
            self.headerCells = session.headerCells
        }
        resetColumnCaches()
        self.rowCountInfo = session.rowCount()
        self.indexProgress = session.indexProgress()
        applyReopenLifecycle(session: session, reopenDecision: adoption.reopenDecision)
        applyAdoptedVisibility(session: session, adoption: adoption)
        // The horizontal window is a function of the widths this open is
        // about to establish; it resets here and the grid re-derives it
        // from its (possibly unchanged) viewport on the next layout pass.
        self.columnWindow = ColumnWindow(first: 0, count: 0, firstX: 0)
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
        // Hidden-column state: carry across a re-open when the column count
        // is unchanged, else reset to all-visible (ARCH req. 10).
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
        // New document identity: the core's search AND filter state died
        // with the old handle — clear results/highlights, retain the typed
        // query so re-running is one Enter (ARCH req. 10;
        // FindControlling.invalidated); a fresh/re-opened session has no
        // filter either (ARCH-filtered-views req. 9).
        self.cancelWrapNav()
        self.userStopped = false   // new document identity — drop any stop latch
        self.findSession = findControl.invalidated(self.findSession)
        self.searchNavDirection = .forward
        self.filterSnapshot = nil
        self.filterDocumentRows = nil
        self.filterScanStartedAt = nil
        self.pendingScrollRow = nil
        // Session-scoped select-copy state dies with the old handle too
        // (ARCH-select-copy): row/column indices from a prior document are
        // meaningless here. `cancelCopy` already ran at the TOP of the open,
        // BEFORE the old handle closed (round-4 UAF fix) — by now there is
        // nothing left to cancel, only this leftover selection state to clear.
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
