# DIAGNOSIS — UI hang on huge-row files (window materialization scans unbounded bytes)

**Date:** 2026-07-09 · **Status:** root cause PROVEN (12 s freeze reproduced) · feeds `/aidev:feature` (huge-row budget).
**Method:** diagnose skill — feedback loop (headless jump proxy) → within-file control → pinned blocking call.

## Symptom
Open `/private/tmp/lsprobe/sparse5g.csv`, scroll to the visual end, open the jump field → **UI freezes ~12 s**.
User-observed in the assembled app; not caught by the headless review (it lives in the human-eyes bucket).

## What `sparse5g.csv` is
A pathological **"huge single row"** fixture: ~53,835 tiny 9–10-byte rows (`1,r1,tag1` …) followed by
~36 rows of ~150 MB each (the last carrying ~5.4 GB). Total ~53,836 rows / 5.4 GB. Left in `/tmp` from
earlier probing. Its tiny-head / fat-tail shape is the entire cause of both the hang and the bogus count.

## Root cause (PROVEN)
`backend/src/window.zig:83-91` — `windowSet` materializes a row window by **synchronously re-lexing the
full source bytes of every row in the window** (the checkpoint→row skip loop `lexer.recordBounds`, then
the materialize loop `lexer.lexInto`; `backend/src/lexer.zig:33,210` decode unit-by-unit to the next
terminator). The display cap bounds **stored output**, never **bytes scanned**. The window is bounded in
**rows** (a checkpoint every 2048 — `backend/src/base.zig:18`) but **never in bytes**. Near sparse5g's
true EOF the window spans the ~36 giant rows ≈ 5.4 GB → the calling thread blocks.

Reached synchronously on the **main thread**:
`NativeGrid.clipBoundsChanged` / estimate-collapse re-land (`apps/macos/.../NativeGrid.swift:481`, `:349-366`)
→ `DocumentModel.viewportChanged` / `landViewport` (`.../ViewerModel.swift:261`, `:546`)
→ `DocumentModel.materialize` `@MainActor` (`.../ViewerModel.swift:282`)
→ `CoreDocumentSession.setWindow` (`.../CoreDocumentSession.swift:101`, window-lane `NSLock`, caller thread)
→ `ls_window_set` (`backend/src/root.zig:406`, synchronous passthrough) → `window.windowSet`.

### Why "scroll to end + open jump" specifically
1. Scroll to the **estimated** end (row ~275 M) → `setWindow` is past the frontier → returns empty, cheap
   (this is why plain scroll-to-end and a past-EOF `LESSSHEET_JUMP` stay responsive).
2. The background indexer grinds the fat tail (~6–12 s); the count **collapses ~275 M → 53,836 exact**.
3. On collapse the grid clamps the clip to the new tiny content height and re-fires `viewportChanged` at
   row ~53,808 → `materialize(start≈53,208, count≈1230)` → `setWindow` must re-lex rows 53,208–53,835,
   **which includes all ~36 giant rows (~5.4 GB)** → freeze. Opening the jump field merely *coincides*
   with this window (`openJumpField` itself only flips flags + renders a cheap count string).

## Proof (within-file control — falsifiable, verified)
Release binary `apps/macos/.build/arm64-apple-macosx/release/LessSheet`, headless jump proxy (same
`materialize → setWindow` path as scroll landing):

| Command (`… <fixture>`, `LESSSHEET_DUMP_EXIT=1`) | main-thread block |
|---|---|
| `LESSSHEET_JUMP=53800` sparse5g (land on a **tiny** row) | ~1 ms |
| `LESSSHEET_JUMP=253000000,53820` sparse5g (full-index, then land **on a giant row**) | **≈11,992 ms frozen** |
| `LESSSHEET_JUMP=253000000` big2g (2.6 GB, 100 M **tiny** rows) | steady ~250 ms, no stall |

Same file, adjacent target rows: tiny = 1 ms, giant = 12,000 ms. big2g (bigger *file*, tiny *rows*) is
responsive. **The only variable is row byte size — fat rows, not file size.**

