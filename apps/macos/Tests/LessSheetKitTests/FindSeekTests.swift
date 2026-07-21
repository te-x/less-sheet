// Frozen behavior tests — find-seek slice (planner-owned).
// ARCH-find-seek app criteria 7–8: the find view-model's pinned semantics
// (composing + validation, count state machine, wrap, Esc/reopen clearing)
// and the search bridge against the REAL linked Zig core — including the
// frontend-vs-core matcher-verdict identity matrix. Semantics are normative
// in Sources/Contracts/FindControl.swift and api/lesssheet.h.
//
// ARCH-search-case-mode (§6.C, macOS): the "Match case" control is one shared
// session bool (default OFF = ASCII case-INSENSITIVE) marshaled 1:1 to the
// request's `caseSensitive` — smart-case is retired. The composer + bridge
// tests below pin: default insensitive folding (an uppercase query matches
// lowercase cells), byte-exact when ON, predicate EQ/NE folding, ordering
// unaffected, non-ASCII never folded, and the flag being part of the request
// identity (so a live toggle re-issues).
//
// Determinism: the fixture is far below the core's head budget, so match
// scans complete in milliseconds; polls are bounded (10 s) and every bridge
// test asserts `startSearch == true` via #require BEFORE any poll loop, so
// unimplemented seeds fail fast instead of waiting.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers

private func findFixturePath() throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "find", withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture find.csv"
    )
    return url.path(percentEncoded: false)
}

private func openFindFixture(
    forcing override: DialectOverride = .sniffAll
) async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: findFixturePath(), forcing: override)
}

