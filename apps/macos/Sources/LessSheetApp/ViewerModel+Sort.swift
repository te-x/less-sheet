import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// Sorted views (ARCH-sort-by-column, AC-s14, Amendments 1 and 3): the two
// triggers — ⇧⌘S (the CYCLE on the cursor's column) and the header CONTEXT MENU
// (three direct intents) — plus the affordance's Cancel, the transitions that
// swap the row coordinate space, the convergence pacing, and the banner /
// indicator derivations the chrome draws.
//
// Everything reads the poll snapshot the loop folds; nothing here keeps a
// second copy of the sort's state.

/// The two sorted-view pacing knobs, each declared ONCE and read in one place.
enum SortWindowTuning {
    /// How long one convergence SLICE may re-issue a short sorted window
    /// back-to-back before yielding a runloop turn. A cold sorted window on a
    /// wide document converges over hundreds of core-side re-issues (the backend
    /// cell measured ~290 over 571 ms of core work on 2000 x 626); pacing those
    /// at the 100 ms poll tick would take half a minute, so they run in slices
    /// instead. It is a CEILING on main-thread occupancy per runloop turn, not a
    /// duty cycle: a fetch is never interrupted, so a document whose single
    /// window fetch already costs more than the slice — the wide case, measured —
    /// gets exactly one fetch per turn.
    static let convergeSlice: Duration = .milliseconds(8)

    /// A materialize is treated as SLOW — worth showing a loading state before
    /// paying for it — once the previous one on this document took longer than
    /// this. A sorted `.csv.gz` window costs ~1.75 s per 50 rows (the signed
    /// ship-and-measure decision), and a silent multi-second freeze would break
    /// the standing >500 ms rule; a fast local sort never reaches this.
    static let slowWindow: Duration = .milliseconds(250)

    /// Rows of scroll buffer kept BEYOND the visible ones once a sorted window
    /// on this document has been measured slow. The normal buffer is
    /// `GridMetrics.scrollBufferRows * 2` (1200 rows), which is free when a row
    /// costs microseconds and is the whole wait when it costs milliseconds; past
    /// the threshold the request shrinks to what the user is actually looking at
    /// plus this, so one landing costs a fraction of what the full buffer would.
    static let slowWindowMargin = 20
}

extension DocumentModel {
    /// A nil poll snapshot means file order (within the current view).
    var isSorted: Bool { sortSnapshot != nil }

    /// A key pass is outstanding: the served top rows can change on any poll, so
    /// the grid re-reads its window rather than assuming a settled order, and the
    /// progress + Cancel affordance stays up.
    var sortIsWorking: Bool { sortSnapshot?.isWorking ?? false }

    /// The header cell state for `column` — `.none` for every column that is not
    /// the sort column.
    func sortIndicator(for column: Int) -> SortIndicator {
        sortCycle.indicator(sortSnapshot, for: column)
    }

    /// The header context menu's three stateful entries for `column`
    /// (Amendment 3). The view layer only renders these — titles, check marks
    /// and enablement are all decided by the frozen `SortCycling`.
    func sortMenu(for column: Int) -> [SortMenuEntry] {
        sortCycle.headerMenu(sortSnapshot, for: column)
    }

    // MARK: - The triggers (⇧⌘S cycles; the menu carries direct intents)

    /// Advance THE cycle on `column` — the body of ⇧⌘S.
    func cycleSort(column: Int) {
        guard session != nil, (0..<columnCount).contains(column) else { return }
        applySortIntent(sortCycle.next(sortSnapshot, for: column))
    }

    /// ⇧⌘S (and the View-menu item): the cycle on the KEYBOARD CURSOR's
    /// column — the selection anchor's column when a selection exists, else the
    /// leftmost column currently in view, which is where the cursor lands on the
    /// first arrow key.
    func cycleSortAtCursor() {
        guard columnCount > 0 else { return }
        let cursor = selection?.anchor.column ?? windowColumns().first ?? visibleColumns.first ?? 0
        cycleSort(column: cursor)
    }