## Contract angle
`api/lesssheet.h` documents `ls_window_set` as *"O(window bytes) re-lexing from the nearest checkpoint …
the only synchronous-fast path, safe to call on the UI thread."* True only for bounded row sizes; with
~150 MB rows "O(window bytes)" = O(5.4 GB), violating PROJECT.md's *"never blocks the UI thread."* This is
the **outlier-budget** case (*"byte-budget the frontend window"*) — never applied to the window path.

## Already-existing plumbing to reuse (narrows the fix)
The display side is already built (ARCH req 13/20, gate-tested): the core byte-caps cell **output**, ships
a per-cell `RowWindow.truncated` flag (`bridgeSurfacesPerCellTruncationFlag`), and the frontend renders it
(`SheetRowView.drawTruncationMarker`). `bridgeSearchesTheFullCellPastTheDisplayCap` confirms output is
capped while full bytes remain scannable. **Missing: a bound on bytes SCANNED in the synchronous window
path.**

## Aggravator (hypothesis, strongly implied — not fully isolated)
`madvise(DONTNEED)` behind the frontier (`backend/src/index.zig:285-293`) releases the giant-row pages, so
the synchronous re-lex re-faults ~5.4 GB from disk. Predicts CPU-only ≈6 s (5.4 GB ÷ ~900 MB/s) vs observed
~12 s → roughly doubled by disk faulting. Would be falsified if the giant pages were resident and it still
took ~12 s.

## Secondary (own ticket)
The row-count **estimator** (`backend/src/index.zig:316`, `count = total_data * frontier_rows / scanned_data`)
is ~5000× high for tiny-head/fat-tail files. Harmless on its own — the frontend already presents it as
`"~N rows, estimating…"` (`OverlayView.swift:388`) and it self-corrects — but it is what places the "visual
end" 5000× too far and sets up the collapse-onto-fat-rows that triggers the freeze. NOT sufficient to fix
alone: even a correct count still lands the viewport on the fat rows if the user scrolls to the true end.

## Fix directions (for the architect/planner — not implemented here)
- **Bound bytes scanned per row in `windowSet`.** When a row's boundary isn't found within a byte budget,
  stop the synchronous scan, serve the bounded prefix + set the existing `truncated` flag, and leave rows
  after the giant one to the background frontier (the standard "ahead of frontier ⇒ not-yet-servable"
  behavior). Keeps `windowSet` O(budget), not O(row bytes).
- **Per-row "oversized / boundary-unknown" signal** across `api/` so the gutter can draw a marker
  (SF Symbol, distinct from the cell "…") with an explanatory tooltip.
- Optionally move `setWindow` materialization off the main thread as defense in depth.

### Product decisions already made (user)
- **No "load completely" affordance** — rendering a multi-GB value in a cell just reproduces the hang;
  even 10 MB of text in a cell is unusable. Marker + tooltip only ("Row exceeds the display budget —
  showing the first N").
- Display budget stays **small** (a few KB per cell is more than any column shows).
- Bound **responsiveness only** — time/memory may relax on this outlier (outlier-budget policy); slow
  background scanning with a progress indicator is acceptable, a frozen UI is not.

## Regression feedback loop (for the fix phase)
`LESSSHEET_JUMP="253000000,53820" LESSSHEET_DUMP_EXIT=1 <release-binary> /private/tmp/lsprobe/sparse5g.csv`,
compute `landed.at_ms − submit.at_ms` for `seq=1`. **Current ≈12,000 ms; pass < 100 ms.**
Control (must stay green): a near-EOF landing on `big2g.csv` stays < 100 ms.
Gap: no scroll/estimate-collapse hook, and `LESSSHEET_LANDING_STALL`'s heartbeat also freezes during a true
wedge — so submit→landed wall-clock is the reliable signal. A small non-source probe reporting the
`ls_window_set` call duration would make the pinned regression test precise (planner owns `Tests/`).
