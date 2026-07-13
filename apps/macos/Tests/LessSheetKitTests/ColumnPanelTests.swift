// Frozen behavior tests — column-config PANEL geometry + label search
// (planner-owned). ARCH-column-config criterion 11 (the 100k-column panel is
// O(viewport)) + criterion 12 (bounded, batched label search). Pure, no GUI:
// the AppKit NSTableView reuse and off-main search scheduling live in the app;
// these pin the deterministic decisions (which rows to instantiate; which
// labels match). Cancellation/streaming/off-main is a reviewer check.
//
// RED SEED: `ColumnPanelLayout` returns the whole `0..<totalColumns` (the old
// eager ForEach) and `ColumnLabelSearch` reports batch size 0 / matches nothing.
import Foundation
import Testing
import Contracts
import LessSheetKit

@Suite("column-config panel + label search")
struct ColumnPanelTests {

    @Test func conformancePins() {
        let _: any ColumnPanelLayouting = ColumnPanelLayout()
        let _: any ColumnLabelSearching = ColumnLabelSearch()
    }

    // AC11 — the 100k-column panel instantiates at most 3·visible+8 rows,
    // INDEPENDENT of total columns, and still covers the visible range. RED: the
    // seed instantiates all 100_000.
    @Test func panelIsOViewportOnAHundredThousandColumns() {
        let layout = ColumnPanelLayout()
        let visible = 20
        let bound = 3 * visible + 8   // 68

        let vp = ColumnPanelViewport(totalColumns: 100_000, firstVisibleRow: 50_000, visibleRowCount: visible)
        let plan = layout.plan(for: vp)
        #expect(plan.instantiatedRows.count <= bound)                 // RED: 100_000 > 68
        // covers the visible window, clamped in-bounds.
        #expect(plan.instantiatedRows.lowerBound <= 50_000)
        #expect(plan.instantiatedRows.upperBound >= 50_000 + visible)
        #expect(plan.instantiatedRows.lowerBound >= 0)
        #expect(plan.instantiatedRows.upperBound <= 100_000)

        // Independence: 50× more columns, same viewport -> same bound.
        let vpBig = ColumnPanelViewport(totalColumns: 5_000_000, firstVisibleRow: 50_000, visibleRowCount: visible)
        #expect(layout.plan(for: vpBig).instantiatedRows.count <= bound) // RED
    }

    // AC11 — degenerate viewports (edges / empty) yield a clamped, empty-safe
    // range and never exceed the bound.
    @Test func panelClampsAtEdgesAndEmpty() {
        let layout = ColumnPanelLayout()
        // top edge: no negative lower bound.
        let top = layout.plan(for: ColumnPanelViewport(totalColumns: 1000, firstVisibleRow: 0, visibleRowCount: 10))
        #expect(top.instantiatedRows.lowerBound == 0)
        #expect(top.instantiatedRows.count <= 3 * 10 + 8)              // RED: 1000 > 38
        // empty document -> empty range (guard).
        let empty = layout.plan(for: ColumnPanelViewport(totalColumns: 0, firstVisibleRow: 0, visibleRowCount: 10))
        #expect(empty.instantiatedRows.isEmpty)
    }

    // AC12 — a search scans batches of at most 1024. RED: the seed reports 0.
    @Test func labelSearchBatchIsBounded() {
        #expect(ColumnLabelSearch().batchSize == columnLabelSearchBatchMax)  // 1024
    }

    // AC12 — localized, case-insensitive substring match over a batch, returning
    // matching IDs in source-column order (never label Strings). RED: seed [].
    @Test func labelSearchMatchesSubstringsInOrder() {
        let s = ColumnLabelSearch()
        let en = Locale(identifier: "en_US")
        let batch = [
            ColumnLabelCandidate(column: 0, label: "name"),
            ColumnLabelCandidate(column: 1, label: "age"),
            ColumnLabelCandidate(column: 2, label: "NATION"),
        ]
        #expect(s.matches(query: "na", in: batch, locale: en) == [0, 2])   // case-insensitive
        #expect(s.matches(query: "AGE", in: batch, locale: en) == [1])
        #expect(s.matches(query: "", in: batch, locale: en) == [])          // empty query: no match (guard)
        #expect(s.matches(query: "zz", in: batch, locale: en) == [])        // no match (guard)
    }

    // AC12 — a header-off / empty-label column matches on its generic name +
    // 1-based index (column 26 -> "AA 27"). RED: seed [].
    @Test func labelSearchHeaderlessUsesGenericNamePlusIndex() {
        let s = ColumnLabelSearch()
        let en = Locale(identifier: "en_US")
        let batch = [ColumnLabelCandidate(column: 26, label: nil)]
        #expect(s.matches(query: "27", in: batch, locale: en) == [26])   // 1-based index
        #expect(s.matches(query: "aa", in: batch, locale: en) == [26])   // generic name "AA"
    }
}
