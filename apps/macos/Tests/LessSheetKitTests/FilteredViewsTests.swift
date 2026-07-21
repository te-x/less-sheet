// Frozen behavior tests — filtered-views slice (planner-owned).
// ARCH-filtered-views app criteria 16–18: the filtered banner view-model's
// pinned semantics, and the filter bridge against the REAL linked Zig core —
// applying a filter (in-place remap into filtered coordinates), the source-row
// gutter mapping, clear + re-anchor, jump-by-original-row, find-within-filter,
// the empty state, and reset semantics. Semantics are normative in
// Sources/Contracts/FilterControl.swift + DocumentSession.swift and
// api/lesssheet.h FILTERED VIEWS.
//
// ARCH-search-case-mode A3/C4 (filter half): a filter inherits the request's
// `caseSensitive` exactly like find (bridgeTextFilterHonorsMatchCase), so a
// live "Match case" toggle re-applies with the new folding.
//
// Determinism: find.csv is far below the core's head budget, so filter/match
// scans complete in milliseconds; polls are bounded (10 s) and every bridge
// test asserts `setFilter == true` via #require BEFORE any poll loop, so an
// unimplemented seed fails fast instead of waiting.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers

private func findCSVPath() throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "find", withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture find.csv"
    )
    return url.path(percentEncoded: false)
}

// find.csv data rows (source row numbers):
//   0 Widget,2,alpha needle      1 NEEDLE,10,beta       2 needle,2.0,gamma
//   3 gadget,-3,Needle point      4 Gizmo,1e2,delta      5 café,0.5,CAFÉ
//   6 ,5.,needleneedle            7 plain,abc,end needle
// TEXT "needle" (case-insensitive by default) -> sources 0,1,2,3,6,7 (m = 6).
// WHERE qty(col 1) >= 2                        -> sources 0,1,2,4,6   (m = 5).

private func openFiltered(forcing override: DialectOverride = .sniffAll) async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: findCSVPath(), forcing: override)
}

/// Poll the filter status until `predicate` holds (<= 10 s).
private func waitFilter(
    _ session: any DocumentSession,
    until predicate: (FilterSnapshot) -> Bool
) async throws -> FilterSnapshot {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if let snap = session.filterStatus(), predicate(snap) { return snap }
        try #require(clock.now - start < .seconds(10), "filter poll timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Poll the search status until `predicate` holds (<= 10 s).
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

/// Issue a navigation and poll until it resolves; nil on exhaustion.
private func navFound(
    _ session: any DocumentSession, _ nav: SearchNav
) async throws -> (row: UInt64, position: UInt64)? {
    session.navigateSearch(nav)
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if let snap = session.searchStatus() {
            switch snap.nav {
            case let .found(match, position): return (match.row, position)
            case .exhausted: return nil
            default: break
            }
        }
        try #require(clock.now - start < .seconds(10), "nav timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Poll the jump slot until it lands (<= 10 s); returns the landed row.
private func waitJump(_ session: any DocumentSession) async throws -> UInt64 {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if case let .done(landedRow) = session.jumpStatus() { return landedRow }
        try #require(clock.now - start < .seconds(10), "jump timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Contract conformance pins (signature drift fails this build)

@Test func filterContractConformancePins() {
    let _: any FilterControlling = FilterControl()
}

// MARK: - ABI agreement: C header <-> Swift contract

@Test func filterABIConstantsArePinned() {
    #expect(LS_FILTER_IDLE.rawValue == 0)
    #expect(LS_FILTER_SCANNING.rawValue == 1)
    #expect(LS_FILTER_DONE.rawValue == 2)
    #expect(LS_FILTER_CANCELLED.rawValue == 3)
    #expect(UInt64(LS_NO_ROW) == UInt64.max)
}

// MARK: - The banner view-model (pure; no core)

@Test func bannerViewModelFollowsThePinnedSemantics() {
    let ctl = FilterControl()
    let mEstimate = RowCountInfo(count: 1000, isExact: false)
    let mExact = RowCountInfo(count: 8, isExact: true)
    // No filter -> no banner.
    #expect(ctl.banner(nil, documentRows: mExact) == nil)
    // Scanning: N so far + progress %, not final; M rendered as an estimate.
    #expect(
        ctl.banner(FilterSnapshot(phase: .scanning(progress: 0.4), total: 3, totalIsFinal: false), documentRows: mEstimate)
            == FilterBanner(matching: 3, documentRows: 1000, documentRowsEstimated: true, matchingIsFinal: false, progress: 0.4)
    )
    // Done: progress nil, final; M exact.
    #expect(
        ctl.banner(FilterSnapshot(phase: .done, total: 5, totalIsFinal: true), documentRows: mExact)
            == FilterBanner(matching: 5, documentRows: 8, documentRowsEstimated: false, matchingIsFinal: true, progress: nil)
    )
    // Cancelled: frozen progress, not final (the filter mode persists).
    #expect(
        ctl.banner(FilterSnapshot(phase: .cancelled(progress: 0.6), total: 2, totalIsFinal: false), documentRows: mExact)
            == FilterBanner(matching: 2, documentRows: 8, documentRowsEstimated: false, matchingIsFinal: false, progress: 0.6)
    )
    // Empty result: done with zero matches -> "no matching rows".
    #expect(ctl.banner(FilterSnapshot(phase: .done, total: 0, totalIsFinal: true), documentRows: mExact)?.isEmptyResult == true)
}

