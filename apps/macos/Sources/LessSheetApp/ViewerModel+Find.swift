import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — find (search): submit / step / cancel / close, the wrap-notice
// latch, and the per-window match-flags mask derivation (ARCH-thin-frontend-
// shared-core Phase 1). Pure code motion out of ViewerModel.swift.

extension DocumentModel {
    // MARK: - Find (search)

    /// Enter in the Find field: while a filter is active the field edits the
    /// FILTER, so re-apply the (edited) predicate as the filter; otherwise run
    /// a normal search.
    func submitFindField() {
        if isFiltered { applyFindAsFilter() } else { submitFind() }
    }

    /// Flip the shared "Match case" control (ARCH-search-case-mode C4). Records
    /// the one session-scoped draft flag (shared by Text/Where) and LIVE-re-issues
    /// whatever is active: because `caseSensitive` is part of `SearchRequest`
    /// identity, the composed request is now UNEQUAL to the running one, so
    /// `submitFind` takes its restart branch (never the same-request "advance to
    /// next"), and `applyFindAsFilter` re-applies the filter with the new folding.
    /// With nothing active only the draft changes — a never-submitted query is not
    /// spontaneously searched.
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
            // Enter on the SAME active search advances to the next match (ARCH
            // req. 7: "Enter runs the search … then Enter/⌘G = next"). A changed
            // query/predicate starts a fresh search.
            if findSession.display.request == request {
                stepFind(.forward)
                return
            }
            guard let session, session.startSearch(request) else {
                // The composer already validated; the real core accepts. (The
                // seed core rejects every start, so find stays inert until the
                // core lands — surfaced as a rejection here.)
                findRejections += 1
                if FindProbe.active { FindProbe.rejected(model: self) }
                return
            }
            cancelWrapNav()
            userStopped = false                       // a fresh search shows counts, never a stale "Stopped"
            findSession = findControl.began(findSession, running: request)
            searchNavDirection = .forward
            session.navigateSearch(.fromTop)          // "first match in the file"
            foldSearch(session.searchStatus())        // fold the (possibly instant) result
            startPolling()
            // Repaint the new highlights NOW. A FOUND first match lands (async
            // apply via foldSearch), but a query with NO match has no landing to
            // carry the repaint that must ERASE the prior search's highlights —
            // they would otherwise linger until the next scroll (same family as
            // closeFind / the filter toggle). Idempotent alongside the landing.
            NativeGridController.live?.apply()
        }
    }

    /// Drive the real submit path from the verification hook (LESSSHEET_FIND):
    /// open the field, set a Text-mode query, and submit — identical to typing
    /// the query + Enter through the popup.
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

    /// The scan-cancel affordance: stop the match-scan, keep what's known so
    /// far, state "Stopped".
    func cancelFind() {
        cancelWrapNav()
        session?.cancelSearch()
        // Latch the genuine user stop so the follow-up cancelled+found poll
        // (an already-landed NAV_FOUND persists past ls_search_cancel — see
        // `userStopped`) does not fold "Stopped" away into the count.
        userStopped = true
        findSession = findControl.stopped(findSession)
    }

    /// Esc / close: clear results + highlights (request nil), retain the typed
    /// query, and cancel the core search.
    func closeFind() {
        cancelWrapNav()
        session?.cancelSearch()
        userStopped = false           // the session is cleared — drop any stop latch
        findSession = findControl.closed(findSession)
        findFieldActive = false
        searchNavDirection = .forward
        // Clear the match highlights NOW. Closing find only nils the request
        // (an observed key) with no scroll/landing, so — like the filter toggle
        // — the SwiftUI-observation repaint defers to the next event and the blue
        // highlights linger until the user scrolls. The explicit synchronous
        // poke repaints this turn (RepaintAuditProbe: closeFind delta 0 -> 1).
        NativeGridController.live?.apply()
    }

    /// Fold one search poll into the display; when a wrap notice appears, hold
    /// it on screen for a readable beat and THEN issue the follow-up navigation,
    /// and bring a fresh landing into view like a jump landing.
    func foldSearch(_ snapshot: SearchSnapshot?) {
        let previous = findSession.display
        findSession = findControl.resolved(findSession, with: snapshot, navDirection: searchNavDirection)

        // A genuine user Cancel latched "Stopped" (userStopped). The core's
        // ls_search_cancel leaves an already-landed NAV_FOUND in place, so the
        // follow-up poll after the cancel folds through `resolved` as the count
        // (notice nil — the correct net-park behavior). Re-assert "Stopped"
        // while the latch holds, keeping every folded field (landing / position
        // / count) the fold produced. The latch clears on the next fresh
        // search or navigation, so subsequent searches show counts normally.
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

        // A wrap notice ("Wrapped to start/end") appeared. Issuing the follow-up
        // navigation synchronously here would coalesce into this same @Observable
        // turn, giving the notice a zero-frame lifetime; instead latch it for a
        // readable beat, then navigate (see scheduleWrapNav). When the wrap
        // lands, the next fold clears the notice — the pinned self-clear.
        if findControl.wrapNav(findSession) != nil {
            scheduleWrapNav()
        }

        // A new landing scrolls the viewport to it (same mechanics as a jump).
        // The ONLY viewport movement is an exact FOUND landing: a .searching /
        // .exhausted poll leaves `current` unchanged, so nothing scrolls.
        var scrolledTo: UInt64?
        if let current = findSession.display.current, current != previous.current {
            landSearchOn(current.row)
            scrolledTo = current.row
        }
        if FindProbe.active { FindProbe.note(model: self, snapshot: snapshot, scrolledTo: scrolledTo) }
    }

    /// Minimum time a wrap notice stays visible before the follow-up navigation
    /// fires (the notice must be genuinely readable in both directions,
    /// including the single-match case where the landing does not change).
    private static let wrapNoticeLatch: Duration = .milliseconds(900)

    /// Latch the current wrap notice, then issue its navigation on a LATER
    /// main-actor turn (so the notice renders first) and resume polling. Armed
    /// once per notice — polls during the latch keep re-deriving the same notice
    /// but never stack another timer.
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

    /// Page the window to a search landing and scroll it into view (mirrors the
    /// jump landing, including the EOF overscroll allowance).
    private func landSearchOn(_ row: UInt64) {
        landViewport(on: row)
    }

    /// Per-visible-column highlight state for a data row (O(viewport), one core
    /// mask fetch per materialize/search-change — NEVER per cell). The current
    /// match is strong; every other matching visible cell is subtle; header
    /// cells are never passed here (never matched).
    func cellHighlights(forRow row: Int) -> [SheetCellHighlight] {
        highlights(forRow: row, over: visibleColumns)
    }

    /// The window-bound analog of `cellHighlights` — the live grid's path
    /// (ARCH-column-windowing): O(column window), never O(visible columns).
    func windowCellHighlights(forRow row: Int) -> [SheetCellHighlight] {
        highlights(forRow: row, over: windowColumns())
    }

    /// Shared highlight derivation over an explicit (absolute-indexed) column
    /// list. The subtle verdict now comes from the CORE's per-window match
    /// flags (`ensureMatchFlagsFresh` fetches the mask once per window/search
    /// change; `matchFlag` indexes it per cell — no frontend matcher), so
    /// `cellHighlights` / `windowCellHighlights` differ only in which columns
    /// they cover. The strong current-match highlight stays driven by
    /// `findSession.display.current` (found_row/found_col), needing no mask.
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

    /// (Re)fetch the per-window match-flags mask from the core iff the
    /// materialized window geometry OR the active search request changed since
    /// the last fetch — exactly ONE `windowMatchFlags` call per
    /// materialize-or-search-change, never per repaint and never per cell (AC5).
    /// With no active request (or an empty window / column range) the core
    /// returns `[]`, so nothing is subtly highlighted. The window-tied borrow is
    /// copied out inside `windowMatchFlags`, so the cached `[UInt8]` is safe to
    /// index across later repaints until the next refetch.
    private func ensureMatchFlagsFresh() {
        let key = currentMatchFlagsKey()
        guard key != matchFlagsKey else { return }
        matchFlagsKey = key
        if let session, key.request != nil, key.rowCount > 0, key.columnCount > 0 {
            matchFlagsMask = session.windowMatchFlags(firstColumn: key.firstColumn, columnCount: key.columnCount)
            matchFlagsFetchCount &+= 1   // instrumentation (MatchFlagsFetchProbe): a REAL ABI fetch
        } else {
            matchFlagsMask = []
        }
    }

    /// Reset the fetch counter (probe-only). Inert in normal use.
    func resetMatchFlagsFetchCount() { matchFlagsFetchCount = 0 }

    /// The cache key for the CURRENT materialized window + active request — the
    /// geometry the mask is fetched for (`firstColumn`/`columnCount` mirror
    /// `RowWindow.firstColumn` and the fetched column width). Shared by
    /// `ensureMatchFlagsFresh` and `seedMatchFlags` so a seeded mask is treated
    /// as already-fresh (no refetch attempt).
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

    /// DUMP/PROBE hook (FrameDump find scenes): seed the match-flags cache with a
    /// mask computed on a real core session ELSEWHERE, so a SESSIONLESS dump
    /// snapshot still renders the CORE's subtle highlights (its own
    /// `windowMatchFlags` returns `[]` with no session). `flags` MUST have been
    /// fetched for THIS model's current window + `findSession.display.request`
    /// (`window.firstColumn` × the fetched column width); the seeded key mirrors
    /// what `ensureMatchFlagsFresh` would compute, so it is treated as fresh.
    /// Inert in normal use (the live model fetches its own mask).
    func seedMatchFlags(_ flags: [UInt8]) {
        matchFlagsMask = flags
        matchFlagsKey = currentMatchFlagsKey()
    }

    /// DUMP/PROBE hook (FrameDump find scenes): compute the CORE's per-window
    /// match-flags mask for `request` over THIS model's already-materialized
    /// window, keeping `session` private (the sessionless dump snapshot can't
    /// reach it). Sets `request` active on the session, then reads the flags —
    /// which come from the active request + the materialized window, NOT the
    /// match-scan (so no wait). Returns `[]` with no session or empty window.
    /// This model is a throwaway dump driver; the flags feed `seedMatchFlags`.
    func dumpMatchFlagsMask(for request: SearchRequest) -> [UInt8] {
        guard let session else { return [] }
        _ = session.startSearch(request)
        let stride = window.rows.first?.count ?? 0
        return session.windowMatchFlags(firstColumn: window.firstColumn, columnCount: stride)
    }

    /// The core's SUBTLE-highlight verdict for absolute (`row`, `column`), read
    /// from the cached mask (`ensureMatchFlagsFresh` must have run this frame).
    /// Any cell outside the materialized window — or when no mask was fetched
    /// (no search, empty range) — is `false`. Column-relative mapping mirrors
    /// `RowWindow.firstColumn`: absolute column `c` sits at slot `c - firstColumn`.
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
