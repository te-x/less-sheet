# REVIEW — huge-row-budget (round 1)

Reviewer: independent; loyalty to the frozen contract (`api/lesssheet.h` huge-row-budget surface) +
ARCH-huge-row-budget acceptance criteria; verified by measurement. Did not edit code.

## Overall verdict: PASS

All 8 ARCH acceptance criteria are genuinely met and verified by measurement. Three gates green, no
frozen path touched, and the highest-risk logic (the separate `oversized_checkpoints` array) is correct
for every reachable state — proven by analysis and confirmed by brute force. Findings below are
NON-BLOCKING (one is a pre-existing, out-of-scope responsiveness residual worth a follow-up ticket; the
rest are hardening/doc notes).

## Gate results (verbatim + counts)
- `bash backend/.aidev/gate.sh backend` → `GATE: PASS`; `zig build test` = **113/113** (incl. frozen
  `hr3-served`, `hr4-reach`, `hr5-count`, `hr6-fullcell`, and the `LS_WINDOW_ROW_SCAN_MAX_BYTES` /
  `ls_row_oversized` ABI pin).
- `bash apps/macos/.aidev/gate.sh apps/macos` → `GATE: PASS`; **67 tests** pass, incl.
  `bridgeSurfacesOversizedRowFlag`, `bridgeSearchesTheFullCellPastTheDisplayCap`,
  `landingsStallTheMainThreadLessThan100ms`.
- `bash .aidev/gate.sh` → `GATE: PASS` (api/ integrity + both chained).
- Frozen-path check (`git diff --name-only 4bb245a -- api backend/contracts backend/tests
  apps/macos/Sources/Contracts apps/macos/Tests apps/macos/Package.swift`) → **empty**. Only
  `backend/src/{base,filter,index,root,search,window}.zig` and
  `apps/macos/Sources/LessSheetApp/{ViewerModel,NativeGrid}.swift` changed.

## Measured repro (self-rebuilt ReleaseFast backend + purged/rebuilt Swift release), `seq=1` Δ
- **Primary (sparse5g giant-row landing, ARCH 1):** submit `at_ms=8311` → landed `at_ms=8315` →
  **Δ = 4 ms** (baseline ~12,000 ms). Preceding full-index phase never gapped the main-thread heartbeat
  beyond `max_gap_ms=302` (background frontier work, off-thread, as designed) — no wedge.
- **Control (big2g near-EOF, tiny rows, ARCH 2):** submit `at_ms=7978` → landed `at_ms=7980` → **Δ = 2 ms**.
- **Cold-start (ARCH 2):** `first_rows_visible_ms = 246` (sparse5g) / `247` (big2g), both < 500 ms.

## Item 4 — checkpoint separation is CORRECT (highest-risk area)
**(a) `nav.zig` block-direct-indexing uncorrupted.** Every writer of `checkpoints` is block-aligned
(`index.zig:57` `row % interval == 0`; `res.checkpoint`-guarded appends at `search.zig:169` /
`index.zig:231` / `filter.zig:151` set only at `row==target`; the `{row:0,offset:data_start}` seed at
`root.zig:244`). `oversized_checkpoints` is written only by `drainOversized`, read only by
`bestCheckpoint`. `nav.zig` indexes `doc.checkpoints[b]` exclusively and never touches
`oversized_checkpoints`. No oversized entry can leak into the block-indexed array.

**(b) `checkpointAtOrBefore`/`bestCheckpoint` safe.** Proven (and confirmed with 2,000,000 adversarial
random trials) that the binary search never returns an entry with `.row > query`, even on unsorted
input — so the skip loops can never receive a checkpoint beyond the target; wrong-row corruption is
impossible. `bestCheckpoint` correctly maxes the regular checkpoint with the closest oversized one.

**(c) The `advancing`-gated drain cannot produce a harmful out-of-order list.** A search/filter scan runs
from row 0 with its own cursor; `advancing = res.end_offset > frontier_offset` (same gate as the sibling
`checkpoints` append). The only chunk that can overlap already-drained rows is the single block that
straddles the frontier when a scan catches up to a **mid-block** frontier — and the frontier is left
mid-block only by `headScan` at open (`stop`/`stop_atomic` are set only in `ls_close`, `root.zig:364-365`;
reaching EOF sets `complete`, after which nothing is `advancing`). So **at most ONE overlap run** can ever
be appended. Brute-forced this exact reachable single-overlap structure: **0 misses / 0 re-scans / 0
corruption** across 500k + 1M random configs, for BOTH the oversized-recovery loop (`window.zig:122-130`)
and the top skip-from-checkpoint loop (`window.zig:94-98`). A hypothetical *two*-overlap list DOES break
the search (307k anomalies) — so correctness rests on the "one mid-block frontier" invariant (holds today;
see finding 2).

