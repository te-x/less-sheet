# REVIEW — filtered-views (macOS frontend) — Round 1

**Verdict: PASS — zero blocking findings.** Two low-severity advisory `[impl]` polish notes below; neither gates acceptance.

## Gate
`bash apps/macos/.aidev/gate.sh apps/macos` → **GATE: PASS**, 65 tests (was 53 pre-existing + 12 new filtered-views). The gate's CONFORMANCE_CMD rebuilds `backend` (`zig build`) and deletes the SwiftPM link products before `swift build`, so the bridge tests linked against the CURRENT core — the stale-archive trap is defended and the implementer's own note in CoreDocumentSession.swift records that the earlier "rejection" was a stale link, not a marshaling bug. All 12 bridge/pure filtered-views tests plus the pre-existing suite pass; the native-grid stall/layout probes (landingsStall <100ms, layoutFrames pinned) still pass.

## Frozen paths
Untouched. `git diff HEAD --name-only` over `Sources/Contracts`, `Tests`, `Package.swift` is empty. No CHANGE-REQUEST. Contract mirrors (FilterControl.swift / DocumentSession.swift) unchanged; the implementation declares conformance and the frozen `filterContractConformancePins` test compiles.

## Acceptance criteria — genuinely met
- **Req 10 (apply-as-filter):** `applyFindAsFilter()` routes the SAME `FindControl.submit(...)` `.run(request)` to `session.setFilter`, not `startSearch` — no new predicate UI. Pinned by `bridgeApplyAsFilterReusesTheFindSubmitRequest`.
- **Req 11 (banner):** persistent `FilterBannerView` (does not hover-fade), "Filtered — N of M rows" with converging N + "~M" estimate + "…" while scanning, working ✕. M is captured once from the identity view before filtering (`filterDocumentRows`) and held fixed — correct, since the session's own `rowCount()` reports m while filtered. Clear is also on the Find popup (`filterRow`).
- **Req 12/find-in-filter:** running Find while filtered is plain `startSearch`, composed by the core; counts/nav read within the filtered view. Pinned by `bridgeFindComposesWithinTheActiveFilter`.
- **Req 13 (gutter):** `gutterRow(forRow:)` forwards `session.sourceRow` verbatim (not recomputed) and draws `source + 1`; not-yet-servable rows left blank, matching cells. Gutter width sized to the captured document count so it is stable across scroll.
- **Req 14 (jump):** the identity-view upfront reject and the past-target reject are both correctly gated `!isFiltered` — under a filter the jump target is an ORIGINAL row number in a different domain and the core clamps to the last match. `jumpRowCountInfo` scales the jump-box hint to the whole document. Pinned by `bridgeJumpUnderFilterTakesOriginalRowNumbers`.
- **Req 15 (clear re-anchor):** `clearFilter()` re-windows the top visible row, captures its `sourceRow` BEFORE clearing, then `landViewport(on: anchor)`. Pinned by `bridgeClearRestoresIdentityAndReanchorsOnTheTopSourceRow`.
- **Reset semantics:** setFilter/clearFilter and re-open each null out `filterSnapshot`/`filterDocumentRows` and invalidate the find app-side; the open handler resets both. Pinned by `bridgeSettingOrClearingResetsFindAndAFreshSessionHasNeither`.

## ABI wiring
- `withSearchRequest` is a clean shared helper; `startSearch` and `setFilter` both delegate to it, building an identical `ls_search_request` — no copy-paste divergence. The out-of-UInt32 guard is preserved (graceful `false`).
- `filterStatus()` maps LS_FILTER_SCANNING/DONE/CANCELLED and returns nil for LS_FILTER_IDLE (matches the contract's "nil ⇒ identity view"). Constants pinned by `filterABIConstantsArePinned`.
- **Lane choice correct:** api/lesssheet.h THREADING lists `ls_source_row` in the **Window lane** (alongside `ls_window_set`/`ls_cell`/`ls_header_cell`); `sourceRow(_:)` takes the same `lock` as `setWindow`. `ls_filter_*` are on the poll/control lane and correctly take no window lock. `LS_NO_ROW`→nil handled.

## Non-functional
Cold start / O(viewport) not harmed: the open path is unchanged except nil-initializing filter state (no scan); filter is opt-in post-open. `sourceRow` and the filtered window are non-scanning window-lane reads; re-materialize is poll-driven on the existing short-window signal (extended to keep polling while a filter-scan — including a cancelled-but-auto-resuming one — is unfinished). The gate's main-thread stall probe (<100ms) still passes. No measurable frontend regression; core perf properties are core-side and already tested.

## Structure / maintainability
Cohesive and native-idiomatic. Shared landing logic genuinely factored: `landViewport(on:)` extracted and now backs jump landing, `landSearchOn`, and filter apply/clear — verified `landSearchOn` delegates (no duplicated body). `FilterControl` is a pure value transform mirroring `FindControl`. New `FilterBannerView`/`FilterCopy` are small and single-purpose. Names accurate. No dead controls (Find-within-filter reuses existing Find; ✕ and "Clear filter" both wired). No dead code introduced.

## Advisory findings (non-blocking)
1. `[impl]` **Filter banner shows a progress bar but no numeric "%".** FilterBanner.swift `FilterCopy.summary` appends only "…" while scanning; the bar conveys the fraction visually but the sibling Find control shows textual "Scanning… NN%" (FindControls.swift:275) and both ARCH req. 11 and criterion 16 word it as "converging with a scan %", and the FilterControl.swift contract comment says progress is "shown as a %". Consider surfacing the integer percent for literal compliance and consistency with Find. Low severity — the percentage is visually present via the ProgressView.
2. `[impl]` **Empty-filter uses only the banner text, not a grid-center message.** An empty FILE renders the prominent centered `EmptyStateView` ("This file is empty."), but a zero-match filter shows only the small top-leading "Filtered — no matching rows" capsule; the grid area is blank. ARCH req. 16 says "an empty grid with 'no matching rows'". The visible "no matching rows" text requirement is met by the banner, so this is stylistic parity only. Low severity.

Both are optional polish; the feature is correct and complete against the frozen contract and acceptance criteria.
