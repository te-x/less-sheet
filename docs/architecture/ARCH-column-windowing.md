# ARCH — column-windowing (bound frontend first-paint to the visible column range)

**Feature:** make the macOS frontend's cold-open and scroll cost **O(visible column range)**, not
**O(total columns)** — the horizontal analog of the row window it already has. Fixes the measured
wide-doc cold-start gap: opening a 100k-column file takes 3034 ms to first paint (must be < 500 ms).

**Read first:** `docs/architecture/ARCH-csv-corpus.md` (AC5, the frozen probe that measures this),
the workspace `CLAUDE.md` cold-start budget, `[[outlier-budget-policy]]` (wide docs: relax memory/time,
NEVER responsiveness — "byte-budget the frontend window"), and `NativeGrid.swift` / `ViewerModel.swift`.

## Problem (measured + code-confirmed)
The csv-corpus AC5 launch probe measured `wide_100k_cols` (100k columns × 3 rows, 2.5 MB) at
`first_rows_visible_ms = 3034` — 6× the 500 ms budget. The 4 normal-width reps pass. The **backend**
cold-opens the same file < 500 ms (csv-corpus AC4 passes: `ls_open` is O(head), 2.5 MB fits the 4 MiB
head). So the 3 s is entirely the **Swift frontend**, which — unlike rows — never windows columns. The
name `visibleColumns` is misleading: it means *non-hidden* columns (the column-hide feature), so with no
columns hidden it is ALL columns. Every O(total-columns) hot spot on the cold-open path:
- `ViewerModel.measureColumnWidths` (`:1068`, `for c in 0..<columnCount`) — measures every column's width
  from the head sample at open.
- Per-row `cells` / `visibleColumnWidths` / `visibleColumnLabels` / truncation arrays
  (`:446–469`, `visibleColumns.map`) — built across all columns, per row.
- `growColumnWidthsToFitWindow` (`:311–340`, `for c in visibleColumns`) — grows all columns as windows
  materialize.
- `SheetRowView.draw` (`NativeGrid:856`) + `GridHeaderView.draw` (`:970`) — iterate all column widths and
  call `.size(withAttributes:)` per cell, regardless of `dirtyRect`; ~300k text measurements for the
  first visible rows.

## Goal
Frontend cold-open first-paint and each scroll tick are **O(columns intersecting the viewport + a small
overscan)**, independent of total column count. `wide_100k_cols` first-paint < 500 ms (the frozen
csv-corpus AC5 goes GREEN, unblocking csv-corpus); horizontal scroll stays responsive; **files that fit
the viewport render byte-for-byte as today** (no regression).

## Constraints (the crux)
- **NEVER relax responsiveness** (outlier policy). This is a real bug, not an accepted outlier.
- **No behavior change for viewport-fitting files.** A file whose columns all fit on screen (the common
  case, and every existing fixture that does) must lay out, size, and paint EXACTLY as today. Existing
  macOS tests stay green unchanged.
- **Correctness preserved:** the right cell/width/label renders at the right x; horizontal scroll reveals
  the correct columns; find/filter column scoping (`visibleColumns` in the find/filter path,
  `ViewerModel:612/787/801`) is unaffected — that consumer wants non-hidden columns and keeps its meaning.
- **No `api/` change expected.** `ls_cell(row, col)` + `ls_window_set` already let the frontend fetch any
  column on demand; the backend is already O(head). If a column-RANGE fetch proves genuinely necessary for
  the budget, that is a root-planner decision to bring back — default: no api change.

## Design direction (planner works out the mechanism)
Introduce a **horizontal column window**, mirroring the row window:
- **Column x-offset prefix-sums** in the model: a cumulative-width array so any column's x is O(1) and the
  viewport x-range → `[firstCol, lastCol]` is an O(log cols) binary search. Rebuilt only when a width batch
  changes (not per draw); building it is O(cols) but happens off the per-frame path.
