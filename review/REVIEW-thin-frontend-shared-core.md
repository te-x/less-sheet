# REVIEW — thin-frontend-shared-core (Phase 1: match-flags)

Build cell for `docs/architecture/ARCH-thin-frontend-shared-core.md` (signed off by the author 2026-07-16).
Branch `feat/thin-frontend-shared-core`. Contract frozen at `a18903f`; contract amended (two-key) at
`9421669`. Native implementer (opus/medium) ⇄ native reviewer (opus/high) cell, run-id `tfsc-p1`,
**2 rounds to convergence**. Orchestrator ran the trusted gate independently after every round; never
accepted a role's own gate claim.

## Feature (Phase 1 of the thin-frontend refactor)
Move the platform-neutral cell-match verdict OUT of the Swift frontend and INTO the shared Zig core behind
one additive C-ABI call, so every frontend (macOS today, GTK next) reuses it instead of re-implementing.
The macOS frontend's duplicated `CellMatcher` is deleted; highlights now derive from the core.

Additive ABI (two-key ROOT amendment, `LS_BYTES_TOTAL_UNKNOWN` precedent):
`ls_str ls_window_match_flags(const ls_doc *doc, uint32_t first_col, uint32_t col_count)` — a borrowed
one-byte-per-visible-cell match mask over the current window + the active search/filter predicate (empty
when IDLE), same borrow discipline as `ls_cell`, memoized per window/query change. Design decisions
(signed): one ABI (not a second lib); per-cell type = CLIENT-CLASSIFIES (core exposes no per-cell
conformance); batched window bitmask (one byte per cell, not per-cell FFI, not packed bits); search-wrap
stays client. Phase 2 (core-framed streaming copy, `ls_copy_*`) is a SEPARATE later freeze — untouched here.

## Round 1 — implementer
Implemented `window.matchFlags` (byte-identical BY CONSTRUCTION: refactored `matcher.matchRecord` to
compose from a new `matcher.cellMatches`, so whole-row match and per-cell highlight are one code path),
the Swift `windowMatchFlags` bridge, and re-pointed the grid highlight path off `CellMatcher` onto a cached
core mask. Drafted the CHANGE-REQUEST to remove the frozen refs blocking `CellMatcher`'s deletion.
Orchestrator gate: **GATE: PASS** (backend 243 incl. `mf1`–`mf8`, macOS 163 incl. the still-present
cross-check). Perf differential (orchestrator-run, ReleaseFast, 1.07 GB warm): **no regression** — search
~0.37 GB/s and filter ~0.38 GB/s both within ~1% of the pre-refactor baseline; match-flags ~1 µs/materialize;
open→first-window unchanged.

## Round 1 — reviewer verdict: NOT PASS (2 `[impl]`) + CHANGE-REQUEST co-signed `[contract]`
The reviewer independently confirmed AC1–AC4/AC7 genuinely met and the perf NFR, then caught a real
frontend regression the implementer missed:
- **Finding 1 `[impl]`** — `MatchFlagsCacheKey` keyed on window GEOMETRY not CONTENT, and the mask was
  never reset on document re-open → a stale mask could be served over a new document's rows (open A →
  Cmd+F → open B same geometry → serves A's mask until a scroll self-heals). A regression vs the cache-free
  `CellMatcher`, and a literal AC5 ("once per materialization") violation. The implementer's *filter-toggle*
  worry was a red herring (a find request is never live while filtered); the real hole was re-open.
- **Finding 2 `[impl]`** — AC5's required one-fetch-per-materialize inert probe was absent (which is how
  finding 1 passed a green gate).
- **CHANGE-REQUEST `[contract]` co-signed**: independently validated `CellMatcher` is verdict-equivalent
  (locked by `mf1`–`mf8` + `MatchFlagsBridgeTests` goldens-from-`CellMatcher` + the cross-check) and the
  grid consumes the core path → `CellMatcher`/`CellMatching` are dead but for three frozen refs;
  `NumericGrammar` correctly retained.

## Contract amendment (two-key) — planner Mode B, committed `9421669`
Planner removed exactly the three co-signed frozen refs (the `CellMatching` protocol in
`Sources/Contracts/FindControl.swift`; the conformance pin + the `frontendMatcherVerdictsAreIdenticalToTheCore`
cross-check test in `Tests/…/FindSeekTests.swift`), re-froze macOS (2/57 entries). Orchestrator committed the
amended protected surface (transient RED until the implementer deleted `CellMatcher`).