// MARK: - Bridge: applying / clearing a filter (criteria 16, 13)

@Test func bridgeAppliesAWhereFilterAndRemapsRowsToFilteredCoordinates() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    // qty (col 1) >= 2 -> source rows 0,1,2,4,6 (m = 5).
    try #require(session.setFilter(.predicate(column: 1, comparison: .greaterOrEqual, value: "2", caseSensitive: false)), "core rejected the filter")
    let done = try await waitFilter(session) { $0.totalIsFinal }
    #expect(done.total == 5)
    #expect(session.rowCount() == RowCountInfo(count: 5, isExact: true))
    // The window serves the matching rows in file order (filtered coordinates).
    let win = session.setWindow(firstRow: 0, rowCount: 5)
    #expect(win.rows.count == 5)
    #expect(win.rows[0][0] == "Widget")        // source 0
    #expect(win.rows[1][0] == "NEEDLE")        // source 1
    #expect(win.rows[3][0] == "Gizmo")         // source 4
    #expect(win.rows[4][2] == "needleneedle")  // source 6
    // Each filtered row maps back to its original data-row number (the gutter).
    #expect([0, 1, 2, 3, 4].map { session.sourceRow(UInt64($0)) } == [0, 1, 2, 4, 6])
    // The header record is unaffected by the filter.
    #expect(session.headerCells == ["name", "qty", "note"])
}

@Test func bridgeAppliesATextFilterCaseInsensitiveByDefault() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    try #require(session.setFilter(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the filter")
    let done = try await waitFilter(session) { $0.totalIsFinal }
    #expect(done.total == 6) // sources 0,1,2,3,6,7
    _ = session.setWindow(firstRow: 0, rowCount: 6)
    #expect((0..<6).map { session.sourceRow(UInt64($0)) } == [0, 1, 2, 3, 6, 7])
}

@Test func bridgeTextFilterHonorsMatchCase() async throws {
    // ARCH-search-case-mode A3 + C4 (filter half): the filter inherits
    // `caseSensitive` exactly like find. Default (insensitive) "Needle" folds
    // to the 6 needle rows; Match case ON is byte-exact — only source row 3
    // ("Needle point"). (The ON assertions are RED until the bridge marshals
    // the flag; re-issuing on toggle is the implementer's UI glue.)
    let session = try await openFiltered()
    defer { session.close() }
    // Insensitive (default): an uppercase query folds -> 6 rows.
    try #require(session.setFilter(.text(query: "Needle", scope: nil, caseSensitive: false)), "core rejected the filter")
    #expect(try await waitFilter(session) { $0.totalIsFinal }.total == 6)
    // Match case ON: byte-exact -> only "Needle point".
    try #require(session.setFilter(.text(query: "Needle", scope: nil, caseSensitive: true)), "core rejected the filter")
    let done = try await waitFilter(session) { $0.totalIsFinal }
    #expect(done.total == 1)
    #expect(session.rowCount() == RowCountInfo(count: 1, isExact: true))
    _ = session.setWindow(firstRow: 0, rowCount: 1)
    #expect(session.sourceRow(0) == 3) // source row 3 = "Needle point"
}

@Test func bridgeApplyAsFilterReusesTheFindSubmitRequest() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    // Compose a Where predicate in the Find popup, then "Apply as filter": the
    // app validates via FindControlling.submit and routes .run(request) to
    // setFilter (ARCH req. 10 — identical grammar, no new UI).
    var draft = FindDraft.empty
    draft.mode = .predicate
    draft.column = 1
    draft.comparison = .greaterOrEqual
    draft.value = "2"
    let composed = FindSession(draft: draft, display: FindControl().initial().display)
    guard case let .run(request) = FindControl().submit(composed, visibleColumns: [0, 1, 2], columnCount: 3) else {
        Issue.record("apply-as-filter should validate to .run")
        return
    }
    try #require(session.setFilter(request), "core rejected the applied filter")
    let done = try await waitFilter(session) { $0.totalIsFinal }
    #expect(done.total == 5)
}

@Test func bridgeClearRestoresIdentityAndReanchorsOnTheTopSourceRow() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    try #require(session.setFilter(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the filter")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    // Viewport top at filtered row 4 (source row 6): capture the re-anchor row.
    _ = session.setWindow(firstRow: 4, rowCount: 2)
    let anchor = try #require(session.sourceRow(4))
    #expect(anchor == 6)
    // Clear -> identity view; the captured source row addresses the same data.
    session.clearFilter()
    #expect(session.filterStatus() == nil)
    #expect(session.rowCount() == RowCountInfo(count: 8, isExact: true))
    let win = session.setWindow(firstRow: anchor, rowCount: 1)
    #expect(win.rows.first?[2] == "needleneedle")  // physical data row 6
    #expect(session.sourceRow(anchor) == anchor)   // identity again
}

