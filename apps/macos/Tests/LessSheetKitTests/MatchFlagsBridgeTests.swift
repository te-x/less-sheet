// Frozen behavior test — thin-frontend-shared-core Phase 1 (planner-owned).
// ARCH-thin-frontend-shared-core Phase 1 AC1/AC2/AC3: the core's
// `ls_window_match_flags` path (surfaced by `DocumentSession.windowMatchFlags`)
// reproduces, BYTE-FOR-BYTE, the per-cell find / predicate verdicts the
// frontend's `CellMatcher` produced — the duplicate Phase 1 deletes.
//
// The expected arrays below are GOLDEN LITERALS captured from the CURRENT
// `CellMatcher` (apps/macos/Sources/LessSheetKit/FindLogic.swift) evaluated over
// the find.csv fixture cells, so this test does NOT reference `CellMatcher` /
// `CellMatching` — which lets it stay green after Phase 1 deletes them, and is
// exactly what makes AC1 "byte-identical to the deleted matcher" gate-lockable.
// The backend `mf*` suite (backend/tests/all_tests.zig) pins the SAME verdicts
// against the core directly; this pins the copy-out binding + filter interplay.
//
// RED at freeze: `CoreDocumentSession` does NOT yet override `windowMatchFlags`,
// so the protocol's RED default (returns []) answers every call — each non-empty
// golden assertion fails on the empty buffer (a BEHAVIOR red). The implementer
// flips it GREEN by overriding `windowMatchFlags` to call `ls_window_match_flags`
// and copy the borrowed flag bytes out.
//
// Semantics are normative in api/lesssheet.h "MATCH-FLAGS EXTENSION" and mirrored
// in Sources/Contracts/DocumentSession.swift.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers (self-contained; no dependency on the deleted matcher)

private func findFixturePath() throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "find", withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture find.csv"
    )
    return url.path(percentEncoded: false)
}

private func openFindFixture() async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: findFixturePath(), forcing: .sniffAll)
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

/// One golden verdict case over the full (header ON) find.csv window.
///
/// find.csv data rows (0-based), header `name,qty,note` is ON:
///   0: Widget | 2   | alpha needle       4: Gizmo | 1e2 | delta
///   1: NEEDLE | 10  | beta               5: café  | 0.5 | CAFÉ
///   2: needle | 2.0 | gamma              6:       | 5.  | needleneedle
///   3: gadget | -3  | Needle point       7: plain | abc | end needle
private struct FlagCase {
    let name: String
    let request: SearchRequest
    let firstColumn: Int
    let columnCount: Int
    let golden: [UInt8]
}