    /// The ONE apply step behind both triggers: the cycle's next step and the
    /// context menu's chosen entry are the same `SortIntent` type, so neither
    /// surface can interpret a request differently from the other.
    func applySortIntent(_ intent: SortIntent) {
        switch intent {
        case let .sort(column, direction):
            applySort(column: column, direction: direction)
        case .clear:
            clearSort()
        }
    }

    /// The progress affordance's Cancel — deliberately the SAME verb as the
    /// cycle's "stop" arm (`ls_sort_clear` is both), so the two cannot drift.
    func cancelSort() {
        clearSort()
    }

    // MARK: - Transitions

    /// Sets (or replaces) the sort. The view is in SORTED coordinates the moment
    /// this returns and serves the converging prefix as soon as the core's pass
    /// commits its first chunk; the pass itself is observed by the poll loop.
    private func applySort(column: Int, direction: SortDirection) {
        guard let session else { return }
        guard session.setSort(column: column, direction: direction) else {
            // The core rejected it (an out-of-range column). Nothing changed.
            return
        }
        // The row coordinate space just changed — the filter precedent, with the
        // core doing the same reset on its side.
        viewGeneration += 1
        invalidateMatchFlags()
        cancelWrapNav()
        userStopped = false
        findSession = findControl.invalidated(findSession)
        searchNavDirection = .forward
        setJumpFlow(.idle)
        selection = nil
        sortSnapshot = session.sortStatus()
        rowCountInfo = session.rowCount()
        // Only the top K rows are servable while the pass runs, and the sorted
        // top is what a sort is FOR, so the viewport goes there.
        landViewport(on: 0)
        startPolling()
        // The first prefix lands a fraction of a millisecond after the request on
        // a local document; converging for it right away (in bounded slices)
        // means the first frame after a sort already carries rows rather than
        // waiting out a poll tick.
        scheduleSortConverge()
        // Sorting while already at the top produces no scroll, so the landing
        // carries no repaint and AppKit would defer the redraw (the
        // repaint-family rule — see `applyFindAsFilter`).
        NativeGridController.live?.apply()
    }

    /// Removes the sort — and cancels a running pass, which is the same call.
    /// Re-anchors on the row the user was looking at.
    func clearSort() {
        guard let session, isSorted else { return }
        // Capture the re-anchor row BEFORE clearing, while the sorted coordinate
        // space still holds. A row past the converging prefix has no source row
        // yet, in which case the top of the restored view is the honest answer.
        _ = session.setWindow(firstRow: UInt64(firstVisibleRow), rowCount: 1)
        let anchor = session.sourceRow(UInt64(firstVisibleRow)) ?? 0
        session.clearSort()
        viewGeneration += 1
        invalidateMatchFlags()
        sortSnapshot = nil
        cancelWrapNav()
        userStopped = false
        findSession = findControl.invalidated(findSession)
        searchNavDirection = .forward
        setJumpFlow(.idle)
        selection = nil
        rowCountInfo = session.rowCount()
        reanchor(onSourceRow: anchor)
        startPolling()
        NativeGridController.live?.apply()
    }

    /// Brings `sourceRow` — an ORIGINAL data-row number — back into view in
    /// whatever view mode is now active. In the IDENTITY view a source row IS
    /// the view index, so it can be landed directly; in any other view (a filter
    /// still active after clearing a sort, a sort still active after clearing a
    /// filter) it is not, and landing it raw would clamp to the end of a short
    /// filtered view or drop onto blank rows past a rebuilding prefix. The jump
    /// primitive is defined to land a source row at its position in the CURRENT
    /// view, filter and sort composed, so it is the right instrument there.
    func reanchor(onSourceRow sourceRow: UInt64) {
        if isFiltered || isSorted {
            // Re-issue the CURRENT geometry first. A jump that has to scan
            // resolves later and materializes only when it lands, so without
            // this the window keeps the rows of the view we just left — the
            // sorted cells presented as the restored view, beside a gutter that
            // reads nil — and nothing re-issues it meanwhile (no sort is
            // working, and a full window is not short). The jump re-lands on
            // top of this when it resolves.
            materialize(start: desiredStart, count: desiredCount)
            beginJump(to: sourceRow)
        } else {
            landViewport(on: sourceRow)
        }
    }

