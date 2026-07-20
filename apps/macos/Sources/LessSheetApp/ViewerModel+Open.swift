import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the local open funnel and dialect-change routing. The network
// funnel + the shared session-adoption tail live in ViewerModel+Adopt.swift.
// Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    // MARK: - Opening (single funnel)

    /// The one open path shared by panel / launch / CLI / drag. `forcing`
    /// defaults to sniff-all (a fresh open); dialect re-opens pass a composed
    /// override and carry the caller's prior column visibility.
    func open(
        path: String, forcing override: DialectOverride = .sniffAll, carrying previous: ColumnVisibility? = nil
    ) async {
        await stopPolling()
        // Cancel any in-flight copy against the OLD handle BEFORE closing it
        // (round-4 UAF fix): an orphaned copy build keeps calling
        // `session.copyCell` from a detached Task after `cancelCopy` merely
        // asks it to stop, so the handle must still be open while that ask
        // lands — closing first left a window where the orphaned build could
        // call `ls_cell_copy` on an already-freed `doc`.
        cancelCopy()
        let oldSession = session
        let oldDialect = dialect
        let authoredSettings = columnUserSettings
        let authoredManualWidths = manualColumnWidths

        do {
            let candidate = try await opener.open(path: path, forcing: override)
            guard let resolved = resolveReopen(
                candidate: candidate, oldSession: oldSession, oldDialect: oldDialect,
                previous: previous, authoredSettings: authoredSettings
            ) else {
                candidate.close()
                startPolling()
                return
            }
            adoptSession(SessionAdoption(
                candidate: candidate, path: path, kind: .local, previous: previous,
                replayAuthoredSettings: resolved.replayAuthoredSettings,
                reopenDecision: resolved.reopenDecision, oldSession: oldSession,
                authoredSettings: authoredSettings, authoredManualWidths: authoredManualWidths
            ))
        } catch {
            if previous != nil, oldSession != nil {
                self.session = oldSession
                startPolling()
            } else {
                oldSession?.close()
                self.session = nil
                self.phase = .failure(error, path: path)
            }
        }
        openGeneration += 1
        // Cross-window poke (same bridge as the column-config mutators): a
        // dialect re-open driven from the separate (key) Settings window — or
        // a header toggle whose observation turn gets coalesced — must reach
        // the grid's openGeneration branch NOW, not on the next interaction.
        // Without it the sticky header and the top rows keep the pre-toggle
        // content until a scroll repages them ("header only changes once I
        // scroll down and up"). Idempotent; on first launch the grid isn't
        // built/attached yet and the call is a guarded no-op.
        NativeGridController.live?.apply()
        if SettingsRedesignProbe.active {
            DispatchQueue.main.async {
                AppDelegate.shared?.runSettingsProbeAfterFirstPaint(model: self)
            }
        }
    }

    /// Decides how a re-open (dialect change) should treat the PRIOR session's
    /// column settings — shared by the local `open(path:)` and network
    /// `openURL(_:)` funnels so a separator/quote/header/encoding change
    /// behaves identically regardless of document kind. Returns nil when the
    /// authored-settings replay itself failed (the caller must restore the
    /// OLD session and abort the re-open, exactly as `open(path:)` did inline
    /// before this was extracted).
    func resolveReopen(
        candidate: any DocumentSession, oldSession: (any DocumentSession)?, oldDialect: DialectReport,
        previous: ColumnVisibility?, authoredSettings: [Int: ColumnUserSettings]
    ) -> (replayAuthoredSettings: Bool, reopenDecision: ColumnReopenDecision?)? {
        guard previous != nil, let oldSession else { return (false, nil) }
        let headerOnly = oldDialect.separator == candidate.dialect.separator
            && oldDialect.quote == candidate.dialect.quote
            && oldDialect.encoding == candidate.dialect.encoding
        let change: ColumnReopenChange = headerOnly ? .headerOnly : .separatorQuoteEncoding
        let oldHeaders = change == .separatorQuoteEncoding ? Self.headerIdentities(oldSession) : nil
        let newHeaders = change == .separatorQuoteEncoding ? Self.headerIdentities(candidate) : nil
        let decision = ColumnSessionModel().decide(
            change: change, oldCount: oldSession.columnCount, newCount: candidate.columnCount,
            oldHeaders: oldHeaders, newHeaders: newHeaders
        )
        let replayAuthoredSettings = decision == .replayOrdinally

        if replayAuthoredSettings, let core = candidate as? CoreDocumentSession {
            for (column, setting) in authoredSettings {
                guard let id = UInt32(exactly: column),
                      core.setColumnOverride(setting.overrideType, column: id),
                      core.setColumnNullSentinel(setting.nullSentinel, column: id) else {
                    return nil
                }
            }
        }
        return (replayAuthoredSettings, decision)
    }

    static func headerIdentities(_ session: any DocumentSession) -> [ColumnHeaderIdentity]? {
        guard session.dialect.hasHeader else { return nil }
        if let core = session as? CoreDocumentSession {
            var identities = [ColumnHeaderIdentity]()
            identities.reserveCapacity(session.columnCount)
            var start = 0
            while start < session.columnCount {
                let end = min(session.columnCount, start + columnLabelSearchBatchMax)
                let values = core.columnLabels((start..<end).map { UInt32($0) })
                guard values.count == end - start else { return nil }
                identities.append(contentsOf: values.map { $0 ?? ColumnHeaderIdentity(bytes: [], truncated: false) })
                start = end
            }
            return identities
        }
        guard let headers = session.headerCells, headers.count == session.columnCount else { return nil }
        return headers.map { ColumnHeaderIdentity(bytes: Array($0.utf8), truncated: false) }
    }

    /// Re-open the current document with one dialect parameter changed
    /// (popup / Settings edit). Returns false — with no re-open — when the
    /// selection is invalid (`DialectComposing` rejected it).
    @discardableResult
    func applyDialectChange(_ change: DialectChange) -> Bool {
        guard case .document = phase, let override = composer.compose(from: dialect, changing: change) else {
            return false
        }
        let path = self.path
        let carried = self.visibility
        // A header toggle preserves the viewport: record how the data-row index
        // shifts so the grid can re-anchor to the same file record across the
        // re-open (it captures its own exact top row from the live scroll, so we
        // only pass the ±1 shift). A separator/quote change resets to the top.
        if case let .header(newValue) = change {
            pendingHeaderShift = (newValue == dialect.hasHeader) ? 0 : (newValue ? -1 : +1)
            // The H button toggles with no popup or text of its own — surface
            // what just changed (same vocabulary as the button's tooltip).
            showDialectNotice(newValue ? "First row is now a header" : "First row is now data")
        } else {
            pendingHeaderShift = nil
        }
        // A network document must re-open through the SAME (network) funnel:
        // `path` holds its URL, not a filesystem path, so routing it through
        // `open(path:)` would try to ls_open the URL string as a local file
        // and silently fail back to the old session — this was a real bug
        // (separator/quote/header changes on a network doc did nothing).
        if currentOpenKind == .network {
            Task { await self.openURL(path, forcing: override, carrying: carried) }
        } else {
            Task { await self.open(path: path, forcing: override, carrying: carried) }
        }
        return true
    }

    /// Raises the brief dialect notice and schedules its auto-clear —
    /// exactly `completeCopy`'s notice lifecycle (a fresh notice supersedes
    /// a still-fading one by cancelling its task first).
    private func showDialectNotice(_ text: String) {
        dialectNoticeTask?.cancel()
        dialectNotice = text
        dialectNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled else { return }
            self.dialectNotice = nil
        }
    }

    /// The grid reads (and clears) the pending header-toggle shift when it handles
    /// a re-open, to decide whether to re-anchor the viewport (header toggle) or
    /// rest at the top-left (every other open). Returns nil when there is none.
    func consumePendingHeaderShift() -> Int? {
        defer { pendingHeaderShift = nil }
        return pendingHeaderShift
    }

    func closeDocument() {
        // cancelCopy() BEFORE close() — same round-4 UAF fix as `open()`: an
        // orphaned copy must stop touching the handle before it's freed.
        Task { await stopPolling(); cancelCopy(); session?.close(); session = nil }
    }
}
