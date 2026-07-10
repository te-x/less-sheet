# REVIEW — column-windowing (final round)

Reviewer: independent; loyal to the frozen contract + `ARCH-column-windowing.md` acceptance, verified by
measurement. Adversarial. Did not edit code.

> Orchestrator note: this is the reviewer subagent's verdict verbatim. I independently re-ran
> `bash .aidev/gate.sh` (PASS, 75/75 macOS) and confirmed AC5 by measurement. Verdict is FAIL on ONE
> blocking `[impl]` finding (a gate-invisible regression in the DUMP_FRAME verification hook); routed back
> to the implementer for the one-line fix.

**Verdict: FAIL** — one blocking `[impl]` finding (a real regression the gate does not catch), plus
non-blocking notes. Everything the ACs actually cover (the LIVE grid: AC1–AC7 + AC5b) is genuinely met and
measured; the blocker is collateral damage from the `visibleColumns` memoization in a verification-only path.

## Gate (run by the reviewer, verbatim verdicts)
- `bash .aidev/gate.sh` → **EXIT 0**. Backend `GATE: PASS` (zig 0.16.0 + `zig build` + `zig build test`;
  csvgen catalog 142 passed / 0 failed). macOS `GATE: PASS` (`swift build` + `swift test`: **75 tests in 4
  suites passed**, incl. AC5 over all 5 reps, and the two round-2 AC7 tests). Root `GATE: PASS`.
- **Frozen-path integrity clean.** `git diff --name-only 2408ca1 -- api backend/contracts backend/tests
  apps/macos/Sources/Contracts apps/macos/Tests apps/macos/Package.swift` → empty; worktree diff on the
  same set → empty. Uncommitted = the 4 impl files + acknowledged sibling WIP (`profile.sh`, `build.zig`) +
  `CHANGE-REQUEST.md`.

## Cruxes attacked
- **Crux 1 (column-relative indexing) — CLEAN.** Every consumer maps `rel = c - window.firstColumn` with a
  `rel >= 0 && rel < row.count` guard (`cellsAt`/`truncatedAt` ViewerModel:584/595, `growColumnWidthsToFitWindow`
  base=firstColumn :505/523, `windowBody*`, and the draw loops). Dense path byte-identical: dense
  `setWindow` → `fetchWindow(columns: 0..<columnCount)` → `firstColumn == 0`, `cellsAt` with `base == 0`
  reduces to the old `full[c]`. AC7 proves real values at both edges. No off-by-one / absolute-into-narrow
  index found.
- **Crux 2 (h-scroll cell correctness) — CLEAN.** `clipBoundsChanged` runs `refreshColumnWindow()` (updates
  window, re-materializes/grows) BEFORE `refreshVisibleRows()` which reconfigures every live row via
  `windowBodyCells` — so cells re-pull from the fresh window every tick (rides 3f0ca4d). Body at
  `columnFirstX`, header at `columnFirstX - contentOffsetX` from the same `windowColumns()` → a drawn cell
  always sits under its header. `coversLeft`/`coversRight` comfort zone correct at boundaries + near-EOF clamp.
  `ColumnLayout.window` is a correct intersect-then-overscan scan (firstX walked back exactly `pad` cols).
- **Crux 3 (O(visible) fetch) — CONFIRMED.** Fresh open resets `columnWindow` empty → first materialize
  uses `0..<min(columnCount, 256)` → wide_100k_cols fetches 256 cols, not 100k. `measureColumnWidths` still
  iterates all columns (cheap `utf8.count`×advance) so widths exist for every column at open.
- **Crux 4 (no regression, AC4/AC5b) — CLEAN.** Viewport-fitting files (columnCount < 256) →
  `columnFetchRange` = full range, dense-equivalent, identical widths/labels/x. `grown` is a correct
  monotone, independent, per-column max-merge.