// MARK: - Bridge: jump, find, empty, source-row window domain (criteria 17, 18)

@Test func bridgeJumpUnderFilterTakesOriginalRowNumbers() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    // needle -> filtered 0..5 == sources 0,1,2,3,6,7.
    try #require(session.setFilter(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the filter")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    // "go to" original row 4 -> nearest match >= 4 is source 6 = filtered index 4.
    session.startJump(to: 4)
    let landed = try await waitJump(session)
    #expect(landed == 4) // FILTERED index
    _ = session.setWindow(firstRow: landed, rowCount: 1)
    #expect(session.sourceRow(landed) == 6) // gutter shows an original >= 4
    // Past EOF -> clamp to the last match: source 7 = filtered index 5.
    session.startJump(to: 1_000_000)
    let clamped = try await waitJump(session)
    #expect(clamped == 5)
    _ = session.setWindow(firstRow: clamped, rowCount: 1)
    #expect(session.sourceRow(clamped) == 7)
}

@Test func bridgeFindComposesWithinTheActiveFilter() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    // Filter qty >= 2 -> source 0,1,2,4,6 (filtered 0..4).
    try #require(session.setFilter(.predicate(column: 1, comparison: .greaterOrEqual, value: "2", caseSensitive: false)), "core rejected the filter")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    // Find "needle" within the filter: filtered rows 0,1,2,4 match (filtered 3 =
    // source 4 "Gizmo" does not) -> total within the filter = 4.
    try #require(session.startSearch(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the search")
    let sdone = try await waitSearch(session) { $0.totalIsFinal }
    #expect(sdone.total == 4)
    // found_row is a FILTERED index; navigation stays within the filtered view;
    // position (n of m) counts rows satisfying BOTH predicates.
    let m0 = try #require(try await navFound(session, .fromTop))
    #expect(m0.row == 0 && m0.position == 1)
    let m1 = try #require(try await navFound(session, SearchNav(anchor: 1, direction: .forward)))
    #expect(m1.row == 1 && m1.position == 2)
    let m3 = try #require(try await navFound(session, SearchNav(anchor: 3, direction: .forward)))
    #expect(m3.row == 4 && m3.position == 4) // skips filtered 3 (no match)
    let exhausted = try await navFound(session, SearchNav(anchor: 5, direction: .forward))
    #expect(exhausted == nil)
    // The found filtered row maps back to its source row for the gutter.
    _ = session.setWindow(firstRow: 4, rowCount: 1)
    #expect(session.sourceRow(4) == 6)
}

@Test func bridgeEmptyFilterShowsNoMatchingRows() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    try #require(session.setFilter(.text(query: "zzz-no-such-substring", scope: nil, caseSensitive: false)), "core rejected the filter")
    let done = try await waitFilter(session) { $0.totalIsFinal }
    #expect(done.total == 0)
    #expect(session.rowCount() == RowCountInfo(count: 0, isExact: true))
    #expect(session.setWindow(firstRow: 0, rowCount: 10).rows.isEmpty)
    #expect(session.sourceRow(0) == nil)
}

@Test func bridgeSourceRowIsNilOutsideTheMaterializedWindow() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    try #require(session.setFilter(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the filter")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    _ = session.setWindow(firstRow: 2, rowCount: 2) // filtered rows 2,3 -> sources 2,3
    #expect(session.sourceRow(2) == 2)
    #expect(session.sourceRow(3) == 3)
    #expect(session.sourceRow(0) == nil)  // outside the materialized window
    #expect(session.sourceRow(99) == nil) // outside the view range
}

@Test func bridgeSettingOrClearingResetsFindAndAFreshSessionHasNeither() async throws {
    let session = try await openFiltered()
    defer { session.close() }
    // A running find in the identity view...
    try #require(session.startSearch(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the search")
    _ = try await waitSearch(session) { $0.totalIsFinal }
    #expect(session.searchStatus() != nil)
    // ...is RESET when a filter is set (the coordinate space changed).
    try #require(session.setFilter(.predicate(column: 1, comparison: .greaterOrEqual, value: "2", caseSensitive: false)), "core rejected the filter")
    #expect(session.searchStatus() == nil)
    // A find within the filter, then CLEARING the filter, resets it again.
    try #require(session.startSearch(.text(query: "needle", scope: nil, caseSensitive: false)), "core rejected the search")
    _ = try await waitSearch(session) { $0.totalIsFinal }
    session.clearFilter()
    #expect(session.searchStatus() == nil)
    // A dialect RE-OPEN is a fresh session (new document identity): no filter,
    // no search — the state died with the old handle.
    try #require(session.setFilter(.predicate(column: 1, comparison: .greaterOrEqual, value: "2", caseSensitive: false)), "core rejected the filter")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    let reopened = try await openFiltered(forcing: DialectOverride(header: .forcedOff))
    defer { reopened.close() }
    #expect(reopened.filterStatus() == nil)
    #expect(reopened.searchStatus() == nil)
}
