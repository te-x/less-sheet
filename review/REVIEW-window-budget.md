# REVIEW — window-budget (backlog P0 #7 + #6)

**Final verdict: PASS** — both component cells. No residual `[impl]`/`[contract]`/`[design]` findings.
Backend cell bound tree `3e35e4a9…`; macOS cell bound tree `111f8f22…`; frozen contract `62ea031`.
`api/lesssheet.h` byte-identical (backend-only ABI). Root gate PASS (backend 163/163 + 142 corpus, macOS
110/110, api integrity).

## Cell configuration (two parallel, provably-independent cells)
- **backend** (`wb-backend`) — implementer (claude-opus-5, isolated-promotion) ⇄ external
  claude reviewer (claude-opus-5). IMPLEMENTATION_PATHS=`src`.
- **macOS** (`wb-macos`) — same runners; IMPLEMENTATION_PATHS=`Sources/{LessSheetApp,LessSheetKit,CLessSheet}`.
  Disjoint paths, independent gates, and the AC7 test is pure Kit (no backend link) → ran in parallel.
- Orchestrator ran every gate; implementer claims never taken as evidence.

## What shipped
Non-blocking window/nav work budget. `ls_window_set` now enforces a fixed **8 MiB (8,388,608-byte) aggregate
charged-work ceiling** per call (charging source-byte visits incl. filtered test+materialize double-pass and
checkpoint-skip bytes); on reaching it, it returns a **shorter contiguous `ls_row_range`** (completed rows
present, suffix pending — no new ABI, `ls_row_oversized` untouched) and retains a request-local prefix +
continuation so identical repeated calls grow the prefix monotonically (no re-scan, no livelock). #6:
`ls_search_nav`'s previously-unbounded filtered re-lex (`relexBlock`/`countInBlockUpTo` across a 2048-row
block) now returns `LS_SEARCH_NAV_SEARCHING` immediately and resolves the exact result off-main on the
existing worker (generation-guarded, supersede/cancel-safe). macOS: the poll fold reissues + wakes the
coalesced poll driver on a budget-short window (even after index-complete), resolving pending rows via the
existing loading placeholder.

## Round history
- **Backend R1** — gate green 163/163. Review → 1 `[impl]` (AC4/AC5: identity request compared `filter_gen`
  only when `filtered`, so identity→filter_set→filter_clear→identity reused stale prefix).
- **Backend R2** — `window.zig:83` now compares `filter_gen` unconditionally. Gate green; reviewer **PASS**.
- **macOS R1** — gate green 110/110. Review → 1 `[impl]` (a changed/paging row request didn't restart the
  poll driver → permanent placeholder on a budget-short scroll after the poll task had exited).
- **macOS R2** — `ViewerModel.swift:~422` revives the coalesced poll driver on a short paging window
  (idempotent, ~100 ms cadence, exits when full/EOF). Gate green; reviewer **PASS**.

## NFR evidence (release, ReleaseFast, mach_continuous_time; 5 warmups + 30 samples)
Window materialize wall-clock (every fixture >8 MiB → budget-truncated, charges exactly 8,388,608):
mmap identity (0,16) p50 4.96/max 5.58 ms · mmap skip (12,4) 8.83/9.29 · filtered non-match 11.11/11.32 ·
filtered double-pass 5.01/5.23 · gzip identity 58.58/61.33 · gzip filtered double-pass 51.87/53.63.
**All ≤100 ms, ≪500 ms;** every `windowChargedBytes` ∈ (0, 8 MiB]. #6 off-main nav (genGiantNavDoc 16 MiB×8,
134 MiB doc): `ls_search_nav` returned `SEARCHING` in 0.006 ms (navCharged=0), concurrent `ls_window_set`/
`ls_index_poll` ≤0.01 ms while the 128 MiB re-lex ran off-main (baseline cold window 3.84 ms), exact
FWD/BWD FOUND + EXHAUSTED + supersede.

## OUT-OF-SCOPE finding (logged separately — task #14)
The NFR harness incidentally found the **gzip FILTERED background scan** (`ls_filter_set` over a
near-cap-needle `.csv.gz`) is pathologically slow / non-terminating (~5 of 16 rows after ~226 s; likely O(n²)
per-row re-inflation). This is a PRE-EXISTING csv-gz + filter interaction — the window-budget synchronous
path on the same gzip fixture passed at ~52 ms, and no window-budget AC covers filter-scan throughput. Both
the reviewer and orchestrator agree it is out of window-budget scope; it is a separate high-priority csv-gz
responsiveness defect.