/// Poll the session's search status until `predicate` holds (<= 10 s).
private func waitSearch(
    _ session: any DocumentSession,
    until predicate: (SearchSnapshot) -> Bool
) async throws -> SearchSnapshot {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if let snap = session.searchStatus(), predicate(snap) { return snap }
        try #require(clock.now - start < .seconds(10), "search poll timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Walk every match forward from the top; requires a completed scan first so
/// each navigation resolves synchronously (pinned). Returns the match rows.
private func matchedRows(_ session: any DocumentSession, _ request: SearchRequest) async throws -> Set<UInt64> {
    try #require(session.startSearch(request), "core rejected \(request)")
    _ = try await waitSearch(session) { $0.totalIsFinal }
    var rows: Set<UInt64> = []
    var anchor: UInt64 = 0
    for _ in 0..<64 {
        session.navigateSearch(SearchNav(anchor: anchor, direction: .forward))
        guard let snap = session.searchStatus() else { break }
        guard case let .found(match, _) = snap.nav else { break } // exhausted
        rows.insert(match.row)
        anchor = match.row + 1
    }
    return rows
}

private let sampleRequest = SearchRequest.text(query: "x", scope: nil, caseSensitive: false)

// MARK: - Contract conformance pins (signature drift fails this build)

@Test func findContractConformancePins() {
    let _: any FindControlling = FindControl()
}

// MARK: - ABI agreement: C header <-> Swift contract

@Test func searchABIConstantsArePinned() {
    #expect(LS_SEARCH_TEXT.rawValue == 0)
    #expect(LS_SEARCH_PREDICATE.rawValue == 1)
    #expect(LS_SEARCH_OP_EQ.rawValue == 0)
    #expect(LS_SEARCH_OP_NE.rawValue == 1)
    #expect(LS_SEARCH_OP_LT.rawValue == 2)
    #expect(LS_SEARCH_OP_GT.rawValue == 3)
    #expect(LS_SEARCH_OP_LE.rawValue == 4)
    #expect(LS_SEARCH_OP_GE.rawValue == 5)
    #expect(LS_SEARCH_FORWARD.rawValue == 0)
    #expect(LS_SEARCH_BACKWARD.rawValue == 1)
    #expect(LS_SEARCH_IDLE.rawValue == 0)
    #expect(LS_SEARCH_SCANNING.rawValue == 1)
    #expect(LS_SEARCH_DONE.rawValue == 2)
    #expect(LS_SEARCH_CANCELLED.rawValue == 3)
    #expect(LS_SEARCH_NAV_NONE.rawValue == 0)
    #expect(LS_SEARCH_NAV_SEARCHING.rawValue == 1)
    #expect(LS_SEARCH_NAV_FOUND.rawValue == 2)
    #expect(LS_SEARCH_NAV_EXHAUSTED.rawValue == 3)
    // The Swift operator enum mirrors the ABI values one-to-one.
    #expect(SearchOperator.equals.rawValue == Int32(LS_SEARCH_OP_EQ.rawValue))
    #expect(SearchOperator.notEquals.rawValue == Int32(LS_SEARCH_OP_NE.rawValue))
    #expect(SearchOperator.lessThan.rawValue == Int32(LS_SEARCH_OP_LT.rawValue))
    #expect(SearchOperator.greaterThan.rawValue == Int32(LS_SEARCH_OP_GT.rawValue))
    #expect(SearchOperator.lessOrEqual.rawValue == Int32(LS_SEARCH_OP_LE.rawValue))
    #expect(SearchOperator.greaterOrEqual.rawValue == Int32(LS_SEARCH_OP_GE.rawValue))
    #expect(SearchOperator.equals.isOrdering == false)
    #expect(SearchOperator.notEquals.isOrdering == false)
    #expect(SearchOperator.lessThan.isOrdering)
    #expect(SearchOperator.greaterThan.isOrdering)
    #expect(SearchOperator.lessOrEqual.isOrdering)
    #expect(SearchOperator.greaterOrEqual.isOrdering)
}

@Test func searchRequestABICarriesCaseSensitive() {
    // ARCH-search-case-mode A1: `ls_search_request` grew one `bool
    // case_sensitive` — the field the frontend marshals the "Match case"
    // control to. It round-trips through the C-imported memberwise init (and
    // there is no case enum / SMART value anywhere in the ABI).
    var req = ls_search_request(
        kind: LS_SEARCH_TEXT, op: LS_SEARCH_OP_EQ, column: 0,
        value_ptr: nil, value_len: 0, scope_ptr: nil, scope_len: 0,
        case_sensitive: true
    )
    #expect(req.case_sensitive == true)
    req.case_sensitive = false
    #expect(req.case_sensitive == false)
}

@Test func caseSensitiveIsPartOfTheRequestIdentity() {
    // ARCH-search-case-mode C4 (mechanism): flipping "Match case" makes an
    // otherwise-equal request UNEQUAL, so a live toggle re-issues (restarts)
    // rather than advances the active search.
    #expect(SearchRequest.text(query: "a", scope: nil, caseSensitive: false)
        != .text(query: "a", scope: nil, caseSensitive: true))
    #expect(SearchRequest.predicate(column: 0, comparison: .equals, value: "a", caseSensitive: false)
        != .predicate(column: 0, comparison: .equals, value: "a", caseSensitive: true))
}

// MARK: - The pinned numeric grammar (same fixtures as the core's frozen tests)

@Test func numericGrammarMatchesTheCorePins() {
    let accepted = [
        "1", "-2", "+1e5", ".5", "5.", " 12 ", "1e5", "\t7\t",
        "-0.0", "+42", "1.5e-3", "2E+4", "0.01", "9007199254740993",
    ]
    for text in accepted {
        #expect(NumericGrammar.isNumeric(text), "expected numeric: \(text)")
    }
    let rejected = [
        "", " ", "0x1F", "1,000", "1e", "e5", "--1", "1 2", "NaN", "inf",
        "١٢", "1.2.3", ".", "+.", "5..", "abc", "1.5e", "e", "+",
    ]
    for text in rejected {
        #expect(!NumericGrammar.isNumeric(text), "expected non-numeric: \(text)")
    }
}

// MARK: - Composer (Enter): mode switch, scope derivation, ordering validation