    // MARK: - Convergence pacing (finding 4a)

    /// Re-issues the identical window in bounded SLICES while a building sort is
    /// still filling it, instead of once per 100 ms poll tick. Each slice
    /// re-issues back-to-back for at most `SortWindowTuning.convergeSlice` and
    /// then yields a runloop turn, so a window that needs hundreds of re-issues
    /// converges in about the core's own work time while the UI stays live.
    /// One converge loop at a time; it stops as soon as the window fills, the
    /// pass lands, or the document changes.
    func scheduleSortConverge() {
        guard !sortConvergeRunning else { return }
        sortConvergeRunning = true
        DispatchQueue.main.async { [weak self] in self?.runSortConvergeSlice(generation: self?.viewGeneration ?? 0) }
    }

    private func runSortConvergeSlice(generation: Int) {
        guard session != nil, generation == viewGeneration, sortIsWorking,
              desiredWindow.isShort, !windowLoading else {
            sortConvergeRunning = false
            // A window that filled (or a pass that landed) still needs the frame
            // the last re-issue produced to reach the screen.
            NativeGridController.live?.apply()
            return
        }
        let sliceStart = progressClock.now
        let rowsAtSliceStart = window.rows.count
        repeat {
            materialize(start: desiredStart, count: desiredCount)
        } while sortIsWorking && desiredWindow.isShort && !windowLoading
            && progressClock.now - sliceStart < SortWindowTuning.convergeSlice
        NativeGridController.live?.apply()
        // A window is also SHORT when its rows are simply not servable yet —
        // before the pass commits its first chunk, or during a rebuild — and on
        // a gzip or network document that lasts seconds. Re-issuing then cannot
        // grow anything, so a whole slice with no growth ends the loop and hands
        // pacing back to the 100 ms poll tick, which re-arms it the moment the
        // prefix starts filling. Without this the loop is a busy-wait: every
        // iteration pays a full window fetch plus its label/metadata reads to
        // return the same zero rows.
        guard window.rows.count > rowsAtSliceStart else {
            sortConvergeRunning = false
            return
        }
        DispatchQueue.main.async { [weak self] in self?.runSortConvergeSlice(generation: generation) }
    }

    // MARK: - Poll folding

    /// Re-reads the sort right after something that can make the core REBUILD it
    /// (§9: a filter set/clear, or a type override / null sentinel on the sort
    /// column). The rebuild starts inside those calls, so the banner, the header
    /// indicator and the poll cadence must not wait a tick to notice; the view
    /// keeps serving the REBUILD's prefix throughout, never file order.
    func refreshSortAfterInputsChanged() {
        guard let session, sortSnapshot != nil else { return }
        sortSnapshot = session.sortStatus()
        if sortIsWorking { scheduleSortConverge() }
    }

    /// Folds one poll tick's sort snapshot. Returns whether the grid needs a
    /// repaint poke this tick — true while a pass is outstanding (the served top
    /// rows refine under an unchanged window geometry) and on any phase change.
    func foldSort(_ snapshot: SortSnapshot?) -> Bool {
        let previous = sortSnapshot
        sortSnapshot = snapshot
        let phaseChanged = previous?.phase != snapshot?.phase
        switch snapshot?.phase {
        case .failed:
            guard phaseChanged else { return true }
            // The core has already restored the pre-sort order; re-read it and
            // say what happened. The request is retained, so the header keeps
            // its failed indicator and a retry is one menu entry away.
            rowCountInfo = session?.rowCount() ?? rowCountInfo
            materialize(start: desiredStart, count: desiredCount)
            return true
        case .active:
            guard phaseChanged else { return false }
            // THE LANDING TICK. The window on screen was materialized over a
            // prefix that has just been superseded by the final order, and
            // nothing else would re-issue it: the window is not short, so the
            // window-poll decision says nothing, and this is the tick on which
            // the poll loop stops. Without this the grid would keep showing a
            // superseded prefix under a settled "Sorted by …" banner.
            rowCountInfo = session?.rowCount() ?? rowCountInfo
            materialize(start: desiredStart, count: desiredCount)
            return true
        case .parked:
            redriveParkedSortIfIdle()
            return true
        case .building:
            if phaseChanged { scheduleSortConverge() }
            return true
        case nil:
            return phaseChanged
        }
    }

