// Frozen behavior tests — select-copy slice (planner-owned), the PURE half.
//
// ARCH-select-copy turns the pure viewer into a tool: rectangular cell selection
// (unbounded index space) and column resize / auto-fit — every operation bounded
// at 100M×100k scale. This file pins the DETERMINISTIC, no-GUI heart the frontend
// (NativeGrid event routing + ViewerModel state, App target — not importable by
// tests) must route through: the pure Contracts surfaces `Selecting` and
// `ColumnSizing` (implemented in LessSheetKit as SelectionModel / ColumnSizer).
// Same pattern as ColumnWindowingTests / the other view-model logic pins: pixels
// and dispatch stay in the App; the geometry and the width algebra are exact and
// gate-stable HERE.
//
// The clipboard COPY is no longer a frontend builder: it streams core-framed TSV
// (thin-frontend-shared-core Phase 2), so its behavior is pinned OUTSIDE this file
// — the core `cp*` suite + the golden StreamingCopyBridgeTests (byte-identity) +
// StreamCopyWallClockTests (end-to-end wall-clock + STALLED/resume on the real
// `openCopy` path). The lossless full-cell read is CellCopyBridgeTests.
//
// WHAT EACH TEST PINS
//   selectCopyConformancePins ................. signature drift fails the build.
//   AC1 selection* .......................... each interaction yields the right
//     rect (click / drag / shift-click / arrow / shift-arrow / gutter / header),
//     and Cmd+A on a synthetic 100M×100k extent is the WHOLE rect, held O(1).
//   AC5 columnSizing* ....................... manual override sticks + overrides
//     auto-grow; auto-fit computes the visible-window fit; clearing reverts.
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import: the
// LessSheetKit seed impls return trivial results — SelectionModel produces nil /
// unchanged selections, ColumnSizer ignores the manual map and returns the floor
// from autoFit. So every AC test below fails on behavior while the tree compiles
// (the conformances hold).
//
// RED → GREEN (implementer): implement the seeds per the Contracts doc-comments
// (SelectCopyLogic.swift) and route the App's selection state and column widths
// through them. No frozen path changes.
import Foundation
import Testing
import Contracts
import LessSheetKit

@Suite("select-copy (pure)")
struct SelectCopyTests {

    // Frozen conformance: the Kit types still satisfy the frozen signatures.
    @Test func selectCopyConformancePins() {
        let _: any Selecting = SelectionModel()
        let _: any ColumnSizing = ColumnSizer()
    }

    // MARK: - AC1 — Selecting (rectangular selection in index space)

    // Click → a single-cell selection; an out-of-range click clamps into the
    // extent. RED: the seed's `select` returns nil.
    @Test func selectionClickSelectsOneCellClamped() {
        let m = SelectionModel()
        let extent = GridExtent(rowCount: 1000, columnCount: 50)

        let sel = m.select(GridCell(row: 5, column: 3), in: extent)
        #expect(sel?.rect == SelectionRect(top: 5, bottom: 5, left: 3, right: 3))
        #expect(sel?.rect.isSingleCell == true)

        // Out of range → clamped to the last valid row/column.
        let clamped = m.select(GridCell(row: 9_999, column: 999), in: extent)
        #expect(clamped?.rect == SelectionRect(top: 999, bottom: 999, left: 49, right: 49))

        // Empty extent → no selection.
        #expect(m.select(GridCell(row: 0, column: 0), in: GridExtent(rowCount: 0, columnCount: 0)) == nil)
    }

