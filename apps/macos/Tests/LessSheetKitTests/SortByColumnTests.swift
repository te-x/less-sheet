// Frozen behavior tests — sort-by-column slice (planner-owned).
// ARCH-sort-by-column app criterion AC-s14 (as amended by Amendment 1): the
// pure three-state CYCLE that both the header click and ⇧⌘S drive, the header
// indicator, the one declaration of the menu item + accelerator, and the sort
// bridge against the REAL linked Zig core (apply, sorted coordinates WITHOUT
// waiting for the pass, descending, composition with a filter, clear restoring
// the pre-sort order, session-only across a re-open).
// Semantics are normative in Sources/Contracts/SortControl.swift +
// DocumentSession.swift and api/lesssheet.h SORTED VIEWS.
//
// WHY THE CYCLE IS PINNED SO HARD. The feature has three entry points into ONE
// state machine — a header click, ⇧⌘S on the keyboard cursor's column, and the
// progress affordance's Cancel. The truth table below is exhaustive over
// (phase x same/different column x direction) precisely so the three cannot
// drift apart in the display layer.
//
// Determinism: find.csv is far below the core's head budget, so a key pass
// completes in milliseconds; every bridge test asserts `setSort == true` via
// #require BEFORE any poll loop, so an unimplemented seed fails fast instead of
// waiting out the timeout.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers

private func sortFixturePath() throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "find", withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture find.csv"
    )
    return url.path(percentEncoded: false)
}

// find.csv data rows (source row numbers), header "name,qty,note":
//   0 Widget,2,alpha needle      1 NEEDLE,10,beta       2 needle,2.0,gamma
//   3 gadget,-3,Needle point      4 Gizmo,1e2,delta      5 café,0.5,CAFÉ
//   6 ,5.,needleneedle            7 plain,abc,end needle
//
// Sorting by NAME (col 0) with no type override — the effective type is UNKNOWN,
// which sorts as TEXT: ASCII case folded, byte-exact tiebreak, then source
// order. Ascending:
//   ""(6) < café(5) < gadget(3) < Gizmo(4) < NEEDLE(1) < needle(2) < plain(7) < Widget(0)
private let sortedByNameAscending: [UInt64] = [6, 5, 3, 4, 1, 2, 7, 0]
private let sortedByNameDescending: [UInt64] = [0, 7, 2, 1, 4, 3, 5, 6]

private func openForSort() async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: sortFixturePath(), forcing: .sniffAll)
}

/// Poll the sort status until `predicate` holds (<= 10 s).
private func waitSort(
    _ session: any DocumentSession,
    until predicate: (SortSnapshot) -> Bool
) async throws -> SortSnapshot {
    let clock = ContinuousClock()
    let start = clock.now
    while true {
        if let snap = session.sortStatus(), predicate(snap) { return snap }
        try #require(clock.now - start < .seconds(10), "sort poll timed out")
        try await Task.sleep(for: .milliseconds(2))
    }
}

private func waitSortActive(_ session: any DocumentSession) async throws -> SortSnapshot {
    try await waitSort(session) { $0.phase == .active }
}

/// The view's gutter mapping for its first `count` rows.
private func viewSourceRows(_ session: any DocumentSession, _ count: Int) -> [UInt64?] {
    _ = session.setWindow(firstRow: 0, rowCount: count)
    return (0..<count).map { session.sourceRow(UInt64($0)) }
}

// MARK: - Contract conformance pins (signature drift fails this build)

@Test func sortContractConformancePins() {
    let _: any SortCycling = SortCycle()
}

// MARK: - ABI agreement: C header <-> Swift contract

@Test func sortABIConstantsArePinned() {
    #expect(LS_SORT_ASCENDING.rawValue == 0)
    #expect(LS_SORT_DESCENDING.rawValue == 1)
    #expect(LS_SORT_IDLE.rawValue == 0)
    #expect(LS_SORT_BUILDING.rawValue == 1)
    #expect(LS_SORT_ACTIVE.rawValue == 2)
    #expect(LS_SORT_PARKED.rawValue == 3)
    #expect(LS_SORT_FAILED.rawValue == 4)
    #expect(LS_SORT_OK.rawValue == 0)
    #expect(LS_SORT_ERROR_STORAGE.rawValue == 1)
    #expect(LS_SORT_ERROR_MEMORY.rawValue == 2)
    #expect(MemoryLayout<ls_sort_status>.size == 24)
}

