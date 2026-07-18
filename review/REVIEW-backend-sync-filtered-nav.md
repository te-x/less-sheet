# REVIEW — backend: synchronous filtered `ls_search_nav` (window-budget-conditional)

**Verdict: PASS (2 rounds).** Resolves the GTK Slice-4 `apps/gtk/.aidev/DECISION-1.md`
backend follow-up: `ls_search_nav` now honors its frozen ABI "synchronous after
`LS_SEARCH_DONE`" guarantee (`api/lesssheet.h:1242-1247`) under an active filter for the
normal/bounded case, while preserving the window-budget off-main carve-out for giant rows.

## Context
The GTK filter slice found `ls_search_nav` reported `SEARCHING` ~1 tick before `FOUND`
under a filter, violating the ABI. Root cause: `resolveNavLocked` blanket-deferred EVERY
filtered nav to the off-main worker (`if (doc.worker != null) return;`), even a bounded
small-row re-lex. The synchronous resolver `resolveNavLockedFiltered` existed but was
reached only in the no-worker degraded mode.

## Frozen contract (RED-first)
- **`fv16`** — synchronous filtered-nav-after-DONE for the normal/bounded case across the
  four ABI anchor kinds (forward-found / forward-skip / backward / exhausted), in FILTERED
  coordinates. Freeze `05d866d`.
- **`wb_nav_walkpast`** — the multi-block window-budget regression (Round 1 finding). A
  2049-row (two-checkpoint-block) filtered doc whose find-next walk crosses into a block-1
  ~9 MiB giant. Freeze `19beb7e`.
- The giant-row carve-out **`wb_ac11`/`wb_ac12`** (>8 MiB re-lex → off-main `SEARCHING`,
  `navChargedBytes ≤ window_budget_max_bytes`) is correct-by-design and untouched.

## Round 1 — budget-conditional dispatch
**Impl:** made the filtered-nav dispatch budget-conditional —
`if (doc.worker == null or filteredNavFitsBudget(doc)) resolveNavLockedFiltered(doc);` —
resolving inline on the calling thread when the re-lex fits the 8 MiB window budget (`fv16`
GREEN), deferring off-main only for giant crossings (`wb_ac11/12` GREEN). `filteredNavFitsBudget`
is O(checkpoints), no re-lex (checkpoint offsets + block match-counts vs `window_budget_max_bytes`).

**Reviewer:** 1 × `[impl]` — `filteredNavFitsBudget` **under-bounds**. When the anchor's own
checkpoint block holds combined (find∩filter) matches on the already-scanned side,
`findForward/BackwardMatch` walks one non-empty block FURTHER than the budgeted span; a giant
there → inline re-lex O(giant) under the doc mutex → breaches the window budget (`wb_ac11`
charged-bytes ceiling + `wb_ac12`/FR11 parse-outside-lock). Green only because every giant
fixture sits in block 0 (anchor block == answer block). Reachable via the normal find-next
pattern on >2048-row docs. → froze `wb_nav_walkpast` (RED: `navCharged ~27 MiB >> 8 MiB`).

## Round 2 — bound extension
**Impl:** extended the budgeted span to the block the walk actually lands in — forward
`hi = firstCombinedBlockFrom(lo + 1) orelse lo`; backward `lo = lastCombinedBlockTo(hi) orelse hi`;
the `filter_total_exact` tail needs no extension. Still O(checkpoints), no re-lex.

**Reviewer: PASS.** By construction the forward/backward walk lands in at most one non-empty
combined block beyond the anchor block — always ⊆ `[lo, hi]`; the change only *widens* the span
(no new under-bound possible); `fv16` still resolves inline and `wb_ac11/12` still defer via the
`orelse` collapse on single-block docs; the new over-defer is the same safe, ABI-legal
`SEARCHING`-for-a-tick class as the accepted concern-1 (off-main is always correct); normal
multi-block files (no giants) add only one ordinary ~KB block to the span → still inline.

## Gate
254/254 unit + 142/142 generator, native + both `aarch64`/`x86_64-linux-musl` ReleaseFast
cross-compiles. Scope: `backend/src/search.zig` only (no `tests/`/`api/`/`contracts/`/`build.zig`).

## Non-blocking follow-up
`api/lesssheet.h` `ls_search_nav` doc-comment (1242-1247) states "synchronous after DONE"
without spelling out the window-budget giant-row carve-out (documented in
`ARCH-window-budget.md` criterion 12 + pinned by `wb_ac11/12`). A future root-`api/` two-key
pass could add the carve-out note for precision. The frontend is correct either way (it polls).
