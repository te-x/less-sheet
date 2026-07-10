// Frozen behavior tests — select-copy slice (planner-owned), the PURE half.
//
// ARCH-select-copy turns the pure viewer into a tool: rectangular cell selection
// (unbounded index space), a byte-bounded lossless clipboard copy, and column
// resize / auto-fit — every operation bounded at 100M×100k scale. This file pins
// the DETERMINISTIC, no-GUI heart the frontend (NativeGrid event routing +
// ViewerModel state, App target — not importable by tests) must route through:
// the three pure Contracts surfaces `Selecting`, `CopyBuilding`, `ColumnSizing`
// (implemented in LessSheetKit as SelectionModel / TSVCopyBuilder / ColumnSizer).
// Same pattern as ColumnWindowingTests / the other view-model logic pins: pixels
// and dispatch stay in the App; the geometry, the byte-budgeting, the quoting,
// and the width algebra are exact and gate-stable HERE. The lossless full-cell
// COPY BRIDGE against the real core is CellCopyBridgeTests (the real-core half).
//
// WHAT EACH TEST PINS
//   selectCopyConformancePins ................. signature drift fails the build.
//   AC1 selection* .......................... each interaction yields the right
//     rect (click / drag / shift-click / arrow / shift-arrow / gutter / header),
//     and Cmd+A on a synthetic 100M×100k extent is the WHOLE rect, held O(1).
//   AC2 copyStopsAtByteBudget / …CellCap ...... copy stops at the tunable byte
//     budget OR the cell-count safety cap (all-empty huge selection), reports it.
//   AC3 copyTsvOrderingAndQuoting / …Lossless / …Frontier / single-cell raw ....
//     correct TSV order + Excel/Numbers quoting; a > 4 KiB cell included COMPLETE;
//     single cell = raw value; PENDING stops at the frontier row boundary.
//   AC4 copyBuilderRunsOffMain ................ the builder is Sendable, pure,
//     thread-agnostic (runs off the main actor) — the structural precondition for
//     a non-blocking copy (see the test's note).
//   AC5 columnSizing* ....................... manual override sticks + overrides
//     auto-grow; auto-fit computes the visible-window fit; clearing reverts.
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import: the
// LessSheetKit seed impls return trivial results — SelectionModel produces nil /
// unchanged selections, TSVCopyBuilder returns an EMPTY report, ColumnSizer
// ignores the manual map and returns the floor from autoFit. So every AC test
// below fails on behavior while the tree compiles (the conformances hold). AC4
// is green-by-construction (a structural guard, like ColumnWindowing's AC4).
//
// RED → GREEN (implementer): implement the three seeds per the Contracts
// doc-comments (SelectCopyLogic.swift) and route the App's selection state,
// Cmd+C copy (off-main), and column widths through them. No frozen path changes.
import Foundation
import Testing
import Contracts
import LessSheetKit

// Field/row separators + quote, as named constants so the expected TSV strings
// read unambiguously (no dense escape soup).
private let TAB = "\t"
private let NL = "\n"
private let Q = "\""

/// A `@Sendable` per-cell fetch backed by a `[row: [col: text]]` table; any cell
/// not in the table is an empty servable cell. All cells `.ok`, none truncated.
private func tableFetch(_ table: [UInt64: [Int: String]]) -> CopyCellFetch {
    { row, col in
        if let text = table[row]?[col] {
            return CopiedCell(status: .ok, text: text, truncated: false)
        }
        return .empty
    }
}

/// A thread-safe fetch-call counter (a `@Sendable` closure may run off-main and
/// on many threads). Used to prove the cell-count safety cap bounds FETCHES.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("select-copy (pure)")
struct SelectCopyTests {