@Test func submitComposesTextRequestsWithTheVisibleColumnScope() {
    let c = FindControl()
    var s = c.initial()
    s.draft.mode = .text
    s.draft.text = "needle"
    // Nothing hidden: scope nil (all columns). Match case defaults OFF.
    #expect(c.submit(s, visibleColumns: [0, 1, 2], columnCount: 3)
        == .run(.text(query: "needle", scope: nil, caseSensitive: false)))
    // Hidden columns: the ASCENDING visible set is fixed into the request.
    #expect(c.submit(s, visibleColumns: [2, 0], columnCount: 3)
        == .run(.text(query: "needle", scope: [0, 2], caseSensitive: false)))
    // The empty query means "no search" — ignored, not an error.
    s.draft.text = ""
    #expect(c.submit(s, visibleColumns: [0, 1, 2], columnCount: 3) == .ignored)
}

@Test func submitMarshalsTheMatchCaseControlIntoTheRequest() {
    // ARCH-search-case-mode C2 (composer half): the ONE "Match case" draft bool
    // threads 1:1 into the composed request's `caseSensitive`, shared by Text
    // and Where. (RED until the composer reads draft.caseSensitive.)
    let c = FindControl()
    var s = c.initial()
    s.draft.caseSensitive = true
    // Text mode carries it.
    s.draft.mode = .text
    s.draft.text = "needle"
    #expect(c.submit(s, visibleColumns: [0, 1, 2], columnCount: 3)
        == .run(.text(query: "needle", scope: nil, caseSensitive: true)))
    // The SAME control governs the Where predicate request.
    s.draft.mode = .predicate
    s.draft.column = 1
    s.draft.comparison = .equals
    s.draft.value = "x"
    #expect(c.submit(s, visibleColumns: [0, 1, 2], columnCount: 3)
        == .run(.predicate(column: 1, comparison: .equals, value: "x", caseSensitive: true)))
    // Toggling it OFF marshals false (the default).
    s.draft.caseSensitive = false
    #expect(c.submit(s, visibleColumns: [0, 1, 2], columnCount: 3)
        == .run(.predicate(column: 1, comparison: .equals, value: "x", caseSensitive: false)))
}

@Test func submitValidatesOrderingPredicateValues() {
    let c = FindControl()
    var s = c.initial()
    s.draft.mode = .predicate
    s.draft.column = 1
    s.draft.comparison = .lessOrEqual
    s.draft.value = "2.5"
    #expect(c.submit(s, visibleColumns: [0, 1], columnCount: 2)
        == .run(.predicate(column: 1, comparison: .lessOrEqual, value: "2.5", caseSensitive: false)))
    // Ordering + non-numeric value -> the rejection state (blink + shake),
    // BEFORE any core call.
    s.draft.value = "abc"
    #expect(c.submit(s, visibleColumns: [0, 1], columnCount: 2) == .rejected)
    s.draft.value = ""
    #expect(c.submit(s, visibleColumns: [0, 1], columnCount: 2) == .rejected)
    s.draft.value = "1,000"
    #expect(c.submit(s, visibleColumns: [0, 1], columnCount: 2) == .rejected)
    // = and ≠ accept any value — the empty one matches empty cells.
    s.draft.comparison = .equals
    s.draft.value = ""
    #expect(c.submit(s, visibleColumns: [0, 1], columnCount: 2)
        == .run(.predicate(column: 1, comparison: .equals, value: "", caseSensitive: false)))
    // A hidden column is a legal predicate target (the picker marks it)...
    #expect(c.submit(s, visibleColumns: [0], columnCount: 2)
        == .run(.predicate(column: 1, comparison: .equals, value: "", caseSensitive: false)))
    // ...but a column outside the document is not.
    s.draft.column = 5
    #expect(c.submit(s, visibleColumns: [0, 1], columnCount: 2) == .rejected)
}

// MARK: - Count state machine (growing -> final), landings, notices

@Test func initialFindSessionIsEmpty() {
    let s = FindControl().initial()
    #expect(s.draft == .empty)
    #expect(s.draft.caseSensitive == false) // C1: Match case defaults OFF (insensitive)
    #expect(s.display == FindDisplay(
        request: nil, current: nil, position: nil,
        total: 0, totalIsFinal: false, progress: nil, notice: nil
    ))
}

