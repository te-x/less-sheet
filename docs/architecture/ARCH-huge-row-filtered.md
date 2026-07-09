# ARCH — huge-row-filtered (finding-1: bound windowSetFiltered)

**Feature:** extend the huge-row-budget responsiveness guarantee to the FILTERED view path, so a
filtered view over a huge-row file can't block the UI thread. Backend-focused; may touch the frozen
`api/` only if the planner proves it necessary (default: no `api/` change — see below).

**Read first:** `review/REVIEW-huge-row-budget-1.md` (finding 1 — the gap + design direction),
`review/DIAGNOSIS-huge-row-hang-1.md`, `docs/architecture/ARCH-huge-row-budget.md` (the identity-view
fix this extends), and the frozen `api/lesssheet.h` FILTERED VIEWS + THREADING sections.

## Problem (proven, from the huge-row-budget review)
huge-row-budget bounded the IDENTITY-view window path. `windowSetFiltered` (`backend/src/window.zig`
~:161 per-candidate full-cell match TEST with `cap = null`, and ~:164 materialize) was left UNBOUNDED
— both pass `limit = d.content.len`. So a filtered view whose forward walk crosses a giant row
(matching OR not — the test lex runs for every candidate) re-lexes its full bytes synchronously on the
window/UI lane: the SAME multi-second freeze class huge-row-budget fixed for identity. The frozen
`api/lesssheet.h` FILTERED VIEWS text promises the filtered window is "O(window) re-lex … still no
scan" and "safe on the caller/UI thread … in either view" — so the contract already promises the
responsiveness the code doesn't deliver for giant rows. This closes that gap.

## Goal
`windowSetFiltered` is O(budget) like `windowSet`: a filtered view landing on / crossing giant rows
never blocks the UI thread — **without changing filter MATCHING semantics.**

## Hard constraint (the crux)
Filter matching MUST stay FULL-cell and is decided by the BACKGROUND filter-scan (`filterScanChunk`),
never by a foreground prefix. The window path must NOT re-decide a row's match by scanning it
synchronously. So the fix is not "bound the match-test lex" (that would decide matches on a prefix —
wrong); it's "don't re-test in the foreground at all — use what the background scan already computed."

## Design direction (planner works out the mechanism — this is low-level design)
- The background filter-scan already determines matches full-cell and maintains the per-block match
  counters. Locate the `materialize` matching rows via those counters (`nav.nthMatchLocation` /
  `positionOf`) rather than the current forward walk that re-tests every candidate.
- The remaining unbounded spots to bound: (a) the forward walk skipping non-matching rows to reach the
  next match, and (b) `nthMatchLocation`'s bounded in-block re-lex — BOTH re-lex row bytes and blow up
  on a giant row. Use the `oversized_checkpoints` the frontier already drops after each oversized row so
  these walks SKIP a giant row's bytes instead of re-lexing them. The planner determines what the
  background scan must record (e.g. a giant row's match result / oversized-ness) so the window path can
  honor the full-cell match without re-scanning.
- Serve a giant MATCHING row as a bounded prefix (display cap) with `ls_row_oversized` true — same as
  the identity path. Reuse `LS_WINDOW_ROW_SCAN_MAX_BYTES` (1 MiB), `oversized_checkpoints`,
  `ls_row_oversized`. Prefer NO new `api/` surface; if the scan must expose per-match oversized info
  across the ABI, that's a root-planner contract touch — flag it as a decision.
- Fold in the two non-blocking huge-row-budget review findings while here: **(2)** `drainOversized`
  dedup guard — append a staged oversized checkpoint only if its `.row` exceeds the last entry's `.row`
  (keeps `oversized_checkpoints` sorted by construction, robust against a future second mid-block-frontier
  overlap); **(3)** the "O(oversized rows)" doc-precision nit.

## Acceptance criteria (testable)
1. **Responsiveness:** a filtered-view window materialize that lands on / crosses giant rows is
   O(budget), not O(giant-row bytes) — no UI-thread block. Backend test on a synthetic fixture with a
   giant row among matches; measure the materialize is bounded (analog of the huge-row-budget probe).
2. **Matching unchanged (full-cell):** a giant row whose match content is only in its TAIL (past the
   1 MiB scan cap) still matches / doesn't-match exactly as the background full-cell scan decides —
   never decided on a prefix. Existing filtered-views `fv*` tests + a new tail-match test pass.
3. **Counts / nav unchanged:** `filter_total`, source-row mapping, jump-under-filter, find-within-filter
   all still correct (existing `fv*` tests pass).
4. **Bounded prefix:** a giant matching row in a filtered window serves ≤ `LS_CELL_MAX_BYTES` per cell,
   `ls_row_oversized` true for it, rows before it served correctly.
5. Findings 2+3 applied.
6. Gates green (backend + macOS + root); no regression to the identity-view huge-row path, cold-start,
   memory (O(checkpoints)/O(oversized rows), never O(rows)/O(matches)).

## Contract surface (planner freezes)
Expected backend-only: `backend/src/{window,nav,filter,index,base}.zig` (impl) + a new RED frozen test
in `backend/tests/` locking criterion 1/2/4. `api/lesssheet.h`: re-qualify the FILTERED VIEWS "still no
scan / safe in either view" note if needed to match reality, and add a per-match oversized signal ONLY
if the mechanism genuinely requires it (default: reuse `ls_row_oversized`, no new surface). If a new
`api/` surface is needed → that's a decision to bring back.
