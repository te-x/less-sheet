# REVIEW — macOS: "columns resize on first interaction (with header)"

**Verdict: PASS (1 round, no findings).** Bound to tree-hash `114c3dc3…`, trusted gate 159/159
(incl. `launchColdOpenIsUnderBudget`/`wide_100k_cols`). macOS-only; core untouched.

## Bug + root cause
the author: with "first row is header" set, opening + a first interaction (a bounce at the top) makes
columns visibly resize. Diagnosed (`general-purpose` investigation): NOT a boundary bounce re-firing
the fit (that's a no-op via the window-unchanged guards), but a **deferred, racy header-width
refine** — `measureColumnWidths` at open got an EMPTY header placeholder + measured with the body
(monospaced) font → columns opened at min-width (72); the real **semibold** header width was applied
LATER by `growColumnWidthsToFitWindow`, gated by `refineHeaderWidths = markedGeneration != openGeneration`
(true only until the first-paint marker), so the widening popped in on the user's first post-open
interaction. Header-on made it visible (wide semibold labels).

## Fix
1. **Deterministic open-time header measurement (removes the race).** New `openHeaderLabels(for:)`
   returns real labels (`windowColumnLabels` for `CoreDocumentSession` — populated synchronously by
   `refreshWindowLabels` in `materialize(0,…)` BEFORE `columnWidths` is set; `headerCells` for legacy;
   empty for no-header). `measureColumnWidths` signature `header:[String]?` → `headerLabels:[Int:String]`;
   the header label is measured with the semibold `headFont` via the shared `textWidth` helper +
   `GridMetrics.cellHPadding*2` padding, and max-merged. `.size()` is bounded to the ≤256 fetched
   labels → **O(fetched), never O(columnCount)** (`wide_100k_cols` cold-open passes). **`refineHeaderWidths`
   REMOVED** — `growColumnWidthsToFitWindow` now measures the header unconditionally (same font/helper/
   padding/label bytes), so over the open window it's an idempotent no-op (no pop); later-scrolled
   columns get their header width deterministically. `markedGeneration` retained only for `markFirstRowsVisible`.
2. **Viewport-movement guard.** `NativeGrid.clipBoundsChanged` gates `viewportChanged`/`refreshColumnWindow`/
   `refreshColumnWidth(site:"scroll")` behind `fitViewport = moved && !over.x && !over.y`, where `moved`
   compares a remembered `lastFitViewport` identity `(clamped top data row, visible row count, clip x,
   clip width)` (0.5pt tolerance) and `over = overscrollAxes()`. Gutter/row-count/estimate refreshes stay
   unconditional (don't touch per-column widths). `lastFitViewport` reset on reopen so a new doc re-fits.

## Reviewer verification (PASS)
- **Idempotence (no residual pop):** header component byte-identical between open + grow (same
  `headFont`/`textWidth`/padding, same resolved label bytes); body component can only shrink or stay
  (`ceil(L·cw) ≤ L·ceil(cw)`, utf8-count over-counts) → the grow candidate test never fires for
  open-window columns. Only 3 `columnWidths` writes remain (open measure, monotone grow, dump-snapshot
  read) — no min-width fallback survives.
- **Perf:** open header `.size()` gated on present labels (≤256); grow's over `inWindow` only. O(fetched).
- **No over-suppression:** the identity tuple catches any real move (x/top/length/width); the 0.5pt
  tolerance only masks sub-pixel; `lastFitViewport` nil→first fit + reset on reopen.
- **`refineHeaderWidths` removal clean; conformance internal; no frozen drift.**
- Benign note (not a finding): an empty-header placeholder name ≥7 chars could grow a few pts under the
  semibold measure, but requires >321M columns (base-26) — categorically not the reported pop.

## Test-seam gap (non-blocking `[design]`) — TRACKED
No clean `LessSheetKit` unit pin: the header measure is AppKit (`NSFont.size`) and `DocumentModel` is in
the un-importable `.executableTarget` while `LessSheetKit` is AppKit-free. Accepted per the black-box-probe
precedent; follow-up = a `columnWidths` probe (reusing `EstimateReloadProbe`'s overscroll hold) asserting
open widths include the header + unchanged across a top overscroll. Visual no-pop = the author's desktop pass.

Scope: `Sources/LessSheetApp/ViewerModel.swift` + `Sources/LessSheetApp/NativeGrid.swift`.