- **Crux 5 (AC5 by measurement) — RELIABLY GREEN near-idle, thin tail.** Re-ran the harness path
  (products-dir debug binary, `LESSSHEET_DUMP_EXIT=1`, parse `first_rows_visible_ms`):
  - Idle ×10: 367, 369, 387, 423, 451, 452, 458, 462, 464, 466 → **min 367 / median 451 / max 466** (all < 500).
  - Under 6-core load ×8: 396, 424, 465, 466, 469, 472, 488, 495 → **median 466 / max 495, 0/8 over budget**.
  Round-1 579 ms → ~451 ms median = the ~128 ms drop from removing the dense O(columnCount) fetch. Residual
  is the AppKit-launch + backend open/row-lex floor, NOT frontend work — thin margin is an
  environmental / AC5-test-design property (real-process launch wall-clock), not a fix defect.

## Findings
1. **`[impl]` — BLOCKING — `dumpSnapshot` renders an empty grid (broken `LESSSHEET_DUMP_FRAME`).**
   `visibleColumns` became the memoized `cachedVisibleColumns` (ViewerModel:709, init `[]`), synced only by
   `setVisibility`. But `DocumentModel.dumpSnapshot` assigns `snapshot.visibility = live.visibility`
   DIRECTLY (:1322), bypassing `setVisibility`, so the snapshot's `cachedVisibleColumns` stays `[]`
   (`@Observable`-stored, no `didSet`). Every DumpGrid helper (`visibleWidths`/`headerLabels`/
   `visibleBodyCells`/`visibleBodyTruncated`/`cellHighlights`) reads `visibleColumns` → all empty → a framed
   dump shows only gutter + filler, ZERO data columns. Genuine regression (pre-slice the computed
   `visibleColumns` reflected the direct assignment); breaks the visual-verification hook; the gate cannot
   catch it (no test references `dumpSnapshot`/`DUMP_FRAME`/`DumpGrid` — manual/visual per the no-TCC
   policy). Fix: in `dumpSnapshot` call `snapshot.setVisibility(live.visibility)` instead of the direct
   assignment.
2. **`[impl]` — non-blocking, low — wide (>256-col) framed dumps drop far columns.** Even after #1, the dump
   never establishes a `columnWindow` (no scroll view) → `columnFetchRange` caps at 256 → columns ≥ 256
   empty-pad. Invisible in a normal ~12-col clipped dump; `LESSSHEET_HIDE_COLS` could pull a far column into
   view blank. Off the perf path, not an AC.
3. **Note (not a defect) — far columns get a header-only width at open, refined on first horizontal reveal.**
   Columns ≥ 256 aren't in the open-time sample → header-label-only estimate; `growColumnWidthsToFitWindow`
   refines to content-fit when first scrolled in. NOT a visible pop (refine runs before `windowWidths()` is
   pulled for the frame; total width grows monotone so the offset never strands; AC5b out-and-back holds).
   Forced by round-2, within the ARCH's refining-estimate model. Acceptable as-is.
4. **Note — AC5 margin thin.** Median ~451 ms idle / ~466 ms under load, max 495 — reliably green in gate
   conditions, near-budget at the tail under contention. Not a defect; flag as "close to budget," don't fail
   on machine noise.
5. **Follow-up (out of this cell's scope) — backend `ls_window_set` wide-row-lex.** Each row ~830 KB lexed
   to find 100k field boundaries is a real slice of the residual and the natural next lever if the AC5
   margin needs widening. Swift-only slice cannot address it; candidate for a backend O(window) row-lex /
   boundary cache.

## Bottom line
Route back to the implementer for finding #1 only (one-line, within-contract). All ARCH acceptance for the
shipping live-grid path — AC1 (measured 451 ms median < 500), AC2/AC3/AC4/AC5/AC5b/AC6/AC7 — is genuinely
met, contract-conformant, and frozen-path-clean. Re-run `bash .aidev/gate.sh` after the fix; expect PASS.