    // Frozen conformance: the Kit types still satisfy the frozen signatures.
    @Test func selectCopyConformancePins() {
        let _: any Selecting = SelectionModel()
        let _: any CopyBuilding = TSVCopyBuilder()
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
        #expect(m.move(atTop, .up, in: extent).active == GridCell(row: 0, column: 3))
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

    // MARK: - AC2 — copy is BYTE-bounded + honest

    // Stops at the (tunable) byte budget mid-selection and reports it; the FIRST
    // cell is always emitted (progress guarantee) even when it alone exceeds the
    // budget. NOTE: the exact byte total depends on separator accounting — we pin
    // BOUNDEDNESS + the outcome + progress, never a magic size. RED: the seed
    // returns an empty `.complete` report.
    @Test func copyStopsAtByteBudget() {
        let b = TSVCopyBuilder()
        let cell = String(repeating: "X", count: 5)                  // 5 bytes each
        let fetch: CopyCellFetch = { _, _ in CopiedCell(status: .ok, text: cell, truncated: false) }

        // 1 row × 1000 columns; a tiny budget stops far short of all 1000 cells.
        let rect = SelectionRect(top: 0, bottom: 0, left: 0, right: 999)
        let budget = CopyBudget(maxTotalBytes: 40, maxCells: 1_000_000, perCellMaxBytes: 1 << 20)
        let rep = b.build(rect, budget: budget, fetch: fetch)
        #expect(rep.outcome == .stoppedAtBudget)
        #expect(rep.text.hasPrefix("XXXXX"))
        #expect(rep.byteCount >= cell.utf8.count)                    // progress: ≥ one cell
        #expect(rep.byteCount <= budget.maxTotalBytes + cell.utf8.count)  // bounded: budget + ≤1 cell
        #expect(rep.rowCount == 1)

        // Progress guarantee: the first cell is emitted even when it alone blows
        // a 2-byte budget; accumulation then stops immediately.
        let tiny = CopyBudget(maxTotalBytes: 2, maxCells: 1_000_000, perCellMaxBytes: 1 << 20)
        let rep2 = b.build(SelectionRect(top: 0, bottom: 0, left: 0, right: 2), budget: tiny, fetch: fetch)
        #expect(rep2.text == cell)
        #expect(rep2.outcome == .stoppedAtBudget)
    }

    // The cell-count SAFETY cap stops a pathological all-EMPTY huge selection
    // (≈0 content bytes, so the byte budget would let it fetch for millions of
    // rows) — and it bounds the number of FETCHES, not just the payload. RED: the
    // seed never fetches and reports `.complete`.
    @Test func copyStopsAtCellCountSafetyOnAllEmptyHugeSelection() {
        let b = TSVCopyBuilder()
        let counter = CallCounter()
        let fetch: CopyCellFetch = { _, _ in counter.bump(); return .empty }

        // 100k empty rows × 1 column, a huge byte budget, a small cell cap: the
        // cap (not bytes) must stop it, after at most `maxCells` fetches — proving
        // the fetch count tracks the CAP, not the (100k) rect.
        let rect = SelectionRect(top: 0, bottom: 99_999, left: 0, right: 0)
        let budget = CopyBudget(maxTotalBytes: 64 << 20, maxCells: 100, perCellMaxBytes: 1 << 20)
        let rep = b.build(rect, budget: budget, fetch: fetch)
        #expect(rep.outcome == .stoppedAtCellCap)
        #expect(counter.count <= budget.maxCells)                    // fetches bounded by the cap
        #expect(rep.rowCount <= UInt64(budget.maxCells))
    }

    // MARK: - AC3 — copy is lossless + correct

    // Single-cell copy = the RAW value: no quoting (even with an embedded tab),
    // no trailing newline. RED: the seed returns an empty report.
    @Test func copySingleCellIsRawValue() {
        let b = TSVCopyBuilder()
        let rect = SelectionRect(top: 0, bottom: 0, left: 0, right: 0)
        let fetch: CopyCellFetch = { _, _ in CopiedCell(status: .ok, text: "a" + TAB + "b", truncated: false) }
        let rep = b.build(rect, budget: .standard, fetch: fetch)
        #expect(rep.text == "a" + TAB + "b")                         // raw, unquoted
        #expect(rep.rowCount == 1)
        #expect(rep.outcome == .complete)
        #expect(rep.byteCount == ("a" + TAB + "b").utf8.count)
    }

    // Multi-cell TSV: row-major order, tab between columns, newline between rows,
    // no trailing newline; Excel/Numbers quoting for embedded tab / newline /
    // quote (interior quotes doubled). RED: the seed returns an empty report.
    @Test func copyTsvOrderingAndQuoting() {
        let b = TSVCopyBuilder()

        // Ordering: a 2×2 of plain cells → "A\tB\nC\tD".
        let plain = b.build(SelectionRect(top: 0, bottom: 1, left: 0, right: 1),
                            budget: .standard,
                            fetch: tableFetch([0: [0: "A", 1: "B"], 1: [0: "C", 1: "D"]]))
        #expect(plain.text == "A" + TAB + "B" + NL + "C" + TAB + "D")
        #expect(plain.rowCount == 2)
        #expect(plain.outcome == .complete)

        // Embedded TAB → the cell is quoted (so the tab is not read as a field
        // separator): x , "has<TAB>tab".
        let tabbed = b.build(SelectionRect(top: 0, bottom: 0, left: 0, right: 1),
                             budget: .standard,
                             fetch: tableFetch([0: [0: "x", 1: "has" + TAB + "tab"]]))
        #expect(tabbed.text == "x" + TAB + Q + "has" + TAB + "tab" + Q)

        // Embedded NEWLINE → quoted.
        let lined = b.build(SelectionRect(top: 0, bottom: 0, left: 0, right: 1),
                            budget: .standard,
                            fetch: tableFetch([0: [0: "y", 1: "two" + NL + "lines"]]))
        #expect(lined.text == "y" + TAB + Q + "two" + NL + "lines" + Q)

        // Embedded QUOTE → wrapped and interior quotes DOUBLED: p , "a""b".
        let quoted = b.build(SelectionRect(top: 0, bottom: 0, left: 0, right: 1),
                             budget: .standard,
                             fetch: tableFetch([0: [0: "p", 1: "a" + Q + "b"]]))
        #expect(quoted.text == "p" + TAB + Q + "a" + Q + Q + "b" + Q)
    }

    // Lossless: the builder emits whatever the closure returns WHOLE — it never
    // re-applies the 4 KiB display cap (the per-cell cap lives in the closure /
    // copyCell). A > 4 KiB cell comes through complete; a per-cell-`truncated`
    // cell is flagged via `lossyCells`. RED: the seed returns an empty report.
    @Test func copyIsLosslessAndFlagsPerCellTruncation() {
        let b = TSVCopyBuilder()
        let big = String(repeating: "A", count: 5000)               // > 4 KiB display cap

        let whole = b.build(SelectionRect(top: 0, bottom: 0, left: 0, right: 0),
                            budget: .standard,
                            fetch: { _, _ in CopiedCell(status: .ok, text: big, truncated: false) })
        #expect(whole.text == big)                                   // complete, not capped
        #expect(whole.text.count == 5000)
        #expect(whole.lossyCells == false)

        // A cell the per-cell cap cut → surfaced (honest notice), copy continues.
        let lossy = b.build(SelectionRect(top: 0, bottom: 0, left: 0, right: 1),
                            budget: .standard,
                            fetch: { _, col in
                                col == 0 ? CopiedCell(status: .ok, text: "ok", truncated: false)
                                         : CopiedCell(status: .ok, text: "cut", truncated: true)
                            })
        #expect(lossy.text == "ok" + TAB + "cut")
        #expect(lossy.lossyCells == true)
    }

    // A PENDING cell (a row past the scan frontier) stops the copy at that ROW
    // boundary (PENDING is per-row), so `rowCount` is exact for what was copied.
    // RED: the seed returns an empty `.complete` report.
    @Test func copyStopsAtFrontierRow() {
        let b = TSVCopyBuilder()
        // rows 0,1 servable; row 2+ pending. 1 column, rect rows 0…4.
        let fetch: CopyCellFetch = { row, _ in
            row < 2 ? CopiedCell(status: .ok, text: "r\(row)", truncated: false)
                    : CopiedCell(status: .pending, text: "", truncated: false)
        }
        let rep = b.build(SelectionRect(top: 0, bottom: 4, left: 0, right: 0), budget: .standard, fetch: fetch)
        #expect(rep.outcome == .stoppedAtFrontier)
        #expect(rep.rowCount == 2)
        #expect(rep.text == "r0" + NL + "r1")
    }

    // MARK: - AC4 — copy is non-blocking (structural pin)

    // The copy builder is PURE, `Sendable` value logic with a `@Sendable` fetch:
    // it does NO main-thread-only work, so the frontend runs a budget-filling copy
    // OFF the main thread and the UI stays live. This structural pin runs the
    // builder inside a DETACHED (off-main-actor) task — which COMPILES only
    // because the builder, budget, rect, closure, and report are all `Sendable`
    // (a main-actor dependency would fail Swift 6 strict concurrency right here)
    // — and confirms it completes off the main actor. Green-by-construction (a
    // no-regression guard, like ColumnWindowing's AC4): the actual GCD/Task
    // dispatch of Cmd+C, and the end-to-end "main thread responsive during a max
    // copy", are the App's (the build cell's) off-main-probe concern, mirroring
    // NativeGridProbeTests.
    @Test func copyBuilderRunsOffMainThread() async {
        let builder = TSVCopyBuilder()
        let budget = CopyBudget.standard
        let rect = SelectionRect(top: 0, bottom: 0, left: 0, right: 0)
        let fetch: CopyCellFetch = { _, _ in CopiedCell(status: .ok, text: "off", truncated: false) }

        let report = await Task.detached { builder.build(rect, budget: budget, fetch: fetch) }.value
        #expect(report.outcome == .complete)                         // completed off-main
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
