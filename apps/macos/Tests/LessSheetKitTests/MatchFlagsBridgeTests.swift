// Frozen behavior test — thin-frontend-shared-core Phase 1 (planner-owned).
// ARCH-thin-frontend-shared-core Phase 1 AC1/AC2/AC3: the core's
// `ls_window_match_flags` path (surfaced by `DocumentSession.windowMatchFlags`)
// is the SINGLE source of per-cell find / predicate highlight verdicts — the
// frontend owns no matcher of its own.
//
// ARCH-search-case-mode B8/A3: those verdicts inherit the active request's
// `caseSensitive` (the highlight mask reuses the same matcher as
// `ls_search_start`). The golden arrays below are row-major, stride ==
// columnCount, over the find.csv fixture; the case-mode cases pin the mask
// honoring the flag: an insensitive uppercase query folds like its lowercase
// form, and Match case ON makes both TEXT substring and predicate EQ/NE
// byte-exact. (The ON cases are RED until the bridge marshals the flag at
// `withSearchRequest`; the default-insensitive cases are already GREEN.)
//
// Semantics are normative in api/lesssheet.h "MATCH-FLAGS EXTENSION" and
// mirrored in Sources/Contracts/DocumentSession.swift.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers (self-contained)

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

// Row-major, stride == columnCount. These are the verdicts the core's
// ls_window_match_flags computes for each request (case_sensitive-aware).
private let cases: [FlagCase] = [
    // --- TEXT, default insensitive: an uppercase query folds like lowercase --
    .init(name: "text 'needle' (folds ASCII by default)",
          request: .text(query: "needle", scope: nil, caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,1, 1,0,0, 1,0,0, 0,0,1, 0,0,0, 0,0,0, 0,0,1, 0,0,1,
          ]),
    .init(name: "text 'Needle' default folds like 'needle' (B1)",
          request: .text(query: "Needle", scope: nil, caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,1, 1,0,0, 1,0,0, 0,0,1, 0,0,0, 0,0,0, 0,0,1, 0,0,1,
          ]),
    // --- TEXT, Match case ON: byte-exact (RED until the flag is marshaled) ----
    .init(name: "text 'Needle' Match case ON -> byte-exact",
          request: .text(query: "Needle", scope: nil, caseSensitive: true),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,0,0, 0,0,1, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "text 'café' (non-ASCII bytes exact in both modes)",
          request: .text(query: "café", scope: nil, caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 1,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "text 'e' (dense)", request: .text(query: "e", scope: nil, caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            1,0,1, 1,0,1, 1,0,0, 1,0,1, 0,1,1, 0,0,0, 0,0,1, 0,0,1,
          ]),
    // --- PREDICATE eq/ne + numeric ordering -----------------------------------
    .init(name: "qty <= 2", request: .predicate(column: 1, comparison: .lessOrEqual, value: "2", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,1,0, 0,0,0, 0,1,0, 0,1,0, 0,0,0, 0,1,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "qty > 2", request: .predicate(column: 1, comparison: .greaterThan, value: "2", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,1,0, 0,0,0, 0,0,0, 0,1,0, 0,0,0, 0,1,0, 0,0,0,
          ]),
    .init(name: "qty < 1e2 (== 100)", request: .predicate(column: 1, comparison: .lessThan, value: "1e2", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,1,0, 0,1,0, 0,1,0, 0,1,0, 0,0,0, 0,1,0, 0,1,0, 0,0,0,
          ]),
    .init(name: "qty == 2.0 (exact decimal; '2' does not match)",
          request: .predicate(column: 1, comparison: .equals, value: "2.0", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,1,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "qty != 10", request: .predicate(column: 1, comparison: .notEquals, value: "10", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,1,0, 0,0,0, 0,1,0, 0,1,0, 0,1,0, 0,1,0, 0,1,0, 0,1,0,
          ]),
    .init(name: "name == '' (empty matches the padded/empty cell)",
          request: .predicate(column: 0, comparison: .equals, value: "", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 1,0,0, 0,0,0,
          ]),
    // --- PREDICATE eq case folding (B4/B5): 'NEEDLE' (row 1) + 'needle' (row 2)
    .init(name: "name = 'needle' default folds (matches NEEDLE + needle)",
          request: .predicate(column: 0, comparison: .equals, value: "needle", caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 1,0,0, 1,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    .init(name: "name = 'needle' Match case ON -> byte-exact (only 'needle')",
          request: .predicate(column: 0, comparison: .equals, value: "needle", caseSensitive: true),
          firstColumn: 0, columnCount: 3, golden: [
            0,0,0, 0,0,0, 1,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    // --- scope is part of the verdict ------------------------------------------
    .init(name: "text 'e' scope {0,2} (qty col 1 excluded even though '1e2' has 'e')",
          request: .text(query: "e", scope: [0, 2], caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            1,0,1, 1,0,1, 1,0,0, 1,0,1, 0,0,1, 0,0,0, 0,0,1, 0,0,1,
          ]),
    .init(name: "text 'e' scope {0}", request: .text(query: "e", scope: [0], caseSensitive: false),
          firstColumn: 0, columnCount: 3, golden: [
            1,0,0, 1,0,0, 1,0,0, 1,0,0, 0,0,0, 0,0,0, 0,0,0, 0,0,0,
          ]),
    // --- a column sub-window (note column only) --------------------------------
    .init(name: "text 'needle' — column sub-window [2,1)",
          request: .text(query: "needle", scope: nil, caseSensitive: false),
          firstColumn: 2, columnCount: 1, golden: [1, 0, 0, 1, 0, 0, 1, 1]),
]

// MARK: - Tests

@Test func matchFlagsReproduceTheCoreVerdicts() async throws {
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
    try #require(session.setFilter(.text(query: "needle", scope: nil, caseSensitive: false)), "filter rejected")
    _ = try await waitFilter(session) { $0.totalIsFinal }
    let window = session.setWindow(firstRow: 0, rowCount: 20)
    try #require(window.rows.count == 6, "6 rows satisfy the needle filter")
    try #require(session.startSearch(.text(query: "needle", scope: nil, caseSensitive: false)), "search rejected")
    // Identical per-cell verdict to the non-filtered needle case, with the two
    // non-matching rows (4,5) simply absent from the filtered view.
    #expect(session.windowMatchFlags(firstColumn: 0, columnCount: 3) == [
        0,0,1, 1,0,0, 1,0,0, 0,0,1, 0,0,1, 0,0,1,
    ])
}