@Test func countsGrowMonotonicallyAndLatchFinal() {
    let c = FindControl()
    var s = c.began(c.initial(), running: sampleRequest)
    #expect(s.display.request == sampleRequest)
    #expect(s.display.progress == 0)
    #expect(s.display.total == 0)
    #expect(!s.display.totalIsFinal)
    // Growing polls fold in.
    s = c.resolved(s, with: SearchSnapshot(
        phase: .scanning(progress: 0.2), nav: .searching, total: 3, totalIsFinal: false
    ), navDirection: .forward)
    #expect(s.display.total == 3)
    #expect(s.display.progress == 0.2)
    // The display never regresses on a stale poll.
    s = c.resolved(s, with: SearchSnapshot(
        phase: .scanning(progress: 0.1), nav: .searching, total: 2, totalIsFinal: false
    ), navDirection: .forward)
    #expect(s.display.total == 3)
    #expect(s.display.progress == 0.2)
    // A landing sets the current match + its exact position.
    s = c.resolved(s, with: SearchSnapshot(
        phase: .scanning(progress: 0.5),
        nav: .found(SearchMatch(row: 7, column: 1), position: 2),
        total: 5, totalIsFinal: false
    ), navDirection: .forward)
    #expect(s.display.current == SearchMatch(row: 7, column: 1))
    #expect(s.display.position == 2)
    #expect(s.display.total == 5)
    // DONE: the total latches final and the progress display ends.
    s = c.resolved(s, with: SearchSnapshot(
        phase: .done,
        nav: .found(SearchMatch(row: 7, column: 1), position: 2),
        total: 12, totalIsFinal: true
    ), navDirection: .forward)
    #expect(s.display.total == 12)
    #expect(s.display.totalIsFinal)
    #expect(s.display.progress == nil)
    #expect(s.display.notice == nil)
}

@Test func exhaustionWrapsWithANoticeInBothDirections() {
    let c = FindControl()
    var s = c.began(c.initial(), running: sampleRequest)
    s = c.resolved(s, with: SearchSnapshot(
        phase: .done,
        nav: .found(SearchMatch(row: 9, column: 0), position: 3),
        total: 3, totalIsFinal: true
    ), navDirection: .forward)
    let exhausted = SearchSnapshot(phase: .done, nav: .exhausted, total: 3, totalIsFinal: true)
    // Next past the last match: wrapped-to-start notice + the wrap nav.
    let wrappedFwd = c.resolved(s, with: exhausted, navDirection: .forward)
    #expect(wrappedFwd.display.notice == .wrappedToStart)
    #expect(wrappedFwd.display.current == SearchMatch(row: 9, column: 0)) // old landing holds until the wrap lands
    #expect(c.wrapNav(wrappedFwd) == .fromTop)
    // Previous before the first match: wrapped-to-end + the end nav.
    let wrappedBwd = c.resolved(s, with: exhausted, navDirection: .backward)
    #expect(wrappedBwd.display.notice == .wrappedToEnd)
    #expect(c.wrapNav(wrappedBwd) == .fromEnd)
    // The notice clears when the wrap navigation reports its landing.
    let landed = c.resolved(wrappedFwd, with: SearchSnapshot(
        phase: .done,
        nav: .found(SearchMatch(row: 1, column: 0), position: 1),
        total: 3, totalIsFinal: true
    ), navDirection: .forward)
    #expect(landed.display.notice == nil)
    #expect(landed.display.current == SearchMatch(row: 1, column: 0))
    #expect(landed.display.position == 1)
    #expect(c.wrapNav(landed) == nil)
}

@Test func zeroMatchesEverywhereIsNoMatchesNotAWrap() {
    let c = FindControl()
    var s = c.began(c.initial(), running: sampleRequest)
    s = c.resolved(s, with: SearchSnapshot(
        phase: .done, nav: .exhausted, total: 0, totalIsFinal: true
    ), navDirection: .forward)
    #expect(s.display.notice == .noMatches)
    #expect(s.display.current == nil)
    #expect(s.display.position == nil)
    #expect(c.wrapNav(s) == nil) // never wrap into an empty result
    // Backward exhaustion with an unfinished scan still wraps (matches may
    // exist ahead): only the FINAL zero reads "No matches".
    var s2 = c.began(c.initial(), running: sampleRequest)
    s2 = c.resolved(s2, with: SearchSnapshot(
        phase: .scanning(progress: 0.4), nav: .exhausted, total: 0, totalIsFinal: false
    ), navDirection: .backward)
    #expect(s2.display.notice == .wrappedToEnd)
    #expect(c.wrapNav(s2) == .fromEnd)
}

