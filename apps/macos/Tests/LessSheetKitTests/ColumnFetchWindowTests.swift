// Frozen behavior test — column-windowing ROUND 2 (the cell-FETCH), planner-owned.
//
// ARCH-column-windowing "Amendment — round 2: window the cell-FETCH too" / AC7.
// Round 1 made the frontend's MEASURE + DRAW O(visible columns) (pinned purely,
// no GUI, in ColumnWindowingTests). Measurement then showed the residual cold-
// open cost is the FETCH: `CoreDocumentSession.setWindow` materialized ALL
// columns (the dense, columnCount-wide `RowWindow`) at 2 FFI calls/cell
// (`ls_cell` + `ls_cell_truncated`) on every materialize — O(columnCount), not
// O(viewport). This file pins the fetch analog of AC2: a column-windowed
// `setWindow` fetches ONLY the requested column range.
//
// EXERCISED AGAINST THE REAL LINKED ZIG CORE (no mocks), like ViewerUiTests /
// CsvHardeningTests / HugeRowBudgetTests — because AC7's RED→GREEN is a property
// of the CoreDocumentSession bridge, not of a pure helper: a test double could
// not track the round-2 edit to CoreDocumentSession. The fixture is the frozen
// `wide28.csv` (28 columns, one all-numeric data row where column c holds value
// c+1, so a fetched cell's VALUE pins the exact absolute column it came from);
// it is far below the core's head budget, so its index is complete and its row
// count exact from the moment the session exists (pinned determinism) — no
// polling. Normative text: Sources/Contracts/DocumentSession.swift
// (`RowWindow.firstColumn`, `setWindow(firstRow:rowCount:columns:)`).
//
// WHY THE RETURNED SHAPE IS A FAITHFUL, DETERMINISTIC FETCH-VOLUME PROXY:
// CoreDocumentSession copies exactly ONE owned String per returned cell
// (`ls_cell`) plus one flag (`ls_cell_truncated`) — the returned window's
// per-row cell count therefore EQUALS the number of per-cell FFI fetches. So a
// window whose rows are `columns.count` wide (< columnCount) proves the fetch is
// O(visible columns), not O(columnCount); no instrumentation needed. Calling the
// column overload + reading `RowWindow.firstColumn` here also double as the
// COMPILE-TIME conformance pin for the additive contract surface (a signature
// drift fails this build).
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import:
// `CoreDocumentSession` does NOT yet override the column overload, so it resolves
// to the DEFAULT protocol-extension impl (DocumentSession.swift), which IGNORES
// `columns` and returns the DENSE window from `setWindow(firstRow:rowCount:)` —
// `firstColumn == 0`, every row the full 28 columns wide. Both tests below then
// fail on behavior: `firstColumn` is 0 (not the requested lower bound), each row
// is 28 wide (not the window width), and the fetched cells are the whole row (not
// the requested slice). The tree still COMPILES (the default keeps every
// conformer, incl. the round-1 impl's dense `setWindow` calls, building).
//
// RED → GREEN (round-2 implementer): OVERRIDE
// `setWindow(firstRow:rowCount:columns:)` in `CoreDocumentSession` to issue
// `ls_window_set` + read cells/flags for ONLY the (clamped) `columns` range,
// returning `RowWindow(firstColumn: columns.lowerBound, …)`, and route
// `ViewerModel.materialize` through it (`columnWindow.range`) with the
// column-relative consumers indexing off `firstColumn`. That same wiring carries
// `wide_100k_cols` cold-open under the 500 ms budget with margin (csv-corpus AC5
// = ARCH AC1).
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers (file-private; each real-core test file owns its own)

private func fixturePath(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"),
        "missing fixture \(name).csv"
    )
    return url.path(percentEncoded: false)
}

private func openFixture(_ name: String) async throws -> any DocumentSession {
    try await CoreSessionOpener().open(path: fixturePath(name), forcing: .sniffAll)
}

@Suite("column-fetch-window")
struct ColumnFetchWindowTests {

    // AC7 (first paint) — a column-windowed fetch at the LEFT edge materializes
    // only the window width, NOT all columns. Positioned at column 0, so the WIDTH
    // (not `firstColumn`) is what distinguishes a real window from the dense
    // fallback: it proves even a cold first paint fetches O(visible), not O(total).
    @Test func firstPaintFetchesOnlyTheWindowWidthNotAllColumns() async throws {
        let session = try await openFixture("wide28")
        defer { session.close() }
        #expect(session.columnCount == 28)

        let columns = 0 ..< 12                       // a viewport-width first paint
        let win = session.setWindow(firstRow: 0, rowCount: 10, columns: columns)

        // Row dimension unchanged: wide28 has a single all-numeric data row.
        #expect(win.firstRow == 0)
        #expect(win.rows.count == 1)
        #expect(win.firstColumn == columns.lowerBound)   // 0

        // The fetch analog of AC2 (O(viewport), not O(total)): the fetched WIDTH
        // equals the requested window (`columns.count`) — a function of the
        // REQUEST — and is strictly LESS than the document's column count, so the
        // fetch does NOT scale with `columnCount`. RED (dense fallback) makes each
        // row 28 wide; GREEN makes it 12. (Per-row cell count == per-cell FFI
        // fetches, so the shape IS the fetch volume — see the file header.)
        #expect(win.rows.allSatisfy { $0.count == columns.count })          // 12, not 28
        #expect(columns.count < session.columnCount)                        // strict sub-range
        // The parallel truncation flags are windowed to the SAME range (shape).
        #expect(win.truncated.count == win.rows.count)
        #expect(win.truncated.allSatisfy { $0.count == columns.count })

        // Correctness: the RIGHT cells (column c of wide28 holds value c+1).
        #expect(win.rows[0] == (1 ... 12).map(String.init))
    }

    // AC7 (scroll-materialize) — a column-windowed fetch scrolled to the RIGHT
    // edge is POSITIONED at that range (analogue of AC3's "positioned at the
    // scrolled region"): `firstColumn` is the range's lower bound and only the
    // window's cells are fetched, never walked from column 0 / O(columnCount).
    @Test func scrollMaterializeFetchesOnlyThePositionedWindow() async throws {
        let session = try await openFixture("wide28")
        defer { session.close() }

        let columns = 23 ..< 28                      // a window at the far right edge
        let win = session.setWindow(firstRow: 0, rowCount: 10, columns: columns)

        #expect(win.rows.count == 1)
        #expect(win.firstColumn == columns.lowerBound)   // 23, not 0
        #expect(win.rows.allSatisfy { $0.count == columns.count })          // 5, not 28
        #expect(win.truncated.allSatisfy { $0.count == columns.count })

        // Correctness: the exact absolute cells [23, 28) — values 24…28 —
        // indexed off `firstColumn` (slot j == absolute column 23 + j).
        #expect(win.rows[0] == (24 ... 28).map(String.init))
    }
}