## Round 2 — implementer
Deleted `CellMatcher` + private `Decimal10` (AC6). Fixed finding 1 with a monotonic `matchFlagsContentGen`
epoch made the first field of `MatchFlagsCacheKey`, bumped in `materialize` + `adoptSession` +
`applyFindAsFilter` + `clearFilter` (key changes on every materialization regardless of geometry). Fixed
finding 2 with the env-gated `MatchFlagsFetchProbe` (+ a `matchFlagsFetchCount` seam counting only real ABI
fetches) whose `refetch_same_geom` case fails iff finding 1 regresses. Orchestrator gate: **GATE: PASS**
(backend 243, macOS 162 = one fewer, the removed cross-check). Orchestrator-run fetch probe: all four cases
pass (`repaint_cadence`=1, `repaint_stable`=0, `refetch_same_geom`=1 [the finding-1 lock], `refetch_after_filter`=1).

## Round 2 — reviewer verdict: PASS
Both findings genuinely closed (epoch first-class in the key, no content-swap site missed, probe non-vacuous,
fetch-count counts only real fetches); AC6 complete (no dangling refs, `NumericGrammar` retained, equivalence
still gate-locked by `mf1`–`mf8` + the `CellMatcher`-free `MatchFlagsBridgeTests`); no new smells.

## Orchestrator verification
- Ran `gate.sh --require-frozen "$PWD"` after each round (never the role's claim). Both rounds green; no
  frozen drift; the amended frozen surface committed before resuming (`9421669`).
- Ran the perf differential (Round 1) and the fetch-cadence probe (Round 2) myself as the read-only
  reviewer's NFR/lock evidence.
- Confirmed tree-hash stability between the pre-review digest and the reviewer's read-only re-check
  (`00f6a9089bc3d52bd3e8d6f9b2b325c4cc94ea96d07e64fe153cf95b86d7f107`, identical).
- Native single-session cell: handoffs journaled to the session's work dir (not the role-runner relay
  ledger, which is the external-adapter mechanism) — the ORCHESTRATOR invariant that native handoffs are
  "journaled+audited, not structurally forced".

# Phase 2 — streaming copy (`ls_copy_*`)

