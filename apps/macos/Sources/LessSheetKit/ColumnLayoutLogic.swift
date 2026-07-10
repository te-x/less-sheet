import Contracts

// RED SEED (planner-authored; implementer-owned, NOT frozen — replace this with
// the real horizontal column window per ARCH-column-windowing).
//
// This stub deliberately reproduces TODAY'S un-windowed frontend so the new
// behavior tests are RED on BEHAVIOR while compiling + linking cleanly:
//   - `window(...)` returns the WHOLE column range (`first: 0, count: widths.count`)
//     at `firstX: 0` — exactly what the current grid does (`visibleColumns` is
//     every non-hidden column, laid out and drawn in full). So the O(viewport)
//     tests (AC2 first-paint bound, AC3 scroll bound) FAIL: `count` is
//     `columnCount`, not a function of the viewport.
//   - `grown(...)` returns `current` unchanged, so the width-growth / stability
//     test (AC5b) FAILS: a column never grows to fit its revealed content.
// The no-regression positional pin (AC4) is already GREEN here — a full range at
// firstX 0 IS the correct layout for a viewport-fitting file — which is exactly
// what that guard must keep asserting once the window is real.
//
// RED -> GREEN (implementer): implement `ColumnLayouting` for real —
//   - `window`: prefix-sum the widths (rebuilt only when a width batch changes,
//     off the per-frame path) and binary-search the viewport x-range to
//     `[first, first+count)` + overscan, clamped to the column count; set
//     `firstX` to the prefix sum at `first`. Then bound the frontend's
//     measure / cell-fetch / draw loops (ViewerModel `visibleColumns.map` /
//     `measureColumnWidths` / `growColumnWidthsToFitWindow`; NativeGrid
//     `SheetRowView.draw` / `GridHeaderView.draw`) to this range, and drive the
//     ROW/HEADER draw x from `firstX`.
//   - `grown`: monotone per-column max-merge (see the contract doc). Route the
//     App's width establishment + growth through it so the DECIDED width
//     behaviour holds.
// Wiring this is what makes csv-corpus AC5 (`wide_100k_cols` first-paint < 500 ms)
// go green — the headline acceptance for AC1.
public struct ColumnLayout: ColumnLayouting {
    public init() {}

    public func window(widths: [Double], viewportX: Double, viewportWidth: Double, overscan: Int) -> ColumnWindow {
        ColumnWindow(first: 0, count: widths.count, firstX: 0)
    }

    public func grown(_ current: [Double], mergingCandidates candidates: [Int: Double]) -> [Double] {
        current
    }
}