@Test func stepAnchorsFollowThePinnedNavSemantics() {
    let c = FindControl()
    var s = c.began(c.initial(), running: sampleRequest)
    // No landing yet: navigate relative to the viewport.
    #expect(c.step(s, .forward, viewportRow: 42) == SearchNav(anchor: 42, direction: .forward))
    #expect(c.step(s, .backward, viewportRow: 42) == SearchNav(anchor: 42, direction: .backward))
    // With a current match: next = at-or-after row + 1; previous = strictly
    // before the current row (the core's backward rule — no decrement, and
    // previous-from-row-0 exhausts core-side).
    s = c.resolved(s, with: SearchSnapshot(
        phase: .done,
        nav: .found(SearchMatch(row: 10, column: 2), position: 2),
        total: 4, totalIsFinal: true
    ), navDirection: .forward)
    #expect(c.step(s, .forward, viewportRow: 0) == SearchNav(anchor: 11, direction: .forward))
    #expect(c.step(s, .backward, viewportRow: 0) == SearchNav(anchor: 10, direction: .backward))
    // No active search: stepping is a no-op.
    #expect(c.step(c.initial(), .forward, viewportRow: 5) == nil)
}

@Test func stopKeepsPartialsWhileEscAndReopenClearResultsButKeepTheDraft() {
    let c = FindControl()
    var s = c.initial()
    s.draft.mode = .text
    s.draft.text = "needle"
    s = c.began(s, running: sampleRequest)
    s = c.resolved(s, with: SearchSnapshot(
        phase: .scanning(progress: 0.3),
        nav: .found(SearchMatch(row: 2, column: 0), position: 1),
        total: 2, totalIsFinal: false
    ), navDirection: .forward)
    // The scan-cancel affordance: partial knowledge stays, progress UI ends.
    // This is the GENUINE user-invoked stop (the stop button / `cancelSearch`)
    // — it correctly reads "Stopped" even though a match had already landed.
    let stopped = c.stopped(s)
    #expect(stopped.display.notice == .stopped)
    #expect(stopped.display.progress == nil)
    #expect(stopped.display.total == 2)
    #expect(stopped.display.current == SearchMatch(row: 2, column: 0))
    #expect(stopped.draft == s.draft)
    // A cancelled-PHASE poll that CARRIES a landing (row 2) is structurally a
    // network net-park poll (the core navigates to the match, then re-parks at
    // cancelled in the SAME poll — api nfd_ac6). Mechanism-independent folds
    // still hold here: cancelled ends the progress UI, the count folds, and the
    // landing + its position are kept. The NOTICE for this input class
    // (cancelled + landing) is pinned by
    // networkFindParkedAtCancelledShowsCountNotStopped (it presents the count,
    // NEVER "Stopped") — so it is deliberately NOT asserted here.
    let viaPoll = c.resolved(s, with: SearchSnapshot(
        phase: .cancelled(progress: 0.3),
        nav: .found(SearchMatch(row: 2, column: 0), position: 1),
        total: 2, totalIsFinal: false
    ), navDirection: .forward)
    #expect(viaPoll.display.progress == nil)
    #expect(viaPoll.display.total == 2)
    #expect(viaPoll.display.current == SearchMatch(row: 2, column: 0))
    #expect(viaPoll.display.position == 1)
    // Esc: the active search and highlights clear (request nil), the DRAFT
    // is retained — re-running is one Enter.
    let closed = c.closed(s)
    #expect(closed.display == c.initial().display)
    #expect(closed.draft.text == "needle")
    // Dialect re-open (new document identity): same clearing, same retention.
    let reopened = c.invalidated(s)
    #expect(reopened.display == c.initial().display)
    #expect(reopened.draft == s.draft)
}