Contract frozen at `8d8659e`; amended (two-key, DECISION-2) at `e2fb894`. Native implementer (opus) ⇄
native reviewer (opus/high) cell, run-id `tfsc-p2`, **2 rounds to convergence**. Additive ABI:
`ls_copy_open` / `ls_copy_next` / `ls_copy_close` + `ls_copy_rect`/`ls_copy_step`/`ls_copy_progress` +
`LS_COPY_MAX_CELLS` (10M cells, mirroring today's cap; byte-bounding stays caller-side per the ARCH).
Pull-model, caller-owned buffer, TSV framing byte-identical to `TSVCopyBuilder`, `STALLED` at/beyond the
frontier, no background thread.

## Round 1 — implementer
Core `ls_copy_*` frames TSV via `window.cellCopy` (byte-identical by construction — same primitive the
builder drove) reusing the O(1) forward cursor (`cp_perf` pins O(rows) advances); `CoreCopyStream`/`openCopy`
bridge with the `copyBufferLock`/`isClosed` UAF discipline; `ViewerModel` re-pointed to stream off
`openCopy` on a detached task. Orchestrator gate: **GATE: PASS** (backend `cp1`–`cp7`/`cp_perf`/`cp_abi`;
macOS 165 incl. 3 `streamingCopy*` goldens). CHANGE-REQUEST drafted.

## Round 1 — reviewer: NOT PASS (2 `[impl]`) + CHANGE-REQUEST `[contract]` with a carve-out
- **Finding 1 `[impl]`** — the filtered STALLED path passed a *view* row to `startJump` (which takes an
  *original* row under a filter) → mis-target → no frontier progress → immediate-`.done` jump → poll loop
  re-pulls with no sleep → **CPU hot-spin** (AUTO, self-heals) / **unbounded hang** (MANUAL). Regressed the
  old clean `.stoppedAtFrontier`.
- **Finding 2 `[impl]`** — the shipping streaming path was gate-unlocked for wall-clock / STALLED-resume /
  budget; the only wall-clock test still drove the *deleted* builder.
- **CHANGE-REQUEST**: co-signed removing the `CopyBuilding` protocol + the builder behavior tests, but
  **REFUSED a blanket deletion of `StreamCopyWallClockTests`** — carve-out: re-point it onto `openCopy`
  and keep the `<5 s` ceiling so the frontend perf lock survives.

## Contract amendment (two-key) — planner Mode B, committed `e2fb894`
Removed the `CopyBuilding` protocol + dead `CopyCellFetch` typealias + the conformance pin + 7 builder
behavior tests; **re-pointed `StreamCopyWallClockTests` onto `session.openCopy`** (kept, crosses the
frontier, asserts outcome + `<5 s`). RETAIN types intact.

## Round 2 — implementer
Deleted `TSVCopyBuilder` + `Decimal10`-analog helpers (completes the de-dup). Fixed finding 1 with a
`lastStalledRow` no-progress guard (recurring stalled row after a non-advancing jump → `.stoppedAtFrontier`)
+ a **sleep-first** back-off (poll can never busy-spin) + an `advanceFrontier` filter-skip. Fixed finding 2
with the env-gated `StreamCopyOutcomeProbe`. A correctness bonus: `streamCopy`/`advanceFrontier` made
`nonisolated` (the class is `@MainActor`) — R1 latently hopped the whole sweep back to the main actor; R2
keeps it off-main (AC4). Orchestrator gate: **GATE: PASS** (macOS 158 = −7 removed builder tests).

## Round 2 — reviewer: PASS
Both findings resolved (guard is filter-scoped by construction; identity resume intact per the re-pointed
1.752 s wall-clock test; `nonisolated` verified safe + fixes off-main); `TSVCopyBuilder`/`CopyBuilding`/
`CopyCellFetch` cleanly gone, RETAIN types live, equivalence still locked by `cp1`–`cp6` +
`StreamingCopyBridgeTests`. Non-blocking recommendation: hoist the now-pure `streamCopy` into `LessSheetKit`
so its outcomes gate-lock instead of probe-lock.

## Perf — before/after (HONEST; corrects the ARCH figure)
Same `StreamCopyWallClockTests`, 100k rows, debug: **before (`TSVCopyBuilder`, `0986a18`) = 2.54 s;
after (streaming) = 1.75 s → ~1.45× faster.** The ARCH's "~80 s/100k-row stall" **did NOT reproduce** — the
builder was already ~2.5 s at 100k (the `ls_cell_copy` cursor was already forward-optimized). The durable
win is the **O(rows)-advances guarantee** (`cp_perf`-locked, so the gap widens with selection size — the
per-cell-FFI path is linear in *cells*, where a large multiplier would appear at millions of cells, a regime
NOT measured here), plus streaming/cancel/off-main/frontier-handling the builder lacked, plus the
cross-frontend de-dup. The StreamCopyOutcomeProbe: all four outcomes pass (filtered `.stoppedAtFrontier` in
~52 ms — the finding-1 lock, no spin).

# Verdict (both phases)
**DONE.** Phases 1 (match-flags) + 2 (streaming copy) of thin-frontend-shared-core landed on
`feat/thin-frontend-shared-core`. The macOS frontend no longer owns the cell matcher OR the TSV copy
builder; both are core C-ABI calls (`ls_window_match_flags`, `ls_copy_*`) a future GTK frontend reuses
with zero re-implementation. Ready to merge to master.

## Outstanding / next (non-blocking)
1. **Recommendation:** hoist the pure `nonisolated streamCopy` into `LessSheetKit` so its outcome mapping +
   the finding-1 guard become gate-locked tests instead of runtime-probe-locked (reviewer's R2 note).
2. **Cosmetic doc rot:** stale `CellMatcher`/`CellMatching`/`CopyBuilding.build` mentions in the frozen
   `Sources/Contracts/{DocumentSession,FindControl,CopyBuilder,Selection}.swift`; tidy on the next contract touch.
3. Human visual pass: highlight rendering + the muted-gray selection + a copy of a large selection.
4. If the ARCH's "~80 s" matters, measure a millions-of-cells before/after (needs the deleted builder via a
   worktree + a big fixture) to validate or formally retire the figure.
