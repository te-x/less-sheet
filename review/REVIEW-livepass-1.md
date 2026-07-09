# REVIEW-livepass-1 — consolidation pass over live-pass polish + fixes

Scope: `git diff ecd5bb3..HEAD -- apps/macos/` (9 commits dd28164..3f0ca4d). Frontend only.
Reviewer: independent; verified by measurement, no code edited.

## Verdict: PASS (zero blocking findings)

Two non-blocking `[impl]` structure/perf notes below for the upcoming src cleanup.

## Gate + measurement

- `bash apps/macos/.aidev/gate.sh apps/macos` → **GATE: PASS**, 65 tests, 1 suite.
- Frozen paths untouched: `git diff --name-only ecd5bb3..HEAD -- Sources/Contracts Tests Package.swift` is empty. No contract/ABI change.
- **Landing-stall budget verified by direct probe** (built `LessSheet` binary, `LESSSHEET_LANDING_STALL=800001,400001`, 3 runs) — the high-risk area (per-tick `refreshVisibleRows` + per-materialize width measurement):
  - Run 1 per-landing max_gap_ms: 17/17/17/25/22 → worst **25 ms**
  - Run 2: 17/18/17/17/20 → worst **20 ms**
  - Run 3: 17/36/17/32/32 → worst **36 ms**
  - Budget 100 ms. Margin ~3-5x, consistent. The added main-thread work did NOT erode the budget. Not "close to budget".

## Acceptance / correctness verification

1. **Filter toggle + Enter** — CORRECT.
   - `canApplyFilter` (ViewerModel:738) calls `findControl.submit` — confirmed PURE (FindLogic.swift:32-52: reads `session.draft`, returns `FindSubmit` enum, no mutation/side effect). Safe to read from `.disabled`.
   - `.disabled(!model.isFiltered && !model.canApplyFilter)` (FindControls:135) — disabled only when not filtered AND draft composes nothing; enabled to turn ON (valid draft) or OFF (filtered). Correct.
   - `filterBinding` get=`isFiltered`, set on?applyFindAsFilter():clearFilter() — correct.
   - `submitFindField` (ViewerModel:557): filtered→re-apply edited predicate, else `submitFind`. Matches commit 405334a. Composer carry-forward path untouched.
   - Banner moved into overlay control row left of Find (OverlayView:79-81), numeric `%` added (FilterBanner:28-31, rounded monospaced), centered `EmptyStateView(line:"No rows match the filter.")` on `isEmptyResult` (AppUI:297, hit-testing off). Matches ARCH criterion 18.

2. **No-fade** — COMPLETE.
   - `OverlayView` removed opacity/offset/allowsHitTesting(revealed)/animation; grep confirms no residual `.opacity(`/reveal on controls.
   - Traffic lights alpha=1 at creation (AppUI:170) and in `WindowConfigurator.updateNSView` (AppUI:451); `revealed` param dropped.
   - Own filename `Text(windowTitle)` in the title-bar band, `titleVisibility` stays `.hidden` → under-titlebar frost + header alignment preserved. hit-testing off.

3. **growColumnWidthsToFitWindow** (ViewerModel:293) — CORRECT, bounded.
   - Runs only from `materialize`, which `viewportChanged` calls only on comfort-zone exit (early-return at :275) — NOT per scroll tick. Comment is accurate.
   - Monotone (grow-only), capped at `maxColumnWidth`, measures only the visible slice (lo..hi clamped to viewport). Reassigns `columnWidths` only when a width actually grows (>0.5) → converges, no jitter.
   - Reentrancy: a growth mutates `columnWidths` → the width-change branch in `apply()` reflows+reloads but does NOT re-materialize → no loop; converges since monotone+capped. Safe.

4. **Three scroll/window fixes (high-risk)** — CORRECT.
   - (a) Width-change branch preserves clip origin: `let origin = scroll.contentView.bounds.origin` before layout, `scroll(to: origin)` + `reflectScrolledClipView` after (NativeGrid:322-327). Mirrors the estimate branch.
   - Order safety re: pending landing — VERIFIED. In `apply()` the `pendingScrollRow` landing (NativeGrid:362-365, `landOn`) runs LAST, after both origin-preservation branches and `refreshVisibleRows`. A pending jump/find landing therefore wins over the preserved origin; they do not fight.
   - (b) `refreshVisibleRows` now uses `enumerateAvailableRowViews` (whole live pool) not `rows(in: visibleRect)` — fixes off-visible-rect stale rows after a fling.
   - (c) `refreshVisibleRows` called on every `clipBoundsChanged` (NativeGrid:359 and :507 tick) — fills fling gaps within an already-covering window. Verified O(viewport) and within budget by the probe above.

## Findings (non-blocking)

1. `[impl]` (secondary, structure) — **Dead reveal/fade machinery.** `overlayRevealed` (ViewerModel:99) is now written (`revealOverlay` :868, `scheduleFade` :892, snapshot restore :933) but never READ by any view (OverlayView dropped its use; WindowConfigurator dropped the param). `revealOverlay()` is still invoked from GuessPills, OverlayView, AppUI scenePhase, and it calls `scheduleFade()`, which spawns a repeating 2s `Task` (`fadeTask`, :884-895) that toggles a value nothing observes — a small wasted timer loop with no visible effect. Also `overlayPinned` (:817) now feeds only this dead loop. Recommend removing `overlayRevealed`/`revealOverlay`/`scheduleFade`/`fadeTask`/`overlayPinned` (and callers) in the upcoming src cleanup. Not blocking (known dead machinery; behavior is correct — controls stay visible).

2. `[impl]` (secondary, perf note only) — **Per-tick allocation in the refresh path.** `refreshVisibleRows` runs on every scroll tick over the full live row pool, and each `configure` calls `model.visibleBodyCells(forRow:)` which allocates a fresh `[String]` via `visibleColumns.map` (ViewerModel:409-414). At scroll frequency this is per-row/per-column allocation churn. MEASURED not to matter today (worst landing 25/20/36 ms of 100 ms; O(viewport)). Flagging only so it stays on the radar if column/viewport counts grow materially; no action required now.

Nothing here is a `[contract]` defect: no public surface / ABI touched, and both notes are solvable in code within the contract.
