// Frozen behavior tests — sort-by-column slice (planner-owned).
// ARCH-sort-by-column app criterion AC-s14 (Amendments 1 and 3): the pure
// three-state CYCLE that ⇧⌘S drives, the header CONTEXT MENU's three stateful
// entries, the header indicator, the one declaration of the titles +
// accelerator, and the sort bridge against the REAL linked Zig core (apply,
// sorted coordinates, descending, composition with a filter, clear restoring
// the pre-sort order, session-only across a re-open).
//
// AMENDMENT 3 — WHAT TRIGGERS A SORT. Only ⇧⌘S (the cycle, on the cursor's
// column) and the header context menu (three explicit entries). A PLAIN header
// click is NOT a sort trigger and keeps whole-column selection exactly as
// before this feature; the frozen selection tests
// (`SelectCopyTests.wholeColumn`, `NativeGridTests.selectionSecondClickDeselects…`)
// bind to the model and the controller's semantic seam, not to a gesture form,
// so they pin that behavior unchanged and needed no edit here.
// Semantics are normative in Sources/Contracts/SortControl.swift +
// DocumentSession.swift and api/lesssheet.h SORTED VIEWS.
//
// WHY THE CYCLE IS PINNED SO HARD. Two entry points share ONE state machine —
// ⇧⌘S on the keyboard cursor's column, and the progress affordance's Cancel,
// which must mean the same "stop" the cycle means on an unlanded pass. The
// truth table below is exhaustive over (phase x same/different column x
// direction) precisely so the two cannot drift apart in the display layer.
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
    // Amendment 3: the header context menu's three titles are declared HERE
    // too, so the menu, its AT-SPI labels and any future surface naming these
    // commands all read one place.
    #expect(SortCommand.ascendingTitle == "Sort Ascending")
    #expect(SortCommand.descendingTitle == "Sort Descending")
    #expect(SortCommand.clearTitle == "Clear Sort")
}

// MARK: - The header context menu (Amendment 3; pure, no core)

/// The menu's three entries, or nil with a recorded issue. Every menu test goes
/// through this: the RED seed returns an EMPTY array, and indexing it would TRAP
/// and take the whole `swift test` process down with it, hiding every other
/// result. A frozen test must fail cleanly on the seed it was written against.
private func menuEntries(
    _ cycle: SortCycle, _ snapshot: SortSnapshot?, for column: Int,
    _ sourceLocation: SourceLocation = #_sourceLocation
) -> [SortMenuEntry]? {
    let entries = cycle.headerMenu(snapshot, for: column)
    guard entries.count == 3 else {
        Issue.record("the header menu must offer exactly 3 entries; got \(entries.count)",
                     sourceLocation: sourceLocation)
        return nil
    }
    return entries
}

@Test func headerMenuAlwaysOffersTheSameThreeEntriesInOrder() {
    let cycle = SortCycle()
    for snapshot in [nil, SortSnapshot(phase: .active, column: 1, direction: .ascending)] {
        guard let menu = menuEntries(cycle, snapshot, for: 1) else { return }
        #expect(menu[0].title == SortCommand.ascendingTitle)
        #expect(menu[1].title == SortCommand.descendingTitle)
        #expect(menu[2].title == SortCommand.clearTitle)
        // DIRECT intents, not cycle steps — and the same `SortIntent` the cycle
        // produces, so both trigger paths funnel into one apply step.
        #expect(menu[0].intent == .sort(column: 1, direction: .ascending))
        #expect(menu[1].intent == .sort(column: 1, direction: .descending))
        #expect(menu[2].intent == .clear)
        // The two sort entries are always selectable.
        #expect(menu[0].isEnabled)
        #expect(menu[1].isEnabled)
    }
}