// MARK: - The command declaration (one source for the menu and the shortcut)

@Test func sortCommandIsDeclaredOnce() {
    // ⇧⌘S, in a View menu, on "Sort by Column". The View-menu item and the
    // grid's key routing must BOTH read these values — a hand-typed second copy
    // is exactly the drift this constant exists to prevent.
    #expect(SortCommand.menuSection == "View")
    #expect(SortCommand.menuTitle == "Sort by Column")
    #expect(SortCommand.accelerator == KeyAccelerator(key: "s", command: true, shift: true))
    #expect(SortCommand.accelerator.option == false)
}

// MARK: - The cycle (pure; no core) — the exhaustive truth table

@Test func cycleStartsFreshOnAnUnsortedOrDifferentColumn() {
    let c = SortCycle()
    // No sort at all -> ascending on the column that was acted on.
    #expect(c.next(nil, for: 2) == .sort(column: 2, direction: .ascending))
    // A DIFFERENT column, whatever the current phase or direction -> fresh
    // ascending on the new column (never "continue the other column's cycle").
    for phase: SortPhase in [.active, .building(progress: 0.5), .parked(progress: 0.5), .failed(.storage)] {
        for dir: SortDirection in [.ascending, .descending] {
            let snap = SortSnapshot(phase: phase, column: 0, direction: dir)
            #expect(c.next(snap, for: 1) == .sort(column: 1, direction: .ascending))
        }
    }
}

@Test func cycleAdvancesAscendingToDescendingToOffOnTheSortedColumn() {
    let c = SortCycle()
    #expect(c.next(SortSnapshot(phase: .active, column: 1, direction: .ascending), for: 1)
            == .sort(column: 1, direction: .descending))
    #expect(c.next(SortSnapshot(phase: .active, column: 1, direction: .descending), for: 1)
            == .clear)
}

@Test func cycleOnAnUnlandedPassMeansStop() {
    // Acting on a pass that has not landed is STOP — the same intent the
    // progress affordance's Cancel issues, so the two cannot diverge.
    // (`ls_sort_clear` is both "remove the sort" and "cancel the build".)
    let c = SortCycle()
    for phase: SortPhase in [.building(progress: 0.0), .building(progress: 0.9), .parked(progress: 0.3)] {
        for dir: SortDirection in [.ascending, .descending] {
            #expect(c.next(SortSnapshot(phase: phase, column: 2, direction: dir), for: 2) == .clear)
        }
    }
}

@Test func cycleOnAFailedPassRetriesRatherThanAdvancing() {
    // "That didn't work" must not silently move to a direction the user never
    // saw applied; the core re-runs the pass for an identical request on a
    // FAILED sort, so a click retries.
    let c = SortCycle()
    for failure: SortFailure in [.storage, .memory] {
        #expect(c.next(SortSnapshot(phase: .failed(failure), column: 0, direction: .ascending), for: 0)
                == .sort(column: 0, direction: .ascending))
        #expect(c.next(SortSnapshot(phase: .failed(failure), column: 0, direction: .descending), for: 0)
                == .sort(column: 0, direction: .descending))
    }
}

