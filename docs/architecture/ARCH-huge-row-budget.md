# ARCH — huge-row-budget

**Feature:** bound the synchronous byte scan in window materialization so huge rows/cells can never
block the UI thread. **Type:** responsiveness fix on the window/serve path; touches the shared `api/`
contract (root planner) + `backend/` + `apps/macos/`.

**Inputs to read:** `review/DIAGNOSIS-huge-row-hang-1.md` (proven root cause, repro, control),
`docs/architecture/PROJECT.md` (hard constraints; outlier-budget policy), `api/lesssheet.h`
(WINDOW lane, `ls_cell_truncated`, `record1_capped` requirement 9).

## Problem (proven)
`windowSet` (`backend/src/window.zig:83-91`) materializes a window by synchronously re-lexing the
**full source bytes** of every row from the nearest checkpoint, on the caller (UI) thread. The window is
bounded in **rows** (checkpoint every 2048) but not in **bytes**. On a file with huge rows (`sparse5g`:
~53,835 tiny rows + ~36 rows of ~150 MB), landing the viewport near EOF re-lexes ~5.4 GB synchronously →
**~12 s UI freeze** (proven: landing row 53,820 = ~12,000 ms vs the adjacent tiny row 53,800 = ~1 ms;
`big2g` — bigger file, tiny rows — stays responsive). Violates PROJECT "never blocks the UI thread."

## What already exists (this feature extends it, not greenfield)
- **Per-cell display cap** on stored OUTPUT (`LS_CELL_MAX_BYTES`) + per-cell `ls_cell_truncated` /
  `CellRef.truncated`, rendered by `SheetRowView.drawTruncationMarker`. Gate-tested.
- **Bounded record 1** (api requirement 9): when the *first* record doesn't terminate within the head
  budget, the core serves a bounded prefix (`row0_pinned_refs`) and sets `record1_capped`; the frontier
  won't claim a row whose extent past the budget is unknown. This is the byte-bounding pattern — wired
  only for row 0 at open. This feature generalizes the *display-bounding* to any row.

## Goal
Materializing any window is O(budget), never O(row bytes): the UI never blocks on a huge row. A row whose
source extent exceeds the per-row scan cap is served as a bounded prefix, its visible cells display-capped
as today, and a NEW per-row "oversized" flag is set so the gutter marks it. Finding the true end of a huge
row (to reach later rows / count) stays the **background frontier's** job — already off-thread and
UI-responsive (the diagnosis confirmed the past-EOF background scan on `sparse5g` did not block the UI).

## Non-goals (explicit)
- **No "load completely" / expand affordance.** Rendering a multi-GB value reproduces the hang; even
  10 MB of text in a cell is unusable. Marker + tooltip only.
- **No row-count estimator change** (deferred to a separate ticket). Once the window is byte-bounded the
  ~5000×-high estimate on fat-tail files is harmless: already shown as "~N rows, estimating…"
  (`OverlayView.swift:388`) and self-corrects to exact once scanned.
- **Not making huge-row display fast** — only non-blocking (outlier-budget: relax time/memory on
  pathological input, never responsiveness).
- **No change to search/filter cell semantics** — those match the FULL cell (`cap = null`, `nav.zig:52`
  / `filter.zig:83`); only the WINDOW display path is byte-bounded.

## Design decisions (settled with the user)
1. **Per-row scan cap** `LS_WINDOW_ROW_SCAN_MAX_BYTES ≈ 1 MiB` (source bytes scanned per row in the
   synchronous window path). A row lexed up to the cap without reaching its terminator is served as its
   bounded prefix and flagged oversized. This is distinct from `LS_CELL_MAX_BYTES` (the per-cell OUTPUT
   display cap, much smaller — both apply: cells within the scanned prefix are still individually
   display-capped). Reuses the existing `Bounds.capped` mechanism (`lexer.zig:13`, already used for the
   head budget).
2. **Frontier drops a checkpoint immediately after each oversized row** (it already scans every row's full
   bytes in the background to find the end — it now also marks oversized rows and adds a checkpoint after
   them). This is what lets `windowSet`'s skip-from-checkpoint loop reach a row *after* a giant row WITHOUT
   re-scanning the giant row's bytes — the key to O(budget) regardless of viewport position.
3. **New per-row `oversized` signal** across `api/` (window/borrow domain, like `ls_source_row`): set when
   the row's source extent exceeded `LS_WINDOW_ROW_SCAN_MAX_BYTES`. Semantically "served cells are a
   bounded prefix; more source exists; the row's true end may lie past this window." Distinct from the
   per-cell display-cap truncation. Drives the gutter marker.
