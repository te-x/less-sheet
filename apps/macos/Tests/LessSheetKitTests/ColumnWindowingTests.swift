// Frozen behavior tests — column-windowing slice (planner-owned).
//
// ARCH-column-windowing makes the macOS frontend's cold-open first-paint and
// each scroll tick O(visible column range), not O(total columns) — the
// horizontal analog of the row window it already has — closing the measured
// wide-doc gap (wide_100k_cols cold-open 3034 ms -> < 500 ms). The headline
// acceptance (AC1) is the ALREADY-FROZEN process-launch probe in
// CorpusColdOpenTests (wide_100k_cols first_rows_visible_ms < 500) — NOT
// duplicated or modified here. This file pins the DETERMINISTIC, no-GUI heart:
// the pure column geometry + width algebra (`Contracts.ColumnLayouting`,
// implemented in LessSheetKit as `ColumnLayout`), which the frontend
// (ViewerModel / NativeGrid, App target — not importable by tests) must route
// its measure / cell-fetch / layout / draw through. Same pattern as the other
// view-model logic pins (ColumnVisibilityManaging, JumpControlling, …): the pixel
// measurement of a single cell (NSFont) stays in the App; the O(viewport) bound,
// the positions, and the decided width behaviour are pinned here on the pure
// layer, where they are exact and gate-stable.
//
// WHAT EACH TEST PINS
//   - columnLayoutConformancePins ....... signature drift fails the build (the
//                                         frozen conformance check).
//   - firstPaintTouchesViewportColumnsNotAllColumns (AC2): a first paint over a
//     100k-column model touches a viewport-bounded column count (a few hundred),
//     INDEPENDENT of the total column count.
//   - horizontalScrollStepStaysBounded (AC3): a scroll step deep into a wide doc
//     computes a bounded window POSITIONED at the scrolled region — it does not
//     walk from column 0 / touch O(total) columns.
//   - viewportFittingFileLaysOutEveryColumnUnchanged (AC4): a file whose columns
//     all fit lays out EVERY column at firstX 0 (identical to a non-windowed
//     draw); firstX is the exact prefix-sum x of `first` (no positional drift),
//     including the windowed case.
//   - establishedWidthGrowsMonotoneAndSurvivesHorizontalScroll (AC5b): a column
//     grows only to fit its OWN revealed content, monotonically; one column's
//     content never changes another's width; and horizontal scroll never churns
//     an established width (out of view and back = identical).
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import:
// `LessSheetKit.ColumnLayout` is a stub reproducing today's un-windowed frontend
// — `window` returns the WHOLE column range (`count == widths.count`), `grown`
// returns widths unchanged. So:
//   - AC2 fails: window count is `columnCount` (100000), not a few hundred, and
//     scales with the total (100000 != 300).
//   - AC3 fails: the window starts at column 0 and spans all 100000 columns
//     rather than a bounded run at the scrolled region.
//   - AC5b fails: a column never grows to fit revealed content, and a far
//     column's growth is never retained.
//   - AC4 already PASSES (a full range at firstX 0 IS the fitting-file layout) —
//     it is the no-regression guard that must stay green as the window becomes
//     real, so it is deliberately satisfiable by the seed.
//
// RED -> GREEN (implementer): implement `ColumnLayouting` for real (prefix-sum +
// binary-search window; monotone per-column width merge — see the contract doc
// and the seed's header) and route the App's measure/fetch/layout/draw + width
// establishment/growth through it. That same wiring is what carries
// wide_100k_cols under the 500 ms cold-open budget (csv-corpus AC5 / AC1).
import Foundation
import Testing
import Contracts
import LessSheetKit

// A realistic-ish monospaced column width (points). The absolute value is
// irrelevant to every assertion below — the pins are on RATIOS to the viewport,
// independence from the total column count, positions, and monotone growth — so
// they hold regardless of the frontend's exact metrics.
private let columnW = 80.0
private let viewportW = 960.0     // the grid's initial content width (NativeGrid)
private let overscan = 8          // a representative small overscan; assertions never pin its exact value

/// The number of columns whose x-extent intersects a `viewportW`-wide viewport
/// over uniform `columnW` columns — the lower bound a correct window must cover.
private var viewportColumns: Int { Int((viewportW / columnW).rounded(.up)) } // 12

/// A generous "a few hundred" ceiling: decisively sub-linear in a 100k-column
/// document, yet loose enough never to constrain the implementer's overscan.
private let viewportBound = 256

@Suite("column-windowing")
struct ColumnWindowingTests {

    // Frozen conformance: the Kit type still satisfies the frozen signature.
    @Test func columnLayoutConformancePins() {
        let _: any ColumnLayouting = ColumnLayout()
    }