@Test func headerMenuChecksTheRequestedDirectionOnlyOnTheSortedColumn() {
    let cycle = SortCycle()
    // No sort: nothing checked anywhere.
    guard let none = menuEntries(cycle, nil, for: 0) else { return }
    #expect(none.allSatisfy { !$0.isChecked })
    // The check follows the REQUEST, not the phase — building, parked and failed
    // all show it, exactly as the header indicator does, so the menu and the
    // chevron can never disagree about which sort was asked for.
    for phase: SortPhase in [.active, .building(progress: 0.3), .parked(progress: 0.3), .failed(.storage)] {
        for dir: SortDirection in [.ascending, .descending] {
            let snap = SortSnapshot(phase: phase, column: 1, direction: dir)
            guard let onColumn = menuEntries(cycle, snap, for: 1),
                  let elsewhere = menuEntries(cycle, snap, for: 0) else { return }
            #expect(onColumn[0].isChecked == (dir == .ascending))
            #expect(onColumn[1].isChecked == (dir == .descending))
            #expect(!onColumn[2].isChecked, "Clear Sort is never check-marked")
            // A DIFFERENT column's menu shows no check at all.
            #expect(elsewhere.allSatisfy { !$0.isChecked })
        }
    }
}

@Test func headerMenuEnablesClearSortPerDocumentNotPerColumn() {
    let cycle = SortCycle()
    // No sort on the document: Clear Sort is not selectable.
    guard let idle = menuEntries(cycle, nil, for: 0) else { return }
    #expect(idle[2].isEnabled == false)
    // A sort IS set — on column 1. Clear Sort is selectable from EVERY header,
    // including column 0's: clearing is a document-level act, and a user who
    // right-clicks the wrong header should still be able to undo the sort.
    let active = SortSnapshot(phase: .active, column: 1, direction: .ascending)
    guard let onSorted = menuEntries(cycle, active, for: 1),
          let onOther = menuEntries(cycle, active, for: 0) else { return }
    #expect(onSorted[2].isEnabled)
    #expect(onOther[2].isEnabled)
    // Still true while the pass has not landed, and after it failed: the request
    // exists, so it can be dropped.
    for phase: SortPhase in [.building(progress: 0.1), .parked(progress: 0.1), .failed(.memory)] {
        guard let m = menuEntries(cycle, SortSnapshot(phase: phase, column: 1, direction: .ascending), for: 0)
        else { return }
        #expect(m[2].isEnabled)
    }
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

// MARK: - The converging prefix reaches the frontend (DECISION-1)
//
// These two replace `bridgeServesSortedCoordinatesWithoutWaitingForTheKeyPass`,
// which asserted a NON-EMPTY window on the statement after `setSort` returned.
// The frozen header promises only `min(K, rows the pass has scanned so far)`
// servable rows — zero before the core's worker commits its first chunk — and
// that the call never blocks, so that assertion was unsatisfiable by any
// implementation here. See `apps/macos/.aidev/DECISION-1.md` for the evidence
// (5/5 `immediate_rows=0`) and the ruling.
//
// The property splits in two, because ONE fixture cannot show both halves:
//   * WHAT is served — the sorted order, never the pre-sort order, from the
//     first servable window onward. Shown on the shared 8-row fixture.
//   * WHEN it is served — the request returns without waiting for the pass.
//     NOT observable on `find.csv`: measured, it reaches ACTIVE 0.2-0.4 ms after
//     the request, so every non-empty window on it is already ACTIVE and a
//     bridge that blocked until the pass landed would be indistinguishable from
//     a correct one. That half therefore runs on a fixture this test GENERATES,
//     big enough that the pass takes hundreds of milliseconds.

/// Poll the top window until it serves rows, asserting `check` on EVERY
/// observation — not once at the end. A "hold the old order until the pass
/// lands" implementation serves the pre-sort order for a while and the sorted
/// order afterwards; only a per-observation check catches it.
@discardableResult
private func pollTopWindow(
    _ session: any DocumentSession,
    rows: Int,
    within: Duration = .seconds(10),
    check: (RowWindow, [UInt64?], SortSnapshot?) -> Void
) throws -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    var sawRows = false
    while clock.now - start < within {
        let win = session.setWindow(firstRow: 0, rowCount: rows)
        let sources = (0..<win.rows.count).map { session.sourceRow(UInt64($0)) }
        check(win, sources, session.sortStatus())
        if !win.rows.isEmpty {
            sawRows = true
            break
        }
    }
    return sawRows
}

