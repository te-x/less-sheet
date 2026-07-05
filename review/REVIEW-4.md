# REVIEW-4 — walking-skeleton (round 4)

Scope: fix for REVIEW-3 finding 1 (memory budget) plus the two non-blocking fixes (frame
restore, header junction). Only `apps/macos/Sources/LessSheetApp/AppUI.swift` changed; frozen
paths untouched (git status). Reviewer re-ran the root gate: **GATE: PASS** (backend + 11 frozen
Swift tests against the real linked core). All checks headless and TCC-free (markers via
`--stderr`, visuals via `LESSSHEET_DUMP_FRAME`, window presence via CGWindowList; the memory
runs were done WITHOUT the dump env var, which is only delivered via env and cannot leak into
normal launches).

## Criterion 18 re-measured — FIXED (release, 1,000,002,260-byte fixture, 3 doc-launches, no dump hook)
| Run | markers | windows | first_rows_visible_ms | ps RSS | phys_footprint |
|---|---|---|---|---|---|
| 1 | 1 | 1 | 207 | 95.7 MB | 28 MB |
| 2 | 1 | 1 | 226 | 95.6 MB | 28 MB |
| 3 | 1 | 1 | 196 | 95.5 MB | 28 MB |

- vs budget: ps RSS < 100 MB (papered margin ~4.5 MB — the standing "close to budget,
  framework-baseline-dominated" caveat from rounds 1–2 applies again); phys_footprint collapsed
  122 MB → 28 MB. Cold-start creep reversed: median 268 → 207 ms (< 500 ms). Matches the
  implementer's and coordinator's independent numbers (93–94 MB / 28 MB / 190–200 ms) within
  single-machine noise.

## Launch modes spot-checked — deterministic
- Direct exec (tiny.csv): 1 marker, 1 window, dump produced.
- `open -n -a … --args` (big.csv): 1 marker (190 ms), 1 window, dump produced.
- Doc-launch: table above. Always exactly one on-screen window.

## Dumps re-inspected (tiny + big)
- tiny.csv: filler columns/rows to both window edges; the data→filler ROW seam below `1,2` is a
  continuous hairline across ALL columns (data and filler); header/body vertical lines are
  continuous through the pinned-header junction — the round-3 half-point offset is gone
  (integer-edge Rectangles, header and body now share the same `SheetRow`).
- big.csv: 4 data columns + filler columns to the right edge; the data→filler COLUMN boundary
  after `notes` is seamless (horizontals continue, boundary vertical unbroken); 200-row head
  dense to the bottom (no filler in the overflowing axis, as designed); quoted cells
  (`some, quoted note N`) correct end-to-end.

## Code review of the per-row hairline approach — no blocking risks
- Laziness restored correctly: `bodyRows` is a `ForEach` emitted as the Section's content —
  rows are direct lazy children of the `LazyVStack`; only ~viewport rows materialize. The
  footprint measurement (28 MB, file-size-independent) confirms it.
- Scroll-time CPU: each `SheetRow` is `columns` Texts + `columns` 1-pt Rectangles + one
  full-width Rectangle — trivial per-row cost at 150-pt columns (≤ ~10 columns per screen),
  ≤ 200 rows total. No full-height backing store anywhere. Live scroll smoothness itself is
  human-eyes, but there is no structural risk.
- Filler count at exact-multiple viewport heights: `fit = ceil(H/28)`; for H = 28k the grid is
  exactly flush (no overhang). For non-multiples the grid overfills by < 28 pt, leaving a tiny
  scrollable overhang — pre-existing since round 3, cosmetic, unchanged.
- Seam correctness by construction: every row (data, filler, header) has identical geometry and
  draws its own bottom line, so the data→filler boundary cannot seam — confirmed in both dumps.
- Window frame restore: `setFrameUsingName` first, `center()` only when no saved frame —
  round-3 finding 4 fixed correctly.

## Standing accepted debt (non-blocking, explicitly accepted)
- Cmd-, opens an empty Settings window (inherent to the windowless `Settings` scene trick).
- Duplicate "View" menu.
- ps-RSS headroom vs the 100 MB budget is thin (~4.5 MB) and dominated by SwiftUI/AppKit
  baseline — slice 2 should budget accordingly.

## Human-eyes-only items (not attempted, per TCC constraint)
- Menu bar: File › Open… panel, checkable View › First Row Is Header toggle, the duplicate View
  menu, Settings… item.
- Live scrolling: pinned-header behavior and hairline alignment while scrolled, scroll
  smoothness, the < 28 pt overhang.
- Close-button → quit, Dock-click reopen, dark-mode rendering.

## Verdict
**PASS**