Item 3 (crux) confirmed: `row_limit = @min(off +| scan_cap, content.len)` bounds bytes *scanned* (both
`lexInto` and `recordBounds` stop decoding at `limit`), `res.capped` drives `win_oversized`, and the
window's `res.capped` and the frontier's `stageOversized` extent test agree on oversized-ness for every
row (incl. near-EOF), so the post-oversized checkpoint always exists when the window flags a row.

## Item 6 — filtered-view residual (confirmed by code; follow-up)
`windowSetFiltered` was left untouched and still scans unbounded: `window.zig:161` (per-candidate match
test) and `:164` (materialize) both pass `limit = d.content.len`. A filtered window whose stride crosses a
giant row (matching or not — the test lex runs for every candidate) re-lexes its full bytes synchronously
on the window/UI lane — the SAME hang class the identity path just fixed. Pre-existing (unchanged by this
diff) and outside the ARCH's stated scope (identity-view; the reported bug and all 8 criteria are
identity-view). BUT not a contract-sanctioned limitation: `api/lesssheet.h` FILTERED VIEWS says the
filtered window is "O(window) re-lex ... still no scan" and "safe on the caller/UI thread ... in either
view" — so the contract promises filtered responsiveness the implementation doesn't deliver for giant
rows. See finding 1. (Not measurable through the app harness — no `LESSSHEET_FILTER` driver, itself a
small headless-coverage gap; the code is unambiguous.)

## Findings (most-severe first — all NON-BLOCKING for round 1)
1. **`[impl]` — Filtered-view huge-row responsiveness residual (follow-up).** Byte-bound
   `windowSetFiltered`'s test/materialize lex to the per-row cap and reuse the oversized checkpoints to
   skip giant rows, serving a giant matching filtered row as an oversized prefix (or deferring it). A
   clean fix must reconcile with full-cell filter matching — the giant row's match status comes from the
   background filter-scan's per-block counters, so the window path must not re-decide it by scanning.
   Planner should schedule this as a follow-up slice (or add a contract note qualifying the filtered path
   — planner's call). Does NOT block this feature (ARCH scope + all criteria are identity-view, all pass).
2. **`[impl]` — `oversized_checkpoints` ordering correct-but-fragile (cheap hardening).** The
   row-ascending invariant holds only because the frontier is mid-block at exactly one point
   (post-`headScan`). A future change that commits a partial non-complete frontier advance a second time
   would allow a second overlap run and let `checkpointAtOrBefore` miss a post-oversized checkpoint → a
   transient giant-row re-scan. Cheap robust fix: in `drainOversized`, append a staged entry only if its
   `.row` exceeds the last entry's `.row` — keeps the list sorted by construction, O(1)/drain, provably
   safe. Recommend the guard + a comment naming the "at most one mid-block frontier" invariant.
3. **`[impl]` — Doc-precision nit.** The `oversized_checkpoints` "O(oversized rows), never O(rows)"
   comment understates by one straddling block's re-drained entries (the single `headScan` overlap).
   Negligible; the finding-2 dedup guard also makes the bound exact.

## Non-blocking notes
- Behavior preserved (item 5): `hr5` (oversized row counts as one; `bytes_scanned==bytes_total`,
  complete) and `hr6` (search AND filter still match the full cell past the cap — the `cap=null` paths
  untouched) pass. Cold-start/steady memory not regressed (`win_oversized` = one bool per windowed row;
  `oversized_checkpoints` = O(oversized rows)).
- Frontend: gutter marker (`exclamationmark.circle`, `systemOrange`, distinct tooltip, distinct from the
  per-cell "…") wired end-to-end (`CoreDocumentSession.swift:118` → `RowWindow.oversized` →
  `DocumentModel.rowOversized` → `GridGutterView`). Live visual is human-eyes; headless verifies flag
  surfacing (`bridgeSurfacesOversizedRowFlag`). The unconditional `oversizedMarkerReserve` gutter width
  avoids scroll-triggered geometry changes — consistent with the recent column-width-growth fixes.
- Zig 0.16.0 idioms current (unmanaged `ArrayList` + per-call allocator; `+|` saturating add); gate pins
  0.16.0.
