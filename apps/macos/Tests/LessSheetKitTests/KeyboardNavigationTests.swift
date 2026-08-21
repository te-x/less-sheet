// Frozen behavior tests — macOS keyboard cell-navigation (ARCH-macos-kbdnav),
// the PURE half. Planner-owned.
//
// This slice brings macOS to keyboard-navigation parity with the signed GTK
// a11y slice: arrows always move a cell cursor (seeding at the top-left visible
// cell with no step), a full page/document/line command set over the ONE shared
// selection, minimal-reveal auto-scroll, keyboard-only single-cell copy, and an
// Esc that clears the selection as its lowest-priority step. VoiceOver /
// NSAccessibility is explicitly OUT of scope (author-deferred).
//
// It pins the DETERMINISTIC, no-GUI heart the frontend (SheetTableView key
// routing + NativeGridController clip scroll + SheetRowView outline paint, App
// target — not importable by tests) must route through: the pure Contracts
// surfaces KeyboardNavigating / RevealScrolling / EscapeResolving (implemented
// in LessSheetKit as KeyboardNavigator / RevealScroller / EscapeResolver). Same
// pattern as SelectCopyTests: pixels, key events, focus, and rendered
// appearance stay in the App (verified by the H1–H4 human GUI pass); the
// geometry, the reveal arithmetic, and the Esc truth table are exact and
// gate-stable HERE.
//
// WHAT EACH TEST PINS
//   conformancePins ............ signature drift fails the build (G8).
//   G1 seedNoStep .............. from nil, EVERY command (plain + extending)
//     seeds a 1×1 at (topVisibleRow, firstVisibleColumn), no step.
//   G2 directionalMove* ........ plain arrows collapse+step over VISIBLE columns
//     (skip hidden, clamp at ends); shift-arrows keep the anchor; a shift-extend
//     rect SPANS the hidden columns it covers (visibility-blind, Q3).
//   G3 pageDocumentLine* ....... Page/Home/End/Cmd-arrow targets, plain + shift.
//   G4 clampingAndEmptyExtent .. steps clamp at edges; every result stays in the
//     visible-column set (a hidden active corner snaps visible); empty extent →
//     nil for every command.
//   G5 minimalRevealScrollMath . byte-exact landOn-style clamp on each axis;
//     no move when already visible; independent axes.
//   G6 singleCellKeyboardCopyRect a seeded/collapsed cursor is a 1×1 rect
//     (isSingleCell), driving the existing single-cell raw copy path unchanged.
//   G7 escapePrecedenceTruthTable enum-exact dismiss > cancel > clear > none;
//     escapeHandlerDispatchesOnResolver — handleEscape routes through the
//     resolver (structural source check).
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import: the
// LessSheetKit seeds return trivial results (navigate → the input unchanged;
// reveal → no move; resolve → .none). So every G test below fails on behavior
// while the tree compiles (the conformances hold).
//
// RED → GREEN (implementer): implement the seeds per the Contracts doc-comments
// (KeyboardNavigationLogic.swift) — KeyboardNavigator COMPOSING the frozen
// Selecting — and wire the App (key routing, clip scroll, accent outline, and
// handleEscape dispatching on EscapeResolver). No frozen path changes.
import Foundation
import Testing
import Contracts
import LessSheetKit

@Suite("macos-kbdnav (pure)")
struct KeyboardNavigationTests {

    // MARK: - Helpers

    private func cell(_ row: UInt64, _ column: Int) -> GridCell {
        GridCell(row: row, column: column)
    }

    private func selection(_ anchor: (UInt64, Int), _ active: (UInt64, Int)) -> Selection {
        Selection(anchor: cell(anchor.0, anchor.1), active: cell(active.0, active.1))
    }

    /// A vertical descriptor whose active row is already fully visible (so a
    /// combined reveal isolates the horizontal axis): row 10 at rowHeight 22 is
    /// content-y 220..242, inside the unobscured [154, 600) at originY 100.
    private func visibleVertical() -> VerticalReveal {
        VerticalReveal(activeRow: 10, rowHeight: 22, contentInsetTop: 54,
                       originY: 100, viewportHeight: 500, maxY: 21_500)
    }

