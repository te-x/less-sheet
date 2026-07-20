import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — filtered views (ARCH-filtered-views): the banner + progress
// derivation, and the apply / clear transitions that swap the row coordinate
// space. Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    // MARK: - Filter (filtered-views)

    /// Whether a filter is the active view (ARCH-filtered-views FILTERED
    /// VIEWS) — a nil poll snapshot means the identity view.
    var isFiltered: Bool { filterSnapshot != nil }

    /// The "Filtered — N of M rows" banner, or nil for the identity view (ARCH
    /// req. 11, criterion 16).
    var filterBanner: FilterBanner? {
        filterControl.banner(filterSnapshot, documentRows: filterDocumentRows ?? rowCountInfo)
    }

    /// FILTER-scan's live delayed-progress indication (ARCH-stream-copy AC9
    /// "just wiring"): the SAME gate copy/jump use (`progressGate`), fed the
    /// real elapsed since THIS filter began. Hidden whenever the banner
    /// reports no progress (no filter active, or the scan is `.done`);
    /// visible with NO cancel otherwise — a filter is a persistent view mode,
    /// not a one-shot cancellable operation (ARCH: "Filter's indicator need
    /// not offer cancel"). `FilterBannerView` reads this to decide when its
    /// existing progress-bar + % surfaces (FilterBanner.swift).
    var filterProgressIndication: ProgressIndication {
        guard let banner = filterBanner, banner.progress != nil, let startedAt = filterScanStartedAt else {
            return progressGate.indication(for: .settled)
        }
        return progressGate.indication(for: .running(elapsed: progressClock.now - startedAt, cancellable: false))
    }

    /// The row-count knowledge the JUMP popup hints with: the captured base
    /// document count while filtered — the jump box interprets ORIGINAL row
    /// numbers (ARCH-filtered-views req. 7/12, criterion 17), so its hint must
    /// be scaled to the whole document, not the filtered view — else the
    /// (identity) `rowCountInfo` unchanged.
    var jumpRowCountInfo: RowCountInfo { isFiltered ? (filterDocumentRows ?? rowCountInfo) : rowCountInfo }

    /// never-full-download-streaming (AC12): an UNKNOWN-length network stream
    /// reports its row count as a converging LOWER BOUND — the frontend shows
    /// "≥N rows" rather than the "~N rows, estimating…" projection — keyed on the
    /// ls_index_poll UINT64_MAX bytes-total sentinel. Local docs and known-total
    /// network docs (Content-Length / Content-Range) never set it.
    var documentTotalUnknown: Bool { !isFiltered && indexProgress.bytesTotal == .max }

    /// Whether the current find draft composes into something filterable — the
    /// filter toggle is enabled to turn ON only when this is true (an empty
    /// draft yields `.ignored`). Pure check; same compose the apply path uses.
    var canApplyFilter: Bool {
        if case .ignored = findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
            return false
        }
        return true
    }

    /// "Apply as filter" (ARCH req. 10): validate the CURRENT find draft
    /// exactly as Find does (`FindControlling.submit` — identical grammar, no
    /// new predicate UI), then route a successful compose to `setFilter`
    /// instead of `startSearch`. Entering (or re-entering) filtered mode
    /// resets any active find app-side (the core resets it too — the
    /// coordinate space changed) and lands the grid on the top of the
    /// filtered view.
    func applyFindAsFilter() {
        switch findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
        case .ignored:
            break
        case .rejected:
            findRejections += 1
            if FindProbe.active { FindProbe.rejected(model: self) }
        case let .run(request):
            guard let session else { return }
            // M is captured from the IDENTITY view once, the moment filtering
            // begins; while already filtered (re-running / replacing the
            // active filter) the base document count is no longer knowable
            // through the session, so the earlier capture is kept.
            let capturedDocumentRows = isFiltered ? filterDocumentRows : rowCountInfo
            guard session.setFilter(request) else {
                // The composer already validated; a real rejection here would
                // mean the core disagrees (shouldn't happen — same rules as
                // Find). Surface it exactly like a Find rejection.
                findRejections += 1
                if FindProbe.active { FindProbe.rejected(model: self) }
                return
            }
            filterDocumentRows = capturedDocumentRows
            // The view now shows FILTERED rows — a content swap that can keep an
            // identical window geometry, so invalidate the mask epoch directly
            // (belt-and-suspenders with materialize's own bump on the landing).
            invalidateMatchFlags()
            cancelWrapNav()
            userStopped = false   // find is reset entering filter mode — drop any stop latch
            findSession = findControl.invalidated(findSession)
            searchNavDirection = .forward
            setJumpFlow(.idle)
            selection = nil   // the coordinate space just changed (ARCH-select-copy)
            filterSnapshot = session.filterStatus()
            // ARCH-stream-copy AC9 ("just wiring"): this filter's real start,
            // fed to `filterProgressIndication` — set unconditionally (even a
            // filter that resolves instantly on a tiny file is still "started
            // now"; the indication itself stays hidden whenever the banner
            // reports no progress, i.e. already `.done`).
            filterScanStartedAt = progressClock.now
            rowCountInfo = session.rowCount()
            landViewport(on: 0)
            startPolling()
            // Repaint the filtered view NOW. `landViewport` only schedules an
            // ASYNC landing apply; when the filter is applied while already at
            // the top (target row 0 == current), that apply produces no scroll
            // and AppKit defers the row/gutter redraw until the next event — the
            // reported "filter shows only after a scroll". The explicit
            // synchronous poke (the same fix the column-config mutators use) runs
            // apply() + flushGridDisplay in THIS turn. Grid-attached-guarded, so
            // it is a no-op headlessly-without-a-window / pre-first-paint.
            NativeGridController.live?.apply()
        }
    }

    /// Clear the active filter (the banner's ✕, or the Find popup's "Clear
    /// filter"), restoring the identity view. Re-anchors on the source row of
    /// the top visible filtered row (ARCH criterion 13) via the same
    /// materialize-then-scroll landing mechanics as a jump/find/header-toggle
    /// re-anchor. No-op when no filter is active.
    func clearFilter() {
        guard let session, isFiltered else { return }
        // Capture the re-anchor row BEFORE clearing (the coordinate space is
        // about to change): make sure the top visible row is servable, then
        // read its original row number.
        _ = session.setWindow(firstRow: UInt64(firstVisibleRow), rowCount: 1)
        let anchor = session.sourceRow(UInt64(firstVisibleRow)) ?? 0
        session.clearFilter()
        // Back to the identity view — another same-geometry-possible content
        // swap; invalidate the mask epoch (see applyFindAsFilter).
        invalidateMatchFlags()
        filterSnapshot = nil
        filterDocumentRows = nil
        filterScanStartedAt = nil
        rowCountInfo = session.rowCount()
        cancelWrapNav()
        userStopped = false   // find is reset clearing the filter — drop any stop latch
        findSession = findControl.invalidated(findSession)
        searchNavDirection = .forward
        setJumpFlow(.idle)
        selection = nil   // the coordinate space just changed (ARCH-select-copy)
        landViewport(on: anchor)
        startPolling()
        // Repaint the restored identity view NOW (see applyFindAsFilter): the
        // re-anchor may land the same visible row, so the async landing apply
        // alone can leave the filtered rows on screen until the next scroll.
        NativeGridController.live?.apply()
    }
}