@Test func networkFindParkedAtCancelledShowsCountNotStopped() {
    // Network parity fix (mirrors the GTK `lsg_find_resolved` fix): on an
    // http_range document the core drives the nav to the first match, then
    // RE-PARKS the scan at LS_SEARCH_CANCELLED in the SAME poll (api nfd_ac6 —
    // it never runs a background network scan). So a SUCCESSFUL network find
    // poll carries BOTH a landing (found + 1-based position + a non-final
    // total >= 1) AND a cancelled phase. The unconditional
    // `.cancelled -> .stopped` mapping in `resolved` mislabels that success as
    // "Stopped" instead of the real "n of m".
    let c = FindControl()
    var s = c.began(c.initial(), running: sampleRequest)
    s = c.resolved(s, with: SearchSnapshot(
        phase: .cancelled(progress: 0.5),
        nav: .found(SearchMatch(row: 4, column: 1), position: 1),
        total: 3, totalIsFinal: false
    ), navDirection: .forward)
    // OUTCOME pinned (mechanism-agnostic — a landed-match guard OR a user-stop
    // flag both satisfy it): a cancelled poll that carries a landing is never
    // the "Stopped" notice.
    #expect(s.display.notice != .stopped)
    // ...and the count is presented: the landing, its 1-based position, and the
    // still-growing total are all shown.
    #expect(s.display.current == SearchMatch(row: 4, column: 1))
    #expect(s.display.position == 1)
    #expect(s.display.total == 3)
    #expect(!s.display.totalIsFinal)
}

@Test func resolvedIsStableOnIdlePollsAndClearedSessions() {
    let c = FindControl()
    // A stale poll after close/clear never resurrects a display.
    let cleared = c.initial()
    #expect(c.resolved(cleared, with: SearchSnapshot(
        phase: .done, nav: .exhausted, total: 0, totalIsFinal: true
    ), navDirection: .forward) == cleared)
    // A nil (idle) poll never resets an active display.
    let active = c.began(c.initial(), running: sampleRequest)
    #expect(c.resolved(active, with: nil, navDirection: .forward) == active)
}

// MARK: - Bridge: the real core through CoreDocumentSession
//
// find.csv data rows (header name,qty,note is ON):
//   0: Widget | 2   | alpha needle        4: Gizmo | 1e2 | delta
//   1: NEEDLE | 10  | beta                5: café  | 0.5 | CAFÉ
//   2: needle | 2.0 | gamma               6:       | 5.  | needleneedle
//   3: gadget | -3  | Needle point        7: plain | abc | end needle