@Test func bridgeServesTheSortedOrderFromTheFirstServableWindow() async throws {
    let session = try await openForSort()
    defer { session.close() }
    try #require(session.setSort(column: 0, direction: .ascending), "core rejected the sort")

    // The REQUEST is visible at once, even before any row is servable: the view
    // is in sorted coordinates from here on, and the header can already draw its
    // pending indicator.
    let immediately = try #require(session.sortStatus(), "the sort request must be visible at once")
    #expect(immediately.column == 0)
    #expect(immediately.direction == .ascending)

    // Every non-empty window observed, at any point, is the SORTED order — never
    // the pre-sort order (which would put "Widget", source 0, at the top).
    let served = try pollTopWindow(session, rows: 8) { win, sources, snap in
        #expect(snap != nil, "the sort request must not disappear while it builds")
        guard !win.rows.isEmpty else { return }
        #expect(sources[0] == sortedByNameAscending[0],
                "row 0 must already be the sorted top, never the pre-sort order")
        #expect(win.rows[0][0] == "")
    }
    #expect(served, "a sorted window must become servable well within the bound")

    // ... and it converges to the whole order.
    _ = try await waitSortActive(session)
    #expect(viewSourceRows(session, 8) == sortedByNameAscending.map { Optional($0) })
}

/// A generated fixture whose key pass takes long enough to observe. 600k rows of
/// `"{i:08},{2i:08}"` — column 0 ascends with source order, so sorting it
/// DESCENDING makes the pre-sort order and the sorted order maximally different
/// at every scan depth. Returns the path; the caller owns the temp directory.
private func makeLargeSortFixture() throws -> (url: URL, rows: Int) {
    let rows = 600_000
    var text = ""
    text.reserveCapacity(rows * 18)
    for i in 0..<rows {
        text += String(format: "%08d,%08d\n", i, 2 * i)
    }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lesssheet-sorttest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("big.csv")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return (url, rows)
}

@Test func bridgeDoesNotWaitForTheKeyPass() async throws {
    let fixture = try makeLargeSortFixture()
    defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
    let session = try await CoreSessionOpener().open(
        path: fixture.url.path(percentEncoded: false), forcing: .sniffAll
    )
    defer { session.close() }

    try #require(session.setSort(column: 0, direction: .descending), "core rejected the sort")
    // THE DISCRIMINATING ASSERTION. On a document this size the pass runs for
    // hundreds of milliseconds, so a bridge that waited for it — for the whole
    // pass, or for a first prefix, or for anything — could not possibly be back
    // here with the phase still BUILDING. On the small fixture this assertion
    // would be meaningless (it reaches ACTIVE in 0.2-0.4 ms); that is why this
    // test generates its own.
    let immediately = try #require(session.sortStatus(), "the sort request must be visible at once")
    #expect(immediately.column == 0)
    #expect(immediately.direction == .descending)
    guard case .building = immediately.phase else {
        // The one way to be past BUILDING already, on a 600k-row document whose
        // pass runs for hundreds of milliseconds, is to have waited for it.
        Issue.record("setSort must return while the key pass is still BUILDING; phase was \(immediately.phase)")
        return
    }

    // The prefix becomes servable while the pass is still running — the app has
    // rows to paint long before the sort lands.
    //
    // NOT asserted here, deliberately: that a single mid-build window is
    // internally in sort order. It is not, on the tree this was written against
    // — the core materializes over a prefix the worker is concurrently
    // extending, so one window can carry rows from two generations. That is a
    // CORE property and a core defect, so its lock lives where it can be fixed:
    // `srt_prefix_window_consistency` in the backend suite. A frontend cell must
    // not be red for something it cannot repair, and it must not silently
    // ratify it either — hence the pointer rather than silence.
    let served = try pollTopWindow(session, rows: 32) { _, _, snap in
        #expect(snap != nil, "the sort request must not disappear while it builds")
    }
    #expect(served, "the converging prefix must become servable well within the bound")

    // And it converges: the top of a completed descending sort is the last row.
    _ = try await waitSortActive(session)
    #expect(viewSourceRows(session, 1) == [Optional(UInt64(fixture.rows - 1))])
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
