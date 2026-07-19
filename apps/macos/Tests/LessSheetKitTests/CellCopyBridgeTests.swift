// Frozen behavior test — select-copy: the lossless full-cell COPY BRIDGE
// (ARCH-select-copy AC3), the real-core half. Planner-owned.
//
// Copy must be LOSSLESS: a cell longer than the 4 KiB display cap (LS_CELL_MAX_
// BYTES) is searchable but NOT readable through `ls_cell` / the windowed
// `setWindow` path. api/lesssheet.h therefore adds `ls_cell_copy` — a bounded,
// window-INDEPENDENT full-cell read (frozen + backend-implemented in Pass 1) —
// and `DocumentSession` gains an ADDITIVE `copyCell(row:column:maxBytes:)`
// wrapper mirroring it. This file pins that wrapper against the REAL linked Zig
// core (no mocks), exactly like ColumnFetchWindowTests / HugeRowBudgetTests: the
// copy builder's injected closure has a real backing, so a copy of a > 4 KiB
// cell is faithful. Calling `copyCell` here also DOUBLES as the compile-time
// conformance pin for the additive protocol method (a signature drift fails this
// build).
//
// Determinism: the fixture is a few KB — well under the core's head budget — so
// it is fully indexed at open (exact row count, every row behind the frontier),
// materialized in microseconds; no polling. A temp file (not a frozen binary
// fixture), like HugeRowBudgetTests.
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import:
// `CoreDocumentSession` does NOT yet override `copyCell`, so it resolves to the
// DEFAULT protocol-extension impl (DocumentSession.swift), which returns
// `.noCell` for EVERY cell — nothing copies. The assertions below then fail on
// behavior: `.status` is `.noCell` (not `.served`), `.text` is "" (not the cell
// content). The tree still COMPILES (the default keeps every conformer building,
// including this call site).
//
// RED → GREEN (implementer): OVERRIDE `copyCell` in `CoreDocumentSession` to call
// `ls_cell_copy(doc, row, col, buf, maxBytes, &outLen, &outTruncated)` into a
// `maxBytes` buffer and map `ls_copy_result` → `CopiedCell` (.served/.pending/.noCell,
// the written UTF-8 bytes as `text`, `outTruncated` as `truncated`); route the
// App's Cmd+C copy through it (as the `CopyCellFetch` closure, off the main
// thread). PENDING (a row past the frontier) is exercised by the backend suite
// (Pass 1); it cannot be forced on a fully-indexed small fixture.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

private func writeTempCSV(_ text: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lesssheet-copybridge-\(UUID().uuidString).csv")
    try Data(Array(text.utf8)).write(to: url)
    return url.path(percentEncoded: false)
}

@Suite("cell-copy-bridge")
struct CellCopyBridgeTests {

    // The additive `copyCell` wrapper reads the COMPLETE cell via `ls_cell_copy`,
    // beyond the display cap; a small per-cell cap truncates at a code-point
    // boundary and flags it; window-INDEPENDENT (no prior setWindow); out-of-range
    // column → `.noCell`.
    @Test func copyCellReadsFullCellBeyondTheDisplayCap() async throws {
        // A first data cell longer than the 4 KiB display cap, and a short
        // neighbor. Header on (sniffed) → columnCount 2, data row 0 is the big row.
        let big = String(repeating: "A", count: 5000)
        #expect(5000 > Int(LS_CELL_MAX_BYTES))          // the point: past the display cap
        let csv = "a,b\n" + big + ",short\n"
        let session = try await CoreSessionOpener().open(path: try writeTempCSV(csv), forcing: .sniffAll)
        defer { session.close() }
        #expect(session.columnCount == 2)

        // Window-INDEPENDENT: copy WITHOUT any prior `setWindow`. The full cell
        // comes back — NOT the 4 KiB-capped display bytes.
        let cell = session.copyCell(row: 0, column: 0, maxBytes: 1 << 20)
        #expect(cell.status == .served)
        #expect(cell.truncated == false)
        #expect(cell.text.count == 5000)
        #expect(cell.text == big)

        // A small per-cell cap → a boundary-cut prefix, flagged truncated.
        let capped = session.copyCell(row: 0, column: 0, maxBytes: 10)
        #expect(capped.status == .served)
        #expect(capped.truncated == true)
        #expect(capped.text.utf8.count <= 10)
        #expect(big.hasPrefix(capped.text))             // a genuine prefix of the cell

        // The short neighbor round-trips whole.
        let short = session.copyCell(row: 0, column: 1, maxBytes: 1 << 20)
        #expect(short.status == .served)
        #expect(short.text == "short")

        // No such column → `.noCell` (distinct from `.pending`).
        #expect(session.copyCell(row: 0, column: 99, maxBytes: 1 << 20).status == .noCell)
    }
}