@Test func bridgeRunsATextSearchWithLandingsCountsAndNavigation() async throws {
    let session = try await openFindFixture()
    defer { session.close() }
    // Insensitive (default): "needle" folds ASCII -> rows 0,1,2,3,6,7 (m = 6).
    try #require(session.startSearch(.text(query: "needle", scope: nil, caseSensitive: false)))
    session.navigateSearch(.fromTop)
    let first = try await waitSearch(session) {
        if case .found = $0.nav { return true } else { return false }
    }
    guard case let .found(match, position) = first.nav else {
        Issue.record("expected a landing"); return
    }
    #expect(match == SearchMatch(row: 0, column: 2)) // "alpha needle"
    #expect(position == 1)
    // The count grows to its exact final total.
    let done = try await waitSearch(session) { $0.totalIsFinal }
    #expect(done.total == 6)
    #expect(done.phase == .done)
    // After DONE navigation is synchronous (pinned): next / previous / ends.
    session.navigateSearch(SearchNav(anchor: 1, direction: .forward))
    #expect(session.searchStatus()?.nav == .found(SearchMatch(row: 1, column: 0), position: 2)) // "NEEDLE" folds
    session.navigateSearch(SearchNav(anchor: 1, direction: .backward))
    #expect(session.searchStatus()?.nav == .found(SearchMatch(row: 0, column: 2), position: 1))
    session.navigateSearch(.fromEnd)
    #expect(session.searchStatus()?.nav == .found(SearchMatch(row: 7, column: 2), position: 6))
    session.navigateSearch(SearchNav(anchor: 8, direction: .forward))
    #expect(session.searchStatus()?.nav == .exhausted) // wrap decision is the view-model's
    session.navigateSearch(.fromTop)
    #expect(session.searchStatus()?.nav == .found(SearchMatch(row: 0, column: 2), position: 1))
    // Cancel after completion: DONE persists (mirrors ls_search_cancel).
    session.cancelSearch()
    #expect(session.searchStatus()?.phase == .done)
    // Match case OFF: an UPPERCASE query still folds — "Needle" matches the
    // SAME rows as "needle" (D1: the retired smart-case "uppercase => exact"
    // auto-rule is gone; the flag is the only thing that decides folding).
    try #require(session.startSearch(.text(query: "Needle", scope: nil, caseSensitive: false)))
    let folded = try await waitSearch(session) { $0.totalIsFinal }
    #expect(folded.total == 6)
    // Match case ON: byte-exact — only "Needle point" (row 3, col 2) matches.
    try #require(session.startSearch(.text(query: "Needle", scope: nil, caseSensitive: true)))
    let exact = try await waitSearch(session) { $0.totalIsFinal }
    #expect(exact.total == 1)
    session.navigateSearch(.fromTop)
    #expect(session.searchStatus()?.nav == .found(SearchMatch(row: 3, column: 2), position: 1))
}

@Test func bridgeRunsAWhereSearchAndEnforcesValidation() async throws {
    let session = try await openFindFixture()
    defer { session.close() }
    // qty <= 2 numerically: rows 0 (2), 2 (2.0), 3 (-3), 5 (0.5) — m = 4.
    try #require(session.startSearch(.predicate(column: 1, comparison: .lessOrEqual, value: "2", caseSensitive: false)))
    session.navigateSearch(.fromTop)
    let first = try await waitSearch(session) {
        if case .found = $0.nav { return true } else { return false }
    }
    guard case let .found(match, position) = first.nav else {
        Issue.record("expected a landing"); return
    }
    #expect(match == SearchMatch(row: 0, column: 1))
    #expect(position == 1)
    let done = try await waitSearch(session) { $0.totalIsFinal }
    #expect(done.total == 4)
    session.navigateSearch(.fromEnd)
    #expect(session.searchStatus()?.nav == .found(SearchMatch(row: 5, column: 1), position: 4))
    // Exact-decimal equality distinguishes representations ("2.0" vs "2");
    // digits are unaffected by ASCII case folding, so this holds by default.
    #expect(try await matchedRows(session, .predicate(column: 1, comparison: .equals, value: "2.0", caseSensitive: false)) == [2])
    #expect(try await matchedRows(session, .predicate(column: 1, comparison: .equals, value: "2", caseSensitive: false)) == [0])
    // The empty value matches the empty cell (ragged/pad rule), independent of case.
    #expect(try await matchedRows(session, .predicate(column: 0, comparison: .equals, value: "", caseSensitive: false)) == [6])
    // Core-side enforcement mirrors the composer: rejected starts change
    // nothing (the previous search stays polled).
    try #require(session.startSearch(.predicate(column: 1, comparison: .lessOrEqual, value: "2", caseSensitive: false)))
    _ = try await waitSearch(session) { $0.totalIsFinal }
    #expect(session.startSearch(.predicate(column: 1, comparison: .lessThan, value: "abc", caseSensitive: false)) == false)
    #expect(session.startSearch(.text(query: "", scope: nil, caseSensitive: false)) == false)
    #expect(session.startSearch(.predicate(column: 9, comparison: .equals, value: "x", caseSensitive: false)) == false)
    #expect(session.searchStatus()?.total == 4)
    #expect(session.searchStatus()?.totalIsFinal == true)
}