    // Drag / shift-click → extend-to: anchor kept, active moves, rect normalized
    // (works when the target is above/left of the anchor). RED: the seed's
    // `extend` returns its input unchanged.
    @Test func selectionExtendToBuildsNormalizedRect() {
        let m = SelectionModel()
        let extent = GridExtent(rowCount: 1000, columnCount: 50)
        let base = Selection(anchor: GridCell(row: 2, column: 2), active: GridCell(row: 2, column: 2))

        let down = m.extend(base, to: GridCell(row: 6, column: 5), in: extent)
        #expect(down.anchor == GridCell(row: 2, column: 2))          // anchor fixed
        #expect(down.rect == SelectionRect(top: 2, bottom: 6, left: 2, right: 5))

        let up = m.extend(base, to: GridCell(row: 0, column: 0), in: extent)
        #expect(up.rect == SelectionRect(top: 0, bottom: 2, left: 0, right: 2))
    }

    // Arrow → move the single selection (collapse + step the active corner,
    // clamped at edges). RED: the seed's `move` returns its input unchanged (so
    // a range does not collapse to a single stepped cell).
    @Test func selectionArrowMovesSingleCell() {
        let m = SelectionModel()
        let extent = GridExtent(rowCount: 1000, columnCount: 50)

        let range = Selection(anchor: GridCell(row: 2, column: 2), active: GridCell(row: 6, column: 5))
        let moved = m.move(range, .down, in: extent)
        #expect(moved.rect.isSingleCell)                              // collapsed
        #expect(moved.active == GridCell(row: 7, column: 5))          // active stepped down
        #expect(moved.anchor == moved.active)

        // Clamp at the edges (a step past an edge stays put).
        let atRight = Selection(anchor: GridCell(row: 0, column: 49), active: GridCell(row: 0, column: 49))
        #expect(m.move(atRight, .right, in: extent).active == GridCell(row: 0, column: 49))
        let atTop = Selection(anchor: GridCell(row: 0, column: 3), active: GridCell(row: 0, column: 3))
        #expect(m.move(atTop, .upward, in: extent).active == GridCell(row: 0, column: 3))
    }

    // Shift-arrow → extend by one: anchor kept, active steps. RED: the seed's
    // directional `extend` returns its input unchanged.
    @Test func selectionShiftArrowExtendsByOne() {
        let m = SelectionModel()
        let extent = GridExtent(rowCount: 1000, columnCount: 50)
        let start = Selection(anchor: GridCell(row: 3, column: 3), active: GridCell(row: 3, column: 3))

        let ext = m.extend(start, .right, in: extent)
        #expect(ext.anchor == GridCell(row: 3, column: 3))           // anchor fixed
        #expect(ext.active == GridCell(row: 3, column: 4))
        #expect(ext.rect == SelectionRect(top: 3, bottom: 3, left: 3, right: 4))
    }

    // Gutter click → whole row across all columns; header click → whole column
    // across all rows. RED: the seed returns nil for both.
    @Test func selectionWholeRowAndWholeColumn() {
        let m = SelectionModel()
        let extent = GridExtent(rowCount: 1000, columnCount: 50)

        #expect(m.wholeRow(7, in: extent)?.rect == SelectionRect(top: 7, bottom: 7, left: 0, right: 49))
        #expect(m.wholeColumn(4, in: extent)?.rect == SelectionRect(top: 0, bottom: 999, left: 4, right: 4))

        // Composed whole-row EXTEND (gutter shift-click of row 9 from a whole-row
        // anchor) — the frontend composes it from `extend(_:to:)`, keeping full
        // width. RED: `extend` returns its input unchanged.
        if let row5 = m.wholeRow(5, in: extent) {
            let toRow9 = m.extend(row5, to: GridCell(row: 9, column: extent.lastColumn), in: extent)
            #expect(toRow9.rect == SelectionRect(top: 5, bottom: 9, left: 0, right: 49))
        }
    }