    /// A PARKED pass is only ever resumed by another `ls_sort_set` (the header's
    /// §8 rule). On a local AUTO document it never parks; on a NETWORK one — or
    /// under MANUAL indexing — a jump or a find takes the scan slot and parks it,
    /// and nothing would ever re-drive it: the banner would show a frozen
    /// percentage forever. So re-issue the identical request as soon as the scan
    /// slot is genuinely free.
    ///
    /// "Free" excludes a FIND that still exists, not merely one that is still
    /// scanning. Re-issuing the sort is a non-no-op `ls_sort_set`, and the core's
    /// RESET rule wipes the active search with it — so an auto-redrive over a
    /// landed find would silently destroy the user's match count and highlights,
    /// something they never asked for and cannot undo. A parked pass with a find
    /// on screen therefore stays parked and SAYS so ("paused"), and resumes by
    /// itself the moment the find goes away (Esc, or a new one) — or at once if
    /// the user re-picks the same entry from the header menu, which is an
    /// explicit request and resets the find the way every explicit sort does.
    private func redriveParkedSortIfIdle() {
        guard let session, let request = sortSnapshot, case .parked = request.phase else { return }
        guard !sortIsPausedForFind else { return }
        if case .scanning = jumpFlow { return }
        guard session.setSort(column: request.column, direction: request.direction) else { return }
        sortRedrives += 1
        sortSnapshot = session.sortStatus()
        scheduleSortConverge()
    }

    /// The pass is parked and will NOT be re-driven, because doing so would reset
    /// the find the user is looking at. Drives the banner's wording, so a stalled
    /// long operation is never presented as a running one.
    var sortIsPausedForFind: Bool {
        guard case .parked = sortSnapshot?.phase else { return false }
        return findSession.display.request != nil
    }

    // MARK: - Chrome derivations

    /// The sort banner's copy — "Sorting by Price… / Sorted by Price" — or nil
    /// when nothing is sorted.
    var sortBannerText: String? {
        guard let snapshot = sortSnapshot else { return nil }
        let label = (0..<columnCount).contains(snapshot.column) ? columnLabel(snapshot.column) : ""
        switch snapshot.phase {
        case .parked where sortIsPausedForFind:
            // Honest about a stalled operation: the percentage is frozen because
            // the pass yielded the scan slot to the find, and it resumes when the
            // find is dismissed (or immediately if the sort is re-requested).
            return "Sorting by \(label) — paused for find"
        case .building, .parked:
            return "Sorting by \(label)…"
        case .active:
            return "Sorted by \(label)"
        case let .failed(reason):
            return SortCopy.failure(reason)
        }
    }

    /// The pass's fraction while one is outstanding — shown for the WHOLE build,
    /// not behind the shared delay gate: the pass is a full pass over the data
    /// (a minute on a 10 GB file, longer over the wire), so there is no case
    /// where hiding it early is right.
    var sortProgress: Double? {
        sortSnapshot?.progress.map { max(0, min(1, $0)) }
    }
}

/// The user-facing sort strings, in one place.
enum SortCopy {
    static func failure(_ reason: SortFailure) -> String {
        switch reason {
        case .storage:
            return "Couldn't sort — not enough free disk space for the sort's temporary files"
        case .memory:
            return "Couldn't sort — not enough memory"
        }
    }

    /// The accessibility reading of a header's sort state.
    static func indicatorLabel(_ indicator: SortIndicator) -> String? {
        guard let direction = indicator.direction else { return nil }
        if indicator.didFail { return "sort failed" }
        let sense = direction == .ascending ? "ascending" : "descending"
        return indicator.isPending ? "sorting \(sense)" : "sorted \(sense)"
    }
}