@Test func indicatorMarksOnlyTheSortColumnAndDistinguishesPendingFromLanded() {
    let c = SortCycle()
    #expect(c.indicator(nil, for: 0) == .none)
    let active = SortSnapshot(phase: .active, column: 1, direction: .descending)
    #expect(c.indicator(active, for: 0) == .none)               // a different column
    #expect(c.indicator(active, for: 1)
            == SortIndicator(direction: .descending, isPending: false, didFail: false))
    // While the pass is outstanding the indicator SHOWS but is marked pending:
    // the grid IS already re-ordered (it shows the exact sorted top of what has
    // been scanned) but that top is still REFINING and rows past the prefix are
    // not yet servable, so the header must not claim a settled order.
    for phase: SortPhase in [.building(progress: 0.2), .parked(progress: 0.2)] {
        #expect(c.indicator(SortSnapshot(phase: phase, column: 1, direction: .ascending), for: 1)
                == SortIndicator(direction: .ascending, isPending: true, didFail: false))
    }
    #expect(c.indicator(SortSnapshot(phase: .failed(.storage), column: 1, direction: .ascending), for: 1)
            == SortIndicator(direction: .ascending, isPending: false, didFail: true))
}

@Test func snapshotDerivationsDriveTheProgressAffordance() {
    // `isWorking` is what the shared delayed-progress gate and the Cancel
    // affordance key on; `progress` is the fraction, and only while working.
    #expect(SortSnapshot(phase: .building(progress: 0.25), column: 0, direction: .ascending).isWorking)
    #expect(SortSnapshot(phase: .parked(progress: 0.25), column: 0, direction: .ascending).isWorking)
    #expect(!SortSnapshot(phase: .active, column: 0, direction: .ascending).isWorking)
    #expect(!SortSnapshot(phase: .failed(.memory), column: 0, direction: .ascending).isWorking)
    #expect(SortSnapshot(phase: .building(progress: 0.25), column: 0, direction: .ascending).progress == 0.25)
    #expect(SortSnapshot(phase: .parked(progress: 0.5), column: 0, direction: .ascending).progress == 0.5)
    #expect(SortSnapshot(phase: .active, column: 0, direction: .ascending).progress == nil)
    #expect(SortSnapshot(phase: .failed(.storage), column: 0, direction: .ascending).progress == nil)
}

// MARK: - Bridge: applying a sort against the real core

@Test func bridgeSortsByColumnAndServesSortedCoordinates() async throws {
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")
    let active = try await waitSortActive(session)
    #expect(active.column == 0)
    #expect(active.direction == .ascending)
    // The window serves the rows in SORT order ...
    let win = session.setWindow(firstRow: 0, rowCount: 8)
    #expect(win.rows.count == 8)
    #expect(win.rows[0][0] == "")        // source 6
    #expect(win.rows[1][0] == "café")    // source 5
    #expect(win.rows[4][0] == "NEEDLE")  // source 1 — fold-tie with "needle",
    #expect(win.rows[5][0] == "needle")  //            broken byte-exact
    #expect(win.rows[7][0] == "Widget")  // source 0
    // ... and each sorted row maps back to its ORIGINAL data-row number.
    #expect(viewSourceRows(session, 8) == sortedByNameAscending.map { Optional($0) })
    // The row set is unchanged and the header is untouched.
    #expect(session.rowCount() == RowCountInfo(count: 8, isExact: true))
    #expect(session.headerCells == ["name", "qty", "note"])
}

@Test func bridgeDescendingIsTheAscendingOrderReversed() async throws {
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")
    _ = try await waitSortActive(session)
    #expect(viewSourceRows(session, 8) == sortedByNameAscending.map { Optional($0) })
    // The flip is instant: the snapshot is already ACTIVE on the very next poll,
    // with no BUILDING in between (the permutation is read backwards).
    try #require(session.setSort(column: 0, direction: .descending), "core rejected the flip")
    let flipped = try #require(session.sortStatus())
    #expect(flipped.phase == .active)
    #expect(flipped.direction == .descending)
    #expect(viewSourceRows(session, 8) == sortedByNameDescending.map { Optional($0) })
}

@Test func bridgeSortComposesOverAnActiveFilter() async throws {
    let session = try await openForSort()
    defer { session.close() }
    // qty (col 1) >= 2 -> source rows 0,1,2,4,6 (m = 5).
    try #require(session.setFilter(.predicate(column: 1, comparison: .greaterOrEqual, value: "2", caseSensitive: false)),
                 "core rejected the filter")
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")
    _ = try await waitSortActive(session)
    // The sorted row set IS the filtered row set, in name order:
    //   ""(6) < NEEDLE(1) < needle(2) < Widget(0), with Gizmo(4) between them.
    #expect(session.rowCount() == RowCountInfo(count: 5, isExact: true))
    #expect(viewSourceRows(session, 5) == [6, 4, 1, 2, 0].map { Optional($0) })
    // The key pass ran the filter to completion on its way through.
    #expect(session.filterStatus()?.totalIsFinal == true)
}