    // AC2 — O(viewport), not O(total). A first paint on a synthetic 100k-column
    // model touches a column count bounded by the viewport (+ overscan), NOT the
    // total. RED: the seed returns the whole 100000-column range.
    @Test func firstPaintTouchesViewportColumnsNotAllColumns() {
        let layout = ColumnLayout()
        let total = 100_000
        let widths = [Double](repeating: columnW, count: total)

        let win = layout.window(widths: widths, viewportX: 0, viewportWidth: viewportW, overscan: overscan)

        // Correctness: the window must at least cover the visible viewport.
        #expect(win.count >= viewportColumns,
                "window must cover the viewport (>= \(viewportColumns) columns), got \(win.count)")
        // The O(viewport) bound: a few hundred at most, not 100000.
        #expect(win.count <= viewportBound,
                "first paint touched \(win.count) columns for a \(viewportW)pt viewport over \(total) columns — must be O(viewport), not O(total)")
        // The decisive pin: window size does NOT scale with the total column
        // count. The SAME viewport over 300 columns must yield the SAME count —
        // the far 99_700 columns are irrelevant to the paint.
        let small = layout.window(widths: [Double](repeating: columnW, count: 300),
                                  viewportX: 0, viewportWidth: viewportW, overscan: overscan)
        #expect(win.count == small.count,
                "window size must be independent of total column count (\(total) -> \(win.count), 300 -> \(small.count))")
    }

    // AC3 — a horizontal scroll step is O(viewport), not O(total). Windowing deep
    // into a wide doc yields a bounded run POSITIONED at the scrolled region.
    // RED: the seed always starts at column 0 and spans all columns.
    @Test func horizontalScrollStepStaysBounded() {
        let layout = ColumnLayout()
        let total = 100_000
        let widths = [Double](repeating: columnW, count: total)
        let targetCol = 50_000
        let viewportX = Double(targetCol) * columnW   // left edge at column 50_000

        let win = layout.window(widths: widths, viewportX: viewportX, viewportWidth: viewportW, overscan: overscan)

        // Same O(viewport) bound as a cold paint — a scroll tick is bounded work.
        #expect(win.count <= viewportBound,
                "a scroll step touched \(win.count) columns — must be O(viewport), not O(total)")
        // Correctness: the column at the viewport's left edge is in the window.
        #expect(win.first <= targetCol && targetCol < win.upperBound,
                "window must contain the column at the viewport's left edge (\(targetCol)); got \(win.range)")
        // Positioned AT the scrolled region — NOT walked from column 0. (A bound
        // far looser than any sane overscan, so only an O(total) window fails it.)
        #expect(win.first > targetCol - viewportBound,
                "window must start at the scrolled region, not near column 0 (first=\(win.first))")
    }

    // AC4 — no regression for viewport-fitting files. All columns lay out at their
    // true positions; firstX is the exact prefix-sum x of `first`. GREEN under the
    // seed by design (a full range at firstX 0 is the fitting-file layout) — the
    // guard that the real window must not regress this.
    @Test func viewportFittingFileLaysOutEveryColumnUnchanged() {
        let layout = ColumnLayout()

        // A handful of columns that fit within the viewport (sum 532 < 960).
        let fitting = [120.0, 90.0, 72.0, 150.0, 100.0]
        let win = layout.window(widths: fitting, viewportX: 0, viewportWidth: viewportW, overscan: overscan)
        #expect(win.range == 0..<fitting.count,
                "a viewport-fitting file must lay out EVERY column, got \(win.range)")
        #expect(win.firstX == 0, "the first column of a fitting file starts at x 0")

        // Positional no-regression, including the WINDOWED case: firstX must equal
        // Σ widths[0..<first], so in-window columns keep the exact x a naive
        // full-width draw would give them (no drift).
        let wide = [Double](repeating: columnW, count: 100_000)
        let scrolled = layout.window(widths: wide, viewportX: columnW * 50_000,
                                     viewportWidth: viewportW, overscan: overscan)
        let expectedX = wide[0..<scrolled.first].reduce(0, +)
        #expect(abs(scrolled.firstX - expectedX) < 0.001,
                "firstX must equal Σ widths[0..<first] (expected \(expectedX), got \(scrolled.firstX))")
    }

    // AC5b — the DECIDED width behaviour. A column grows only to fit its OWN
    // revealed content, monotonically; one column's content never affects
    // another's width; horizontal scroll never churns an established width. RED:
    // the seed never grows a column, so revealed/retained growth assertions fail.
    @Test func establishedWidthGrowsMonotoneAndSurvivesHorizontalScroll() {
        let layout = ColumnLayout()
        let established = [Double](repeating: 72.0, count: 6)   // widths set at open

        // Grows to fit its OWN revealed content (the vertical row window revealed a
        // longer cell in column 2), and NOTHING else moves (independence).
        let grown = layout.grown(established, mergingCandidates: [2: 140.0])
        #expect(grown[2] == 140.0, "a column must grow to fit its own revealed content")
        #expect(grown[0] == 72.0 && grown[1] == 72.0 && grown[3] == 72.0 && grown[5] == 72.0,
                "growing one column must not change any other (each width is its own content alone)")
        #expect(zip(grown, established).allSatisfy { $0 >= $1 }, "growth is monotone — a width never shrinks")

        // A smaller candidate never shrinks an established width (monotone).
        #expect(layout.grown([100.0], mergingCandidates: [0: 40.0]) == [100.0],
                "a smaller candidate must never shrink an established width")

        // Horizontal scroll never churns an established width. Establish column 1;
        // scroll far right (column 5 is measured + grows) — column 1 is untouched;
        // scroll back (column 1 re-measured over the SAME vertical window = same
        // content) — column 1 is exactly as it was, and the far growth is retained.
        let base = layout.grown(established, mergingCandidates: [1: 96.0])
        let afterRight = layout.grown(base, mergingCandidates: [5: 300.0])
        #expect(afterRight[1] == 96.0, "scrolling right must not change an already-established near column")
        let afterBack = layout.grown(afterRight, mergingCandidates: [1: 96.0])
        #expect(afterBack[1] == base[1], "a column is exactly as you left it after scrolling out of view and back")
        #expect(afterBack[5] == 300.0, "the far column's growth is retained (monotone), not lost on scroll-back")
    }
}
