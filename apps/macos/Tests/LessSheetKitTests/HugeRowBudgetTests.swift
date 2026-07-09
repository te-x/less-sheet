// Frozen behavior tests — huge-row-budget slice (planner-owned).
// ARCH-huge-row-budget app criterion 7 (the HEADLESS half): the per-row
// OVERSIZED flag surfaces through the CoreDocumentSession bridge
// (RowWindow.oversized) against a huge-row fixture, verified against the REAL
// linked Zig core (no mocks). The core's own bounded-prefix / no-rescan / count
// semantics (criteria 3-6) are pinned in the backend suite; the live gutter
// MARKER + tooltip are a human-eyes check (no UI/gutter test here, per the
// ARCH). Normative text: api/lesssheet.h (LS_WINDOW_ROW_SCAN_MAX_BYTES,
// ls_row_oversized) and Sources/Contracts/DocumentSession.swift
// (RowWindow.oversized).
//
// Determinism: the huge row is just OVER the per-row scan cap (~1.1 MiB), so
// the whole fixture is a few MiB — well under the core's head budget, fully
// indexed at open (exact count), materialized in milliseconds. The multi-GB
// UI-freeze proof (criteria 1-2, < 100 ms landing on sparse5g) is the FRONTEND
// sparse5g jump probe from the ARCH regression loop, NOT this test.
import Foundation
import Testing
import Contracts
import CLessSheet
import LessSheetKit

// MARK: - Helpers

private func writeTempCSV(_ bytes: [UInt8]) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lesssheet-hugerow-\(UUID().uuidString).csv")
    try Data(bytes).write(to: url)
    return url.path(percentEncoded: false)
}

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

// MARK: - ABI agreement: C header <-> Swift contract (regression guard)

@Test func hugeRowBudgetABIConstantIsPinned() {
    #expect(LS_WINDOW_ROW_SCAN_MAX_BYTES == 1024 * 1024)
    // The per-row SOURCE scan cap is DISTINCT from — and far larger than — the
    // per-cell OUTPUT display cap; both apply.
    #expect(LS_WINDOW_ROW_SCAN_MAX_BYTES > LS_CELL_MAX_BYTES)
}

// MARK: - Bridge: the per-row oversized flag surfaces (criterion 7, headless)

@Test func bridgeSurfacesOversizedRowFlag() async throws {
    // Header, one small row, then a row whose SOURCE extent exceeds the per-row
    // window scan cap (a > cap first cell), then another small row after it.
    var fixture = bytes("a,b\nfirst,1\n")
    let overCap = Int(LS_WINDOW_ROW_SCAN_MAX_BYTES) + 64 * 1024
    fixture += Array(repeating: UInt8(ascii: "X"), count: overCap)
    fixture += bytes(",TAIL\n")
    fixture += bytes("last,2\n")
    let session = try await CoreSessionOpener().open(path: try writeTempCSV(fixture), forcing: .sniffAll)
    defer { session.close() }

    let window = session.setWindow(firstRow: 0, rowCount: 10)
    #expect(window.rows.count == 3)
    // PER-ROW shape: one flag per row (NOT per cell like `truncated`).
    #expect(window.oversized.count == window.rows.count)
    // The small rows are NOT oversized and are served whole.
    #expect(window.oversized[0] == false)
    #expect(window.rows[0][0] == "first")
    // The row AFTER the huge one is still reached + served correctly.
    #expect(window.oversized[2] == false)
    #expect(window.rows[2][0] == "last")
    // The huge row (index 1) IS flagged oversized; its served cell is
    // display-capped (the per-cell flag is independent of the per-row flag).
    #expect(window.oversized[1] == true)
    #expect(window.rows[1][0].utf8.count <= Int(LS_CELL_MAX_BYTES))
    #expect(window.truncated[1][0] == true)
}