4. **macOS gutter marker** for oversized rows: a native SF Symbol (proposed `exclamationmark.circle`)
   before the row number, visually distinct from the ordinary cell "…" (which means "column too narrow"),
   with a tooltip: *"Row exceeds the display budget — showing the first ~1 MB. Full content isn't loaded."*
5. **`ls_window_set` doc re-qualified** in `api/lesssheet.h`: cost is O(min(row bytes, scan cap) × rows),
   safe on the UI thread for any row size (was "O(window bytes)", true only for bounded rows).

## Known limitation (accepted; documented, not a bug)
The per-row cap bounds each row, not the window aggregate: a viewport spanning many (hundreds of) ~1 MB
rows could still scan hundreds of MB synchronously — a rarer, softer form of the hang. `sparse5g` is
unaffected (its ~36 giant rows cost ~36 MB ≈ ~36 ms). **Optional future tightening** (planner's discretion,
one extra counter): a per-window aggregate scan ceiling — stop materializing further rows once cumulative
scanned bytes exceed a ceiling; the remainder are not-yet-servable and fill via scroll. Deferred unless
the planner elects to include it.

## Acceptance criteria (testable; no open questions)
1. **Primary (the hang):** `LESSSHEET_JUMP="253000000,53820" LESSSHEET_DUMP_EXIT=1 <release-binary>
   /private/tmp/lsprobe/sparse5g.csv` → `landed.at_ms − submit.at_ms` for `seq=1` is **< 100 ms**
   (baseline ~12,000 ms).
2. **No regression on tiny rows:** the equivalent near-EOF landing on `big2g.csv` stays **< 100 ms**;
   cold-start (< 500 ms) and landing-stall (< 100 ms) budgets unchanged; steady phys_footprint unchanged
   (O(viewport); the cap only reduces work).
3. **Oversized row served as bounded prefix:** for a row whose source bytes exceed
   `LS_WINDOW_ROW_SCAN_MAX_BYTES`, `ls_cell` serves ≤ `LS_CELL_MAX_BYTES` per visible cell (unchanged),
   the row's new oversized flag is TRUE, and all rows *before* it in the window are served in full.
4. **No re-scan across a giant row:** `windowSet` reaching a row positioned after an oversized row does
   not re-scan the oversized row's bytes (uses the checkpoint dropped after it). Rows after an oversized
   row are served when behind the frontier, else not-yet-servable (blank, fill in on the existing
   short-window poll) — no permanent gap.
5. **Counting/navigation intact:** each oversized row counts as exactly one row; the frontier's row count
   and the estimate→exact collapse are unchanged; jump/find landings remain exact.
6. **Full-cell match semantics intact:** search and filter still evaluate the FULL cell (not the scan
   cap) — an existing test like `bridgeSearchesTheFullCellPastTheDisplayCap` still passes; a search can
   still match content past the window scan cap.
7. **Frontend marker:** an oversized row shows the distinct gutter marker + tooltip; normal rows show
   none; the marker is distinct from the cell "…". (Headless: the per-row oversized flag surfaces through
   the macOS bridge — a `bridge…OversizedRow…` test; the live visual is a human-eyes check.)
8. **Gates green:** `bash backend/.aidev/gate.sh backend`, `bash apps/macos/.aidev/gate.sh apps/macos`
   (still 65 + the new bridge test), `bash .aidev/gate.sh` (root) all PASS.

## Contract surface (root planner freezes)
- `api/lesssheet.h`: new constant `LS_WINDOW_ROW_SCAN_MAX_BYTES`; new per-row accessor
  `ls_row_oversized(doc, row) -> bool` (or an equivalent flag in the window metadata — planner picks the
  exact shape), window/borrow domain identical to `ls_source_row`; re-qualified `ls_window_set` cost doc.
- `backend/`: `window.zig` (bound the skip + materialize loops to the cap; set oversized; use the
  post-oversized checkpoints), `index.zig` (detect oversized rows during the frontier scan; persist the
  per-row flag; drop a checkpoint after each), `base.zig` (per-row oversized storage in the window,
  parallel to `win_source`).
- `apps/macos/`: `CoreDocumentSession` bridge for the new accessor; `RowWindow` per-row oversized field;
  `NativeGrid` gutter marker + tooltip.

## Regression loop for the build phase
The `sparse5g` jump proxy above is the signal (`materialize → setWindow` is the same path as scroll
landing). NOTE: `LESSSHEET_LANDING_STALL`'s heartbeat also freezes during a true wedge, so `submit→landed`
wall-clock is the reliable measure; a small probe reporting the `ls_window_set` call duration directly
would sharpen the pinned regression test (the planner owns `Tests/`).