    /// A horizontal descriptor already fully visible (isolates the vertical
    /// axis): 100..180 inside [50, 450) at originX 50.
    private func visibleHorizontal() -> HorizontalReveal {
        HorizontalReveal(leftX: 100, width: 80, originX: 50, viewportWidth: 400, maxX: 2_000)
    }

    // MARK: - G8 — frozen conformance

    @Test func conformancePins() {
        let _: any KeyboardNavigating = KeyboardNavigator()
        let _: any RevealScrolling = RevealScroller()
        let _: any EscapeResolving = EscapeResolver()
    }

    // MARK: - G1 — seed (no step)

    @Test func seedNoStep() {
        let nav = KeyboardNavigator()

        // Fixture A: all columns visible, scrolled to top row 10 / column 3.
        let contextA = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 50),
            visibleColumns: Array(0..<50), topVisibleRow: 10, firstVisibleColumn: 3, pageRows: 20
        )
        let seedA = selection((10, 3), (10, 3))
        for motion in NavigationMotion.allCases {
            for extending in [false, true] {
                let result = nav.navigate(from: nil, motion, extending: extending, in: contextA)
                #expect(result == seedA, "seed \(motion) extending=\(extending)")
                #expect(result?.rect == SelectionRect(top: 10, bottom: 10, left: 3, right: 3))
                #expect(result?.rect.isSingleCell == true)
            }
        }

        // Fixture B: a scrolled column window — the leading on-screen column (5)
        // is a visible column, not necessarily the document's first.
        let contextB = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 10),
            visibleColumns: [2, 5, 7, 8], topVisibleRow: 0, firstVisibleColumn: 5, pageRows: 15
        )
        let seedB = selection((0, 5), (0, 5))
        #expect(nav.navigate(from: nil, .right, extending: true, in: contextB) == seedB)
        #expect(nav.navigate(from: nil, .documentEnd, extending: false, in: contextB) == seedB)
        #expect(nav.navigate(from: nil, .lineEnd, extending: true, in: contextB) == seedB)
    }

    // MARK: - G2 — directional move / extend over VISIBLE columns

    @Test func directionalMoveExtendVisibleColumns() {
        let nav = KeyboardNavigator()
        // 0, 3, 5, 6, 9 hidden — interior AND edge hidden columns.
        let context = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 10),
            visibleColumns: [1, 2, 4, 7, 8], topVisibleRow: 0, firstVisibleColumn: 1, pageRows: 20
        )
        let start = selection((5, 4), (5, 4))

        // Plain steps collapse to a single cell over VISIBLE columns.
        #expect(nav.navigate(from: start, .right, extending: false, in: context) == selection((5, 7), (5, 7)))
        #expect(nav.navigate(from: start, .left, extending: false, in: context) == selection((5, 2), (5, 2)))
        #expect(nav.navigate(from: start, .down, extending: false, in: context) == selection((6, 4), (6, 4)))
        #expect(nav.navigate(from: start, .upward, extending: false, in: context) == selection((4, 4), (4, 4)))

        // Clamp at the first / last VISIBLE column (hidden edges 0 and 9 skipped).
        let atFirst = selection((5, 1), (5, 1))
        #expect(nav.navigate(from: atFirst, .left, extending: false, in: context) == atFirst)
        let atLast = selection((5, 8), (5, 8))
        #expect(nav.navigate(from: atLast, .right, extending: false, in: context) == atLast)

        // Shift keeps the anchor and moves only the active corner.
        let extRight = nav.navigate(from: start, .right, extending: true, in: context)
        #expect(extRight?.anchor == cell(5, 4))
        #expect(extRight?.active == cell(5, 7))
        // (b) the resulting rect SPANS the hidden columns 5 and 6 it covers.
        #expect(extRight?.rect == SelectionRect(top: 5, bottom: 5, left: 4, right: 7))
        #expect(extRight?.rect.columns == 4...7)

        // A wider shift-extend spans multiple hidden columns (3, 5, 6).
        let wide = nav.navigate(from: selection((5, 2), (5, 4)), .right, extending: true, in: context)
        #expect(wide?.anchor == cell(5, 2))
        #expect(wide?.active == cell(5, 7))
        #expect(wide?.rect == SelectionRect(top: 5, bottom: 5, left: 2, right: 7))
    }

    // MARK: - G3 — page / document / line commands

    @Test func pageDocumentLineCommands() {
        let nav = KeyboardNavigator()
        let context = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 10),
            visibleColumns: [1, 2, 4, 7, 8], topVisibleRow: 100, firstVisibleColumn: 4, pageRows: 20
        )
        let start = selection((100, 4), (100, 4))

        // Page steps ± pageRows (column kept).
        #expect(nav.navigate(from: start, .pageDown, extending: false, in: context) == selection((120, 4), (120, 4)))
        #expect(nav.navigate(from: start, .pageUp, extending: false, in: context) == selection((80, 4), (80, 4)))

        // Document ends: row 0 / lastRow (column kept). Home/End and Cmd+↑/↓
        // share these targets.
        #expect(nav.navigate(from: start, .documentStart, extending: false, in: context) == selection((0, 4), (0, 4)))
        #expect(nav.navigate(from: start, .documentEnd, extending: false, in: context) == selection((999, 4), (999, 4)))

        // Line ends: first / last VISIBLE column (row kept).
        #expect(nav.navigate(from: start, .lineStart, extending: false, in: context) == selection((100, 1), (100, 1)))
        #expect(nav.navigate(from: start, .lineEnd, extending: false, in: context) == selection((100, 8), (100, 8)))

        // Page clamps at the document edges.
        #expect(nav.navigate(from: selection((990, 4), (990, 4)), .pageDown, extending: false, in: context)
                == selection((999, 4), (999, 4)))
        #expect(nav.navigate(from: selection((5, 4), (5, 4)), .pageUp, extending: false, in: context)
                == selection((0, 4), (0, 4)))

        // The active column at an edge is preserved by a row command.
        #expect(nav.navigate(from: selection((100, 1), (100, 1)), .pageDown, extending: false, in: context)
                == selection((120, 1), (120, 1)))
        #expect(nav.navigate(from: selection((100, 8), (100, 8)), .pageDown, extending: false, in: context)
                == selection((120, 8), (120, 8)))

        // Shift variant keeps the anchor and moves only the active corner.
        let extEnd = nav.navigate(from: start, .documentEnd, extending: true, in: context)
        #expect(extEnd?.anchor == cell(100, 4))
        #expect(extEnd?.active == cell(999, 4))
        #expect(extEnd?.rect == SelectionRect(top: 100, bottom: 999, left: 4, right: 4))

        let extLineEnd = nav.navigate(from: start, .lineEnd, extending: true, in: context)
        #expect(extLineEnd?.anchor == cell(100, 4))
        #expect(extLineEnd?.active == cell(100, 8))
        #expect(extLineEnd?.rect == SelectionRect(top: 100, bottom: 100, left: 4, right: 8))
    }

    // MARK: - G4 — clamping + empty extent

    @Test func clampingAndEmptyExtent() {
        let nav = KeyboardNavigator()
        let context = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 10),
            visibleColumns: [1, 2, 4, 7, 8], topVisibleRow: 0, firstVisibleColumn: 1, pageRows: 20
        )

        // A step past an edge stays on the edge (and collapses a range).
        #expect(nav.navigate(from: selection((0, 1), (0, 4)), .upward, extending: false, in: context)
                == selection((0, 4), (0, 4)))
        #expect(nav.navigate(from: selection((999, 1), (999, 4)), .down, extending: false, in: context)
                == selection((999, 4), (999, 4)))
        #expect(nav.navigate(from: selection((5, 4), (5, 1)), .left, extending: false, in: context)
                == selection((5, 1), (5, 1)))
        #expect(nav.navigate(from: selection((5, 4), (5, 8)), .right, extending: false, in: context)
                == selection((5, 8), (5, 8)))

        // Every result stays in the VISIBLE-column set: a hidden active corner
        // (reachable only via Cmd+A / whole-row select — column 9 is hidden here)
        // snaps to the nearest visible column BEFORE the command applies, so the
        // cursor is never invisible.
        let hidden = selection((0, 0), (500, 9))
        #expect(nav.navigate(from: hidden, .down, extending: false, in: context) == selection((501, 8), (501, 8)))
        #expect(nav.navigate(from: hidden, .left, extending: false, in: context) == selection((500, 7), (500, 7)))
        #expect(nav.navigate(from: hidden, .right, extending: false, in: context) == selection((500, 8), (500, 8)))

        // Empty extent (no rows) → nil for every command, from nil or a stale
        // selection, plain or extending (matches the frozen Selecting).
        let noRows = NavigationContext(
            extent: GridExtent(rowCount: 0, columnCount: 10),
            visibleColumns: [1, 2, 4, 7, 8], topVisibleRow: 0, firstVisibleColumn: 1, pageRows: 20
        )
        #expect(nav.navigate(from: nil, .down, extending: false, in: noRows) == nil)
        #expect(nav.navigate(from: selection((0, 1), (0, 1)), .right, extending: true, in: noRows) == nil)

        // Empty extent (no columns) → nil likewise.
        let noColumns = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 0),
            visibleColumns: [], topVisibleRow: 0, firstVisibleColumn: 0, pageRows: 20
        )
        #expect(nav.navigate(from: nil, .lineEnd, extending: false, in: noColumns) == nil)
        #expect(nav.navigate(from: selection((0, 0), (0, 0)), .down, extending: false, in: noColumns) == nil)
    }

    // MARK: - G5 — minimal-reveal auto-scroll math (pure)

    @Test func minimalRevealScrollMath() {
        let scroller = RevealScroller()

        // Already fully visible on both axes → no move, origin unchanged.
        #expect(scroller.reveal(vertical: visibleVertical(), horizontal: visibleHorizontal())
                == RevealScroll(originX: 50, originY: 100, movedX: false, movedY: false))

        // Vertical just past the top (scrolled too far down): reveal to the top
        // inset — landOn's `row·rowHeight − contentInsetTop` = 220 − 54 = 166.
        let pastTop = VerticalReveal(activeRow: 10, rowHeight: 22, contentInsetTop: 54,
                                     originY: 200, viewportHeight: 500, maxY: 21_500)
        #expect(scroller.reveal(vertical: pastTop, horizontal: visibleHorizontal())
                == RevealScroll(originX: 50, originY: 166, movedX: false, movedY: true))

        // Vertical just past the bottom: reveal so the cell bottom meets the
        // viewport bottom — (30+1)·22 − 500 = 682 − 500 = 182.
        let pastBottom = VerticalReveal(activeRow: 30, rowHeight: 22, contentInsetTop: 54,
                                        originY: 100, viewportHeight: 500, maxY: 21_500)
        #expect(scroller.reveal(vertical: pastBottom, horizontal: visibleHorizontal())
                == RevealScroll(originX: 50, originY: 182, movedX: false, movedY: true))

        // Horizontal off the left: reveal to the cell's left edge.
        let offLeft = HorizontalReveal(leftX: 100, width: 80, originX: 200, viewportWidth: 400, maxX: 2_000)
        #expect(scroller.reveal(vertical: visibleVertical(), horizontal: offLeft)
                == RevealScroll(originX: 100, originY: 100, movedX: true, movedY: false))

        // Horizontal off the right: reveal so the cell right meets the viewport
        // right — 1080 − 400 = 680.
        let offRight = HorizontalReveal(leftX: 1_000, width: 80, originX: 200, viewportWidth: 400, maxX: 2_000)
        #expect(scroller.reveal(vertical: visibleVertical(), horizontal: offRight)
                == RevealScroll(originX: 680, originY: 100, movedX: true, movedY: false))

        // A corner requiring BOTH axes to move (independent results).
        #expect(scroller.reveal(vertical: pastBottom, horizontal: offRight)
                == RevealScroll(originX: 680, originY: 182, movedX: true, movedY: true))

        // Clamp to maxY: the last row's reveal saturates at the content bottom.
        let atEnd = VerticalReveal(activeRow: 999, rowHeight: 22, contentInsetTop: 54,
                                   originY: 100, viewportHeight: 500, maxY: 21_500)
        #expect(scroller.reveal(vertical: atEnd, horizontal: visibleHorizontal())
                == RevealScroll(originX: 50, originY: 21_500, movedX: false, movedY: true))

        // Clamp to minY (= −contentInsetTop): revealing row 0 rests it at the top.
        let atTop = VerticalReveal(activeRow: 0, rowHeight: 22, contentInsetTop: 54,
                                   originY: 300, viewportHeight: 500, maxY: 21_500)
        #expect(scroller.reveal(vertical: atTop, horizontal: visibleHorizontal())
                == RevealScroll(originX: 50, originY: -54, movedX: false, movedY: true))

        // Horizontal maxX boundary: the last column's reveal meets maxX exactly.
        let atRightEdge = HorizontalReveal(leftX: 2_320, width: 80, originX: 0, viewportWidth: 400, maxX: 2_000)
        #expect(scroller.reveal(vertical: visibleVertical(), horizontal: atRightEdge)
                == RevealScroll(originX: 2_000, originY: 100, movedX: true, movedY: false))
    }

    // MARK: - G6 — single-cell keyboard copy rect unchanged

    @Test func singleCellKeyboardCopyRect() {
        let nav = KeyboardNavigator()
        let context = NavigationContext(
            extent: GridExtent(rowCount: 1000, columnCount: 10),
            visibleColumns: Array(0..<10), topVisibleRow: 0, firstVisibleColumn: 0, pageRows: 20
        )

        // A seeded cursor is a 1×1 rect (drives the existing single-cell raw copy
        // special case — no whole-row copy for a bare cursor).
        let seeded = nav.navigate(from: nil, .right, extending: false, in: context)
        #expect(seeded?.rect.isSingleCell == true)
        #expect(seeded?.rect == SelectionRect(top: 0, bottom: 0, left: 0, right: 0))

        // A plain command COLLAPSES a range to a single cell.
        let collapsed = nav.navigate(from: selection((2, 2), (6, 5)), .down, extending: false, in: context)
        #expect(collapsed?.rect.isSingleCell == true)
        #expect(collapsed == selection((7, 5), (7, 5)))

        // The rect property the copy engine special-cases (unchanged this slice).
        #expect(SelectionRect(top: 3, bottom: 3, left: 4, right: 4).isSingleCell == true)
    }

    // MARK: - G7 — Escape-precedence resolver (pure truth table)

    @Test func escapePrecedenceTruthTable() {
        let resolver = EscapeResolver()
        func action(_ popup: Bool, _ copy: Bool, _ hasSelection: Bool) -> EscapeAction {
            resolver.resolve(EscapeContext(popupOrSearchActive: popup, copyInFlight: copy, hasSelection: hasSelection))
        }

        // Priority 1: a popup/search wins regardless of the lower facts.
        #expect(action(true, true, true) == .dismissPopups)
        #expect(action(true, true, false) == .dismissPopups)
        #expect(action(true, false, true) == .dismissPopups)
        #expect(action(true, false, false) == .dismissPopups)
        // Priority 2: an in-flight copy wins over a selection.
        #expect(action(false, true, true) == .cancelCopy)
        #expect(action(false, true, false) == .cancelCopy)
        // Priority 3: clear the selection.
        #expect(action(false, false, true) == .clearSelection)
        // Otherwise nothing.
        #expect(action(false, false, false) == .none)
    }

    /// Structural: `handleEscape` dispatches on the pure resolver rather than
    /// duplicating the branch logic. Locates the App source from this file's
    /// compile-time path (the same technique as AmendmentContractGuardTests),
    /// so it is independent of the runner's working directory. RED at freeze
    /// (handleEscape still branches inline); GREEN once the implementer routes
    /// it through `EscapeResolver`.
    @Test func escapeHandlerDispatchesOnResolver() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../LessSheetKitTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // .../macos
            .appendingPathComponent("Sources/LessSheetApp/NativeGrid+Selection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains("EscapeResolver"),
                "handleEscape must dispatch on the pure EscapeResolver, not inline branch logic.")
        #expect(source.contains("resolve("),
                "handleEscape must call the resolver's resolve(_:) to pick the Esc action.")
    }
}