    // Cmd+A → the WHOLE extent, computed O(1) for ANY extent size: a synthetic
    // 100M × 100k document selects every cell as two corner indices, no
    // materialization. RED: the seed's `selectAll` returns nil.
    @Test func selectionSelectAllIsWholeExtentAndO1() {
        let m = SelectionModel()
        let huge = GridExtent(rowCount: 100_000_000, columnCount: 100_000)

        let all = m.selectAll(in: huge)
        #expect(all?.rect == SelectionRect(top: 0, bottom: 99_999_999, left: 0, right: 99_999))
        // The rect spans the whole document yet is held as two corners (O(1)).
        #expect(all?.rect.rowCount == 100_000_000)
        #expect(all?.rect.columnCount == 100_000)

        // No extent → nothing to select.
        let empty = GridExtent(rowCount: 0, columnCount: 0)
        #expect(m.selectAll(in: empty) == nil)
        #expect(m.wholeRow(0, in: empty) == nil)
        #expect(m.wholeColumn(0, in: empty) == nil)
    }

    // MARK: - AC5 — column resize + auto-fit (width model)

    // A manual width STICKS and OVERRIDES auto-grow — larger OR smaller than the
    // content — and a drag is floored at `minWidth`. RED: the seed's `resized`
    // ignores the set and `effectiveWidths` ignores the manual map.
    @Test func columnSizingManualOverrideSticksAndOverridesAutoGrow() {
        let s = ColumnSizer()
        let auto = [80.0, 80.0, 80.0]

        // A manual width SMALLER than content (a deliberate squeeze) wins.
        let manual = s.resized(manual: [:], column: 1, to: 50.0, minWidth: 20.0)
        #expect(manual[1] == 50.0)
        #expect(s.effectiveWidths(auto: auto, manual: manual) == [80.0, 50.0, 80.0])

        // Even after auto-grow raises column 1's AUTO baseline hugely, the manual
        // width still wins (auto-grow never overrides a manual width).
        let grown = [80.0, 500.0, 80.0]
        #expect(s.effectiveWidths(auto: grown, manual: manual) == [80.0, 50.0, 80.0])

        // A manual width LARGER than content also sticks.
        let wide = s.resized(manual: [:], column: 0, to: 300.0, minWidth: 20.0)
        #expect(s.effectiveWidths(auto: auto, manual: wide) == [300.0, 80.0, 80.0])

        // A drag below the floor is clamped up to `minWidth`.
        #expect(s.resized(manual: [:], column: 0, to: 5.0, minWidth: 20.0)[0] == 20.0)
    }

    // Double-click AUTO-FIT computes the EXACT visible-window fit (max content,
    // clamped to [min, max]); an empty window → `minWidth`. RED: the seed's
    // `autoFit` always returns `minWidth`.
    @Test func columnSizingAutoFitComputesVisibleWindowFit() {
        let s = ColumnSizer()
        #expect(s.autoFit(contentWidths: [40, 120, 72, 90], minWidth: 20, maxWidth: 1000) == 120)
        #expect(s.autoFit(contentWidths: [], minWidth: 20, maxWidth: 1000) == 20)     // empty → floor
        #expect(s.autoFit(contentWidths: [5000], minWidth: 20, maxWidth: 800) == 800) // clamp to max
        #expect(s.autoFit(contentWidths: [3], minWidth: 20, maxWidth: 800) == 20)     // clamp to min
    }

    // Clearing a manual override reverts the column to its auto baseline (auto-
    // grow governs it again). RED: the seed's `resized` ignores the set (so the
    // "manual active" precondition already fails) and `cleared` is a no-op.
    @Test func columnSizingClearingRevertsToAutoGrow() {
        let s = ColumnSizer()
        let auto = [80.0, 80.0, 80.0]

        let manual = s.resized(manual: [:], column: 1, to: 50.0, minWidth: 20.0)
        #expect(s.effectiveWidths(auto: auto, manual: manual) == [80.0, 50.0, 80.0])  // manual active

        let cleared = s.cleared(manual: manual, column: 1)
        #expect(cleared[1] == nil)                                                    // override gone
        #expect(s.effectiveWidths(auto: auto, manual: cleared) == [80.0, 80.0, 80.0]) // reverted to auto
    }
}