// Goldens generated from the current CellMatcher; row-major, stride == columnCount.
private let cases: [FlagCase] = [
    // --- AC1: TEXT smart case --------------------------------------------------
    .init(name: "text 'needle' (folds ASCII)", request: .text(query: "needle", scope: nil),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,1, 1,0,0, 1,0,0, 0,0,1, 0,0,0, 0,0,0, 0,0,1, 0,0,1,
          ]),
    .init(name: "text 'Needle' (uppercase -> byte-exact)", request: .text(query: "Needle", scope: nil),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,0,0, 0,0,1, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "text 'café' (non-ASCII bytes exact)", request: .text(query: "café", scope: nil),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 1,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "text 'e' (dense)", request: .text(query: "e", scope: nil),
          firstColumn: 0, columnCount: 3, golden: [
            1,0,1, 1,0,1, 1,0,0, 1,0,1, 0,1,1, 0,0,0, 0,0,1, 0,0,1,
          ]),
    // --- AC1: PREDICATE eq/ne (byte-exact) + numeric ordering ------------------
    .init(name: "qty <= 2", request: .predicate(column: 1, op: .lessOrEqual, value: "2"),
          firstColumn: 0, columnCount: 3, golden: [
            0,1,0, 0,0,0, 0,1,0, 0,1,0, 0,0,0, 0,1,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "qty > 2", request: .predicate(column: 1, op: .greaterThan, value: "2"),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,1,0, 0,0,0, 0,0,0, 0,1,0, 0,0,0, 0,1,0, 0,0,0,
          ]),
    .init(name: "qty < 1e2 (== 100)", request: .predicate(column: 1, op: .lessThan, value: "1e2"),
          firstColumn: 0, columnCount: 3, golden: [
            0,1,0, 0,1,0, 0,1,0, 0,1,0, 0,0,0, 0,1,0, 0,1,0, 0,0,0,
          ]),
    .init(name: "qty == 2.0 (byte-exact; '2' does not match)",
          request: .predicate(column: 1, op: .equals, value: "2.0"),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,1,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "qty != 10 (byte-exact)", request: .predicate(column: 1, op: .notEquals, value: "10"),
          firstColumn: 0, columnCount: 3, golden: [
            0,1,0, 0,0,0, 0,1,0, 0,1,0, 0,1,0, 0,1,0, 0,1,0, 0,1,0,
          ]),
    .init(name: "name == '' (empty matches the padded/empty cell)",
          request: .predicate(column: 0, op: .equals, value: ""),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 1,0,0, 0,0,0,
          ]),
    // --- AC2: scope is part of the verdict -------------------------------------
    .init(name: "text 'e' scope {0,2} (qty col 1 excluded even though '1e2' has 'e')",
          request: .text(query: "e", scope: [0, 2]),
          firstColumn: 0, columnCount: 3, golden: [
            1,0,1, 1,0,1, 1,0,0, 1,0,1, 0,0,1, 0,0,0, 0,0,1, 0,0,1,
          ]),
    .init(name: "text 'e' scope {0}", request: .text(query: "e", scope: [0]),
          firstColumn: 0, columnCount: 3, golden: [
            1,0,0, 1,0,0, 1,0,0, 1,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    // --- AC4 (binding side): a column sub-window (note column only) ------------
    .init(name: "text 'needle' — column sub-window [2,1)",
          request: .text(query: "needle", scope: nil),
          firstColumn: 2, columnCount: 1, golden: [1, 0, 0, 1, 0, 0, 1, 1]),
]

// MARK: - Tests

@Test func matchFlagsReproduceTheDeletedCellMatcherVerdicts() async throws {
    let session = try await openFindFixture()
    defer { session.close() }
    let window = session.setWindow(firstRow: 0, rowCount: 20)
    try #require(window.rows.count == 8, "find.csv has 8 data rows (header ON)")

    for c in cases {
        try #require(session.startSearch(c.request), "core rejected \(c.name)")
        // Read RIGHT AFTER startSearch: the flags come from the active request +
        // the materialized window, never the (async) match-scan.
        let flags = session.windowMatchFlags(firstColumn: c.firstColumn, columnCount: c.columnCount)
        #expect(flags == c.golden, "match-flags mismatch for [\(c.name)]: got \(flags)")
    }
}

@Test func matchFlagsAreEmptyWhenNoSearchIsActive() async throws {
    // AC3: LS_SEARCH_IDLE -> the empty buffer -> the grid shows no highlights.
    let session = try await openFindFixture()
    defer { session.close() }
    _ = session.setWindow(firstRow: 0, rowCount: 20)
    #expect(session.searchStatus() == nil) // fresh session: no search
    #expect(session.windowMatchFlags(firstColumn: 0, columnCount: 3) == [])
}

@Test func matchFlagsFollowTheFilteredRowsNotTheVerdict() async throws {
    // AC1: a filter changes only WHICH rows the window holds; the per-cell
    // verdict is unchanged. Filter to rows with any "needle" (sources
    // 0,1,2,3,6,7 -> 6 filtered rows), then search "needle" in filtered coords.
    let session = try await openFindFixture()
    defer { session.close() }
    try #require(session.setFilter(.text(query: "needle", scope: nil)), "filter rejected")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    let window = session.setWindow(firstRow: 0, rowCount: 20)
    try #require(window.rows.count == 6, "6 rows satisfy the needle filter")
    try #require(session.startSearch(.text(query: "needle", scope: nil)), "search rejected")
    // Identical per-cell verdict to the non-filtered needle case, with the two
    // non-matching rows (4,5) simply absent from the filtered view.
    #expect(session.windowMatchFlags(firstColumn: 0, columnCount: 3) == [
        0,0,1, 1,0,0, 1,0,0, 0,0,1, 0,0,1, 0,0,1,
    ])
}
