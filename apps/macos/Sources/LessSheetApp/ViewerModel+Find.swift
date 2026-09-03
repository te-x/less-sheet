import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// Find: submit, step, cancel, close, the wrap-notice latch, and the per-window
// match-flags mask the highlights read.

extension DocumentModel {
    // MARK: - Find (search)

    /// Enter in the Find field: while a filter is active the field edits the
    /// FILTER, so re-apply the (edited) predicate as the filter; otherwise run
    /// a normal search.
    func submitFindField() {
        if isFiltered { applyFindAsFilter() } else { submitFind() }
    }

    /// Flips the one shared "Match case" flag and re-issues whatever is active.
    /// Case sensitivity is part of the request's identity, so `submitFind` takes
    /// its restart branch rather than advancing to the next match. With nothing
    /// active only the draft changes: a never-submitted query is not spontaneously
    /// searched.
    func setCaseSensitive(_ enabled: Bool) {
        guard findSession.draft.caseSensitive != enabled else { return }
        findSession.draft.caseSensitive = enabled
        if isFiltered {
            applyFindAsFilter()
        } else if findSession.display.request != nil {
            submitFind()
        }
    }

    /// Submit the current draft (Enter): compose + start the search, then
    /// navigate to the first match in the FILE. A rejected compose (ordering
    /// predicate with a non-numeric value, or an out-of-range column) blinks +
    /// shakes the value field; the empty text query is silently ignored.
    func submitFind() {
        switch findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
        case .ignored:
            break
        case .rejected:
            findRejections += 1
            if FindProbe.active { FindProbe.rejected(model: self) }
        case let .run(request):
            // Enter on the SAME active search advances to the next match; a
            // changed query or predicate starts a fresh one.
            if findSession.display.request == request {
                stepFind(.forward)
                return
            }
            guard let session, session.startSearch(request) else {
                findRejections += 1
                if FindProbe.active { FindProbe.rejected(model: self) }
                return
            }
            cancelWrapNav()
            userStopped = false
            findSession = findControl.began(findSession, running: request)
            searchNavDirection = .forward
            session.navigateSearch(.fromTop)          // "first match in the file"
            foldSearch(session.searchStatus())        // the result may be instant
            startPolling()
            // A found first match carries its own repaint through the landing, but
            // a query with NO match has no landing — and the previous search's
            // highlights must still be erased now rather than at the next scroll.
            NativeGridController.live?.apply()
        }
    }

    /// Verification hook: identical to typing the query and pressing Enter.
    func submitFindQuery(_ query: String) {
        openFindField()
        findSession.draft.mode = .text
        findSession.draft.text = query
        submitFind()
    }

    /// ⌘G / ⇧⌘G: navigate to the next / previous match (relative to the current
    /// landing, else the viewport). No-op when no search is active.
    func stepFind(_ direction: SearchDirection) {
        guard let session,
              let nav = findControl.step(findSession, direction, viewportRow: UInt64(firstVisibleRow))
        else { return }
        cancelWrapNav()               // an explicit step supersedes a pending auto-wrap
        userStopped = false           // resuming navigation supersedes a prior user stop
        searchNavDirection = direction
        session.navigateSearch(nav)
        foldSearch(session.searchStatus())
        startPolling()
    }

    /// The scan-cancel affordance: stop the scan, keep what is known, say
    /// "Stopped".
    func cancelFind() {
        cancelWrapNav()
        session?.cancelSearch()
        // See `userStopped` for why the follow-up poll would otherwise fold
        // "Stopped" away into the count.
        userStopped = true
        findSession = findControl.stopped(findSession)
    }

    /// Esc: clear the results and highlights, retain the typed query, cancel the
    /// core search.
    func closeFind() {
        cancelWrapNav()
        session?.cancelSearch()
        userStopped = false
        findSession = findControl.closed(findSession)
        findFieldActive = false
        searchNavDirection = .forward
        // Closing only nils an observed key, with no scroll or landing to carry a
        // repaint, so without this poke the highlights linger until the user
        // scrolls.
        NativeGridController.live?.apply()
    }

    /// Folds one search poll into the display, holds a wrap notice on screen for
    /// a readable beat before issuing its follow-up navigation, and brings a
    /// fresh landing into view.
    func foldSearch(_ snapshot: SearchSnapshot?) {
        let previous = findSession.display
        findSession = findControl.resolved(findSession, with: snapshot, navDirection: searchNavDirection)

        // Re-assert "Stopped" over the fold while the user-cancel latch holds,
        // keeping every field the fold produced (see `userStopped`).
        let folded = findSession.display
        if userStopped, folded.request != nil, folded.notice != .stopped {
            findSession.display = FindDisplay(
                request: folded.request,
                current: folded.current,
                position: folded.position,
                total: folded.total,
                totalIsFinal: folded.totalIsFinal,
                progress: folded.progress,
                notice: .stopped
            )
        }

        // Issuing the wrap's follow-up navigation synchronously would coalesce
        // into this same observation turn and give the notice a zero-frame
        // lifetime, so it is latched for a readable beat instead.
        if findControl.wrapNav(findSession) != nil {
            scheduleWrapNav()
        }

        // The only viewport movement is an exact landing: a scanning or exhausted
        // poll leaves `current` unchanged, so nothing scrolls.
        var scrolledTo: UInt64?
        if let current = findSession.display.current, current != previous.current {
            landSearchOn(current.row)
            scrolledTo = current.row
        }
        if FindProbe.active { FindProbe.note(model: self, snapshot: snapshot, scrolledTo: scrolledTo) }
    }

    /// How long a wrap notice stays up before its navigation fires. It must be
    /// readable even in the single-match case, where the landing does not change.
    private static let wrapNoticeLatch: Duration = .milliseconds(900)

    /// Latches the wrap notice and issues its navigation on a LATER main-actor
    /// turn, so the notice renders first. Armed once per notice: polls during the
    /// latch re-derive the same notice but never stack another timer.
    private func scheduleWrapNav() {
        guard wrapNavTask == nil else { return }
        wrapNavTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: DocumentModel.wrapNoticeLatch)
            guard let self, !Task.isCancelled else { return }
            self.wrapNavTask = nil
            guard let session = self.session, let wrap = self.findControl.wrapNav(self.findSession) else { return }
            self.searchNavDirection = wrap.direction
            session.navigateSearch(wrap)
            self.foldSearch(session.searchStatus())   // land the wrap on a fresh turn (clears the notice)
            self.startPolling()
        }
    }

    func cancelWrapNav() {
        wrapNavTask?.cancel()
        wrapNavTask = nil
    }

    private func landSearchOn(_ row: UInt64) {
        landViewport(on: row)
    }

    /// Per-visible-column highlight state for a data row. The current match is
    /// strong, every other matching visible cell subtle; header cells are never
    /// passed here, since they are never matched.
    func cellHighlights(forRow row: Int) -> [SheetCellHighlight] {
        highlights(forRow: row, over: visibleColumns)
    }

    /// The window-bound analog of `cellHighlights` — the live grid's path.
    func windowCellHighlights(forRow row: Int) -> [SheetCellHighlight] {
        highlights(forRow: row, over: windowColumns())
    }

    /// Shared derivation over an explicit absolute-indexed column list. The
    /// subtle verdict comes from the core's per-window mask — fetched once per
    /// window-or-search change, then indexed per cell — while the strong
    /// current-match highlight comes from the landing and needs no mask.
    private func highlights(forRow row: Int, over columns: [Int]) -> [SheetCellHighlight] {
        guard findSession.display.request != nil else {
            return Array(repeating: .none, count: columns.count)
        }
        ensureMatchFlagsFresh()
        let current = findSession.display.current
        return columns.map { column in
            if let current, current.row == UInt64(row), current.column == column {
                return .strong
            }
            return matchFlag(row: row, column: column) ? .subtle : .none
        }
    }

    /// Refetches the mask only when the window content or the active request
    /// changed — one call per materialize-or-search-change, never per repaint and
    /// never per cell. The borrow is copied out inside `windowMatchFlags`, so the
    /// cached bytes stay safe to index across later repaints.
    private func ensureMatchFlagsFresh() {
        let key = currentMatchFlagsKey()
        guard key != matchFlagsKey else { return }
        matchFlagsKey = key
        if let session, key.request != nil, key.rowCount > 0, key.columnCount > 0 {
            matchFlagsMask = session.windowMatchFlags(firstColumn: key.firstColumn, columnCount: key.columnCount)
            matchFlagsFetchCount &+= 1
        } else {
            matchFlagsMask = []
        }
    }

    /// Reset the fetch counter (probe-only). Inert in normal use.
    func resetMatchFlagsFetchCount() { matchFlagsFetchCount = 0 }

    /// The key for the current window and request, shared with `seedMatchFlags`
    /// so a seeded mask is treated as already fresh.
    private func currentMatchFlagsKey() -> MatchFlagsCacheKey {
        MatchFlagsCacheKey(
            contentGen: matchFlagsContentGen,
            firstRow: window.firstRow,
            firstColumn: window.firstColumn,
            rowCount: window.rows.count,
            columnCount: window.rows.first?.count ?? 0,
            request: findSession.display.request
        )
    }

    /// Dump hook: seeds the cache with a mask computed on a real session
    /// elsewhere, so a sessionless dump snapshot can still render the core's
    /// highlights. `flags` must have been fetched for THIS model's window and
    /// request.
    func seedMatchFlags(_ flags: [UInt8]) {
        matchFlagsMask = flags
        matchFlagsKey = currentMatchFlagsKey()
    }

    /// Dump hook: computes the mask for `request` over this model's already
    /// materialized window. The flags come from the active request and the
    /// window, not from the match-scan, so there is nothing to wait for.
    func dumpMatchFlagsMask(for request: SearchRequest) -> [UInt8] {
        guard let session else { return [] }
        _ = session.startSearch(request)
        let stride = window.rows.first?.count ?? 0
        return session.windowMatchFlags(firstColumn: window.firstColumn, columnCount: stride)
    }

    /// The subtle-highlight verdict for an absolute cell, read from the cached
    /// mask; `ensureMatchFlagsFresh` must have run this frame. Anything outside
    /// the materialized window is false.
    private func matchFlag(row: Int, column: Int) -> Bool {
        guard let key = matchFlagsKey, key.columnCount > 0, !matchFlagsMask.isEmpty else { return false }
        let relativeRow = row - Int(key.firstRow)
        let relativeColumn = column - key.firstColumn
        guard relativeRow >= 0, relativeRow < key.rowCount,
              relativeColumn >= 0, relativeColumn < key.columnCount else { return false }
        let idx = relativeRow * key.columnCount + relativeColumn
        guard idx < matchFlagsMask.count else { return false }
        return matchFlagsMask[idx] == 1
    }
}