@Test func bridgePredicateEqualityHonorsMatchCase() async throws {
    // ARCH-search-case-mode B4/B5 + C3 (predicate half): col 0 holds both
    // "NEEDLE" (row 1) and "needle" (row 2). `= needle` folds ASCII by default
    // (matches BOTH), and is byte-exact when Match case is ON (only "needle").
    let session = try await openFindFixture()
    defer { session.close() }
    // Insensitive (default): EQ matches "NEEDLE" and "needle".
    #expect(try await matchedRows(session,
        .predicate(column: 0, comparison: .equals, value: "needle", caseSensitive: false)) == [1, 2])
    // NE is the exact complement.
    #expect(try await matchedRows(session,
        .predicate(column: 0, comparison: .notEquals, value: "needle", caseSensitive: false)) == [0, 3, 4, 5, 6, 7])
    // Match case ON: EQ is byte-exact — only the exact "needle" (row 2).
    #expect(try await matchedRows(session,
        .predicate(column: 0, comparison: .equals, value: "needle", caseSensitive: true)) == [2])
}

@Test func bridgeOrderingPredicatesIgnoreMatchCase() async throws {
    // ARCH-search-case-mode B7: the numeric ordering operators produce the SAME
    // verdict regardless of Match case. qty (col 1) <= 2 -> rows 0,2,3,5 in
    // both modes.
    let session = try await openFindFixture()
    defer { session.close() }
    let insensitive = try await matchedRows(session,
        .predicate(column: 1, comparison: .lessOrEqual, value: "2", caseSensitive: false))
    let sensitive = try await matchedRows(session,
        .predicate(column: 1, comparison: .lessOrEqual, value: "2", caseSensitive: true))
    #expect(insensitive == [0, 2, 3, 5])
    #expect(sensitive == [0, 2, 3, 5])
}

@Test func bridgeInsensitiveTextNeverFoldsNonASCII() async throws {
    // ARCH-search-case-mode B3: ASCII folds, but bytes >= 0x80 always compare
    // exactly, even insensitively. "CAFÉ" (uppercase, non-ASCII É) matches only
    // the exact "CAFÉ" cell (row 5, col 2) — NOT the "café" cell (col 0), whose
    // é differs from É in the non-ASCII bytes.
    let session = try await openFindFixture()
    defer { session.close() }
    #expect(try await matchedRows(session, .text(query: "CAFÉ", scope: nil, caseSensitive: false)) == [5])
}

@Test func bridgeScopesTextSearchesExactly() async throws {
    let session = try await openFindFixture()
    defer { session.close() }
    // "needle" per column: col 0 -> rows 1,2; col 2 -> rows 0,3,6,7.
    #expect(try await matchedRows(session, .text(query: "needle", scope: [0], caseSensitive: false)) == [1, 2])
    #expect(try await matchedRows(session, .text(query: "needle", scope: [2], caseSensitive: false)) == [0, 3, 6, 7])
    #expect(try await matchedRows(session, .text(query: "needle", scope: [1], caseSensitive: false)) == [])
    #expect(try await matchedRows(session, .text(query: "needle", scope: [0, 2], caseSensitive: false)) == [0, 1, 2, 3, 6, 7])
}

@Test func aFreshOrReopenedSessionHasZeroSearchState() async throws {
    // Header ON: "name" lives in the header record — never matched.
    let first = try await openFindFixture()
    #expect(first.searchStatus() == nil) // fresh session: no search state
    try #require(first.startSearch(.text(query: "name", scope: nil, caseSensitive: false)))
    let headerOn = try await waitSearch(first) { $0.totalIsFinal }
    #expect(headerOn.total == 0)
    first.close()
    // Dialect re-open (forced header OFF): search state is gone with the old
    // handle, and the re-dialected document matches on its new data row 0.
    let second = try await openFindFixture(forcing: DialectOverride(header: .forcedOff))
    defer { second.close() }
    #expect(second.searchStatus() == nil)
    try #require(second.startSearch(.text(query: "name", scope: nil, caseSensitive: false)))
    let headerOff = try await waitSearch(second) { $0.totalIsFinal }
    #expect(headerOff.total == 1)
    second.navigateSearch(.fromTop)
    #expect(second.searchStatus()?.nav == .found(SearchMatch(row: 0, column: 0), position: 1))
}
