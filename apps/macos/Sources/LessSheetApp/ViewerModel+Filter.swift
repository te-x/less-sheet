import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// Filtered views: the banner and progress derivation, and the apply / clear
// transitions that swap the row coordinate space.

extension DocumentModel {
    /// A nil poll snapshot means the identity view.
    var isFiltered: Bool { filterSnapshot != nil }

    /// The "Filtered — N of M rows" banner, or nil for the identity view.
    var filterBanner: FilterBanner? {
        filterControl.banner(filterSnapshot, documentRows: filterDocumentRows ?? rowCountInfo)
    }

    /// The filter scan's delayed-progress indication, through the same gate copy
    /// and jump use. Never offers cancel: a filter is a standing view mode, not a
    /// one-shot operation.
    var filterProgressIndication: ProgressIndication {
        guard let banner = filterBanner, banner.progress != nil, let startedAt = filterScanStartedAt else {
            return progressGate.indication(for: .settled)
        }
        return progressGate.indication(for: .running(elapsed: progressClock.now - startedAt, cancellable: false))
    }

    /// What the jump popup hints with. While filtered the jump box interprets
    /// ORIGINAL row numbers, so its hint is scaled to the whole document rather
    /// than the filtered view.
    var jumpRowCountInfo: RowCountInfo { isFiltered ? (filterDocumentRows ?? rowCountInfo) : rowCountInfo }

    /// An unknown-length network stream reports its row count as a converging
    /// LOWER bound ("≥N rows"), not the usual projection. Local documents and
    /// known-total network ones never set the sentinel this reads.
    var documentTotalUnknown: Bool { !isFiltered && indexProgress.bytesTotal == .max }

    /// Whether the current find draft composes into something filterable. The
    /// same compose the apply path uses, so the toggle can never enable a filter
    /// the apply would reject.
    var canApplyFilter: Bool {
        if case .ignored = findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
            return false
        }
        return true
    }

    /// "Filter to matches": validates the current find draft exactly as Find
    /// does — identical grammar, no separate predicate UI — then routes it to
    /// `setFilter` instead of `startSearch`. Entering filtered mode resets any
    /// active find, since the row coordinate space just changed.
    func applyFindAsFilter() {
        switch findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
        case .ignored:
            break
        case .rejected:
            findRejections += 1
            if FindProbe.active { FindProbe.rejected(model: self) }
        case let .run(request):
            guard let session else { return }
            // The base document count is captured from the IDENTITY view once,
            // the moment filtering begins: while already filtered the session
            // reports the filtered count and it is no longer knowable.
            let capturedDocumentRows = isFiltered ? filterDocumentRows : rowCountInfo
            guard session.setFilter(request) else {
                findRejections += 1
                if FindProbe.active { FindProbe.rejected(model: self) }
                return
            }
            filterDocumentRows = capturedDocumentRows
            // A content swap that can keep an identical window geometry.
            invalidateMatchFlags()
            cancelWrapNav()
            userStopped = false
            findSession = findControl.invalidated(findSession)
            searchNavDirection = .forward
            setJumpFlow(.idle)
            selection = nil   // the row coordinate space just changed
            filterSnapshot = session.filterStatus()
            filterScanStartedAt = progressClock.now
            rowCountInfo = session.rowCount()
            landViewport(on: 0)
            startPolling()
            // Applying a filter while already at the top produces no scroll, so
            // the landing carries no repaint and AppKit would defer the redraw
            // until the next event — the filter would only appear after a scroll.
            NativeGridController.live?.apply()
        }
    }

    /// Clears the active filter and restores the identity view, re-anchoring on
    /// the source row of the top visible filtered row rather than jumping to the
    /// top.
    func clearFilter() {
        guard let session, isFiltered else { return }
        // Capture the re-anchor row BEFORE clearing, while the filtered
        // coordinate space still holds: make the top visible row servable, then
        // read its original number.
        _ = session.setWindow(firstRow: UInt64(firstVisibleRow), rowCount: 1)
        let anchor = session.sourceRow(UInt64(firstVisibleRow)) ?? 0
        session.clearFilter()
        invalidateMatchFlags()
        filterSnapshot = nil
        filterDocumentRows = nil
        filterScanStartedAt = nil
        rowCountInfo = session.rowCount()
        cancelWrapNav()
        userStopped = false
        findSession = findControl.invalidated(findSession)
        searchNavDirection = .forward
        setJumpFlow(.idle)
        selection = nil   // the row coordinate space just changed
        landViewport(on: anchor)
        startPolling()
        // The re-anchor may land the same visible row, in which case the landing
        // carries no repaint (see `applyFindAsFilter`).
        NativeGridController.live?.apply()
    }
}
