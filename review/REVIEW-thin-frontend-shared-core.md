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

## Verdict
**DONE.** Phase 1 of thin-frontend-shared-core landed on `feat/thin-frontend-shared-core`. The macOS
frontend no longer owns a cell matcher; a future GTK frontend gets highlight verdicts from
`ls_window_match_flags` with zero re-implementation.

## Outstanding / next
1. **Phase 2 — core-framed streaming copy** (`ls_copy_open/next/close`): the separate later freeze; fixes
   the ~80 s/100k-row copy stall + de-dups TSV framing. This is where the big perf win lives; a full
   before/after belongs there ([[perf-before-after-tracking]]).
2. **Cosmetic (non-blocking):** a few stale `CellMatcher`/`CellMatching` doc-comment mentions linger in the
   planner-owned frozen `Sources/Contracts/{DocumentSession,FindControl}.swift`; tidy on the next
   contract touch (not worth a freeze of its own).
3. Human visual pass on the highlight rendering after this + the pending selection-color change.