@Test func bridgeServesSortedCoordinatesWithoutWaitingForTheKeyPass() async throws {
    // AC-s14 / Amendment 1: latency beats throughput. The window is read on the
    // very next line after `setSort` — NO poll, NO wait for `.active` — and it
    // must already be in sorted coordinates (the converging prefix). An
    // implementation that keeps the previous order until the pass completes
    // fails HERE, which is the whole point of the amendment.
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")
    let win = session.setWindow(firstRow: 0, rowCount: 8)
    #expect(win.rows.isEmpty == false, "a sort must serve its converging prefix immediately")
    // find.csv's 8 rows are fully scanned in one block, so the prefix here is
    // the whole (already exact) order; on a large document it would be the
    // sorted top of the scanned region instead. Either way it is never the
    // pre-sort order.
    #expect(session.sourceRow(0) == sortedByNameAscending[0])
    #expect(win.rows[0][0] == "")
    // The phase is honest about it: never `.active` until the order is final.
    let snap = try #require(session.sortStatus())
    #expect(snap.column == 0)
    #expect(snap.direction == .ascending)
}

@Test func bridgeCancelDuringABuildRestoresThePreSortOrder() async throws {
    // AC-s7 / Amendment 1: `clearSort` is also the cancel verb, and the view
    // comes back in FILE order — the converging prefix is gone, not frozen.
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.setSort(column: 0, direction: .descending), "core rejected the sort")
    session.clearSort()
    #expect(session.sortStatus() == nil)
    #expect(viewSourceRows(session, 8) == (0..<8).map { Optional(UInt64($0)) })
    #expect(session.setWindow(firstRow: 0, rowCount: 8).rows[0][0] == "Widget")
}

@Test func bridgeClearRestoresFileOrder() async throws {
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")
    _ = try await waitSortActive(session)
    session.clearSort()
    #expect(session.sortStatus() == nil)
    #expect(viewSourceRows(session, 8) == (0..<8).map { Optional(UInt64($0)) })
    #expect(session.setWindow(firstRow: 0, rowCount: 8).rows[0][0] == "Widget")
}

@Test func bridgeRejectsAnOutOfRangeColumnAndChangesNothing() async throws {
    let session = try await openForSort()
    defer { session.close() }
    #expect(session.setSort(column: 3, direction: .ascending) == false)   // columnCount == 3
    #expect(session.setSort(column: 99, direction: .descending) == false)
    #expect(session.sortStatus() == nil)
    #expect(viewSourceRows(session, 8) == (0..<8).map { Optional(UInt64($0)) })
    // ... and a VALID column is accepted (the half a permanently-rejecting
    // implementation would otherwise pass vacuously).
    #expect(session.setSort(column: 2, direction: .ascending) == true)
}

@Test func bridgeSortIsSessionOnlyAcrossAReopen() async throws {
    let first = try await openForSort()
    try #require(first.setSort(column: 0, direction: .descending), "core rejected the sort")
    _ = try await waitSortActive(first)
    first.close()
    // A re-open is a new handle: per-document state is session-only and NOTHING
    // about the sort survives (no persistence anywhere in this feature).
    let reopened = try await openForSort()
    defer { reopened.close() }
    #expect(reopened.sortStatus() == nil)
    #expect(viewSourceRows(reopened, 8) == (0..<8).map { Optional(UInt64($0)) })
}

@Test func bridgeSortResetsAnActiveFindBecauseTheCoordinateSpaceChanged() async throws {
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.startSearch(.text(query: "needle", scope: nil, caseSensitive: false)),
                 "core rejected the search")
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")
    _ = try await waitSortActive(session)
    #expect(session.searchStatus() == nil)
}