- **Bound measure / fetch / draw to `[firstCol, lastCol] + overscan`:**
  - **Widths — cheap, per-column, at open.** The data font is monospaced (`SheetRowView.font`), so a
    column's content width is (max display-cell count over the head sample) × advance + padding — CHEAP
    arithmetic over the head bytes, NOT 100k `.size(withAttributes:)` calls. Every column gets a real,
    independent width at open in O(head), with no O(cols) measurement pass and no default-that-pops. Growth
    is MONOTONE and driven ONLY by the vertical row window (today's `growColumnWidthsToFitWindow`, now
    bounded to in-window columns). Exotic-glyph columns (emoji/CJK/combining — where display-cell count ≠
    pixel width) get an accurate `.size` correction ONLY while visible, monotone — so an established
    column's width is stable and never re-churned by horizontal scroll. (Viewport-fitting files have all
    columns visible from the start, so they refine accurately immediately = identical widths to today.)
  - Cell fetch: build `cells`/labels/flags only for in-window columns (index the backend row by absolute
    column over the window range), not `visibleColumns.map` over all columns.
  - `SheetRowView.draw` / `GridHeaderView.draw`: use the offsets to draw only columns intersecting
    `dirtyRect`; skip the rest.
- **Total content width** = Σ measured + default × unmeasured — an ESTIMATE that refines as columns are
  measured (the horizontal analog of the row-count estimate). Keep it monotone; if a width refinement
  would strand the horizontal offset, re-anchor (the analog of the vertical re-anchor already shipped,
  `NativeGrid.syncRowCountEstimate`/`reanchorIfStrandedPastNewEnd`).

## Column-width behaviour (DECIDED with the user, 2026-07-10)
Each column's width is **its own** — a function of that column's content ALONE, never influenced by any
other column. It is established at OPEN from the head sample (cheaply — see the design direction) so it is
a real width, not a placeholder that pops. Thereafter it **grows only as VERTICAL scrolling reveals longer
content in that column** (monotone). **Horizontal scrolling never changes an already-established column's
width:** scroll out to column Z and back to column F, and F is exactly as you left it; Z's content never
affects F. This holds for files of any width; viewport-fitting files behave exactly as today.

## Acceptance criteria (testable)
1. **The gap closes:** `wide_100k_cols` cold-open `first_rows_visible_ms < 500` — the frozen csv-corpus
   AC5 (`CorpusColdOpenTests`) passes for all 5 reps. This is the headline acceptance.
2. **O(viewport), not O(total columns):** a frozen unit test asserts the count of columns measured /
   cell-fetched / laid-out for a first paint on a synthetic 100k-column model is bounded by a function of
   the viewport (+ overscan), NOT `columnCount` (e.g. ≤ a few hundred, not 100k). Deterministic, no GUI.
3. **Scroll stays responsive:** a probe asserts a horizontal scroll step on a wide doc does O(viewport)
   work (bounded latency / bounded columns touched), not O(total).
4. **No regression for viewport-fitting files:** every existing macOS test stays green unchanged; a
   viewport-fitting fixture lays out with identical widths/labels/positions as before.
5. **Correctness:** in-window cells/widths/labels/truncation/highlights render at correct x-positions;
   horizontal scroll reveals correct columns end-to-end; find/filter column scoping (non-hidden
   `visibleColumns`) unchanged.
5b. **Width stability (the decided behaviour):** an established column's width is a function of its own
   content ALONE and never changes on horizontal scroll (measure a column, scroll it out of view and back,
   assert its width is identical); widths grow only monotonically with the vertical row window; one
   column's content never affects another's width. A frozen test pins this.
6. **Gates green** (backend + macOS + root), csv-corpus AC5 included; cold-start budget held; memory O(cols)
   for the offset array only (100k floats ≈ 0.8 MB — acceptable), never O(cells).

## Contract surface (planner freezes)
Frontend-only: `apps/macos/Sources/LessSheetApp/{NativeGrid,ViewerModel}.swift` (+ possibly a new
non-frozen column-window helper). New FROZEN frontend tests under `apps/macos/Tests/` locking AC2–5
(the O(viewport) unit test, the scroll probe, a no-regression layout pin). If the design needs a new
protocol in `Sources/Contracts/`, the planner freezes it. **`api/` unchanged** (default). csv-corpus's
frozen `CorpusColdOpenTests` AC5 is the acceptance for AC1 and is NOT modified.

## Open questions
None. The column-width behaviour is decided (see "Column-width behaviour" above).
