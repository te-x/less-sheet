# REVIEW — search case-sensitivity toggle (Match case)

**Verdict: PASS (all 4 components).** Cross-component feature merged to master (ff, `c3f72c6`) on branch
`feat/search-case-mode`. the author's design: replace smart-case with an explicit **"Match case" toggle** —
OFF (default) = ASCII case-INSENSITIVE for text substring AND predicate `=`/`≠`; ON = byte-exact. Ordering
predicates numeric/unaffected. Session-only ([[session-only-document-state]]). No back-compat — v1,
lock-step rebuild, no external ABI consumers ([[no-backcompat-v1]]); smart-case DELETED, not preserved.

## Components (each: planner freeze RED → implementer green → reviewer PASS; orchestrator ran the trusted gate)
- **api/ (root, `95bce88`):** `ls_search_request` grew `bool case_sensitive` (false/zero-init = insensitive);
  smart-case docs deleted + rewritten; the "byte-identical layout" claims in the later extension blocks
  carved out (the struct grew above them). Root frozen.
- **backend (`c7bc7e3`):** `fold = !case_sensitive` computed once at startSearch/setFilter for all kinds
  (was the TEXT-only query-derived smart-case); `queryFolds` deleted; predicate EQ/NE folds ASCII on BOTH
  match paths — `cellMatches` (nav/mask) + `StreamCell.feed` (scan/count/filter) — reviewer traced them
  equivalent (cross-surface fc8). Zig `api.SearchRequest` mirror grown. 142 tests.
- **GTK (`1006830`):** `LsgFindDraft.case_sensitive` → request → ABI at the single `lsg_build_abi_request`
  choke point; `lsg_find_query_case_sensitive` deleted; "Match case" GtkCheckButton by "Filter to matches",
  live re-issue. 12 g_tests.
- **macOS (`c3f72c6`):** `FindDraft.caseSensitive` → `SearchRequest` (Equatable identity → toggle re-issues)
  → ABI at `withSearchRequest`; "Match case" checkbox in FindControls; `setCaseSensitive` live re-issue with
  a genuine never-submitted-query guard. **AC23 `AmendmentContractGuardTests` baseline re-bumped** to the
  authorized header SHA (`df0436b6…`). 166 tests.

## Durable notes
- **api/ amendment gotcha (recurring):** the macOS `AmendmentContractGuardTests` (AC23) pins a SHA-256 of
  `api/lesssheet.h`. ANY authorized `api/` change must re-bump that baseline (frozen `Tests/` = planner
  authority) — the macOS planner missed it here and the gate caught the stale baseline; re-bumped as a
  follow-up. Future api/ freezes: re-bump AC23 in the same pass.
- The change flips two long-standing defaults (text smart-case → insensitive; predicate EQ/NE byte-exact →
  insensitive), all pinned tests re-pinned/flipped accordingly across backend + both frontends.

## Root gate note (NOT a regression)
The full root gate reported 1 macOS failure: `launchColdOpenIsUnderBudget[wide_100k_cols]` = 515ms vs the
500ms budget. This is the DOCUMENTED cold-open flake under the root gate's concurrent CPU load — the
standalone `--require-frozen apps/macos` passed 166/166 at `c3f72c6` (this test <500ms unloaded), and
case-mode does not touch the cold-open path. Per [[outlier-budget-policy]] the 500ms budget stays strict;
the load-induced breach is CPU-starvation, not a real regression (real cold-open ~444ms median).

## Human GUI pass (the author)
The "Match case" checkbox visuals + interaction are the human pass — GTK (`run_gtk_on`) + macOS (reinstall):
toggle OFF → `= isabella` matches `Isabella`; toggle ON → byte-exact; a text search `USA` folds onto `usa`
when OFF; the toggle re-issues find + re-applies an active filter live.
