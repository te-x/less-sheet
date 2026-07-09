# REVIEW — backend module split + filtered-views live-pass integration (verification pass)

**Date:** 2026-07-09 · **Scope:** commit `4a392ad` (backend `root.zig` → 10-module split) plus
the assembled-system verification of the filtered-views live-pass changes `ecd5bb3..HEAD`
(9 commits `dd28164..3f0ca4d`, frontend correctness already accepted in `REVIEW-livepass-1.md`;
here re-measured end-to-end after the reorg). This is a **verification pass, not a feature** —
verified by measurement, not by claim. No code was edited (`git status` clean; only build
artifacts changed).

**Method:** two independent reviewers run concurrently. A **static analyst** (git archaeology +
normalized body-equivalence checksumming + `zig fmt --check`, no builds, no app launches) and a
**measurement agent** (owns *all* compilation + the serialized single app-instance: three gates,
release builds, headless probes on the multi-GB fixtures). The split is deliberate — the analyst
touches neither the build cache nor the app probe, so the two ran in parallel with zero contention.

---

## VERDICT: PASS — all six areas

| # | Area | Verdict | Headline evidence |
|---|------|---------|-------------------|
| 1 | Reorg correctness (`4a392ad` move-only) | **PASS** | 97 moved decls compared, 96 byte-identical, 1 behavior-neutral delta; DAG acyclic; fmt-clean; `contracts/`/`tests/`/`build.zig`/`api/` 0-diff |
| 2 | Gates (all three, run by the reviewer) | **PASS** | backend **108/108**, macOS **65**, root **PASS**; stale-.a guard fired |
| 3 | Times (cold < 500 ms, landing < 100 ms) | **PASS** | cold **198–223 ms**; landing worst **60 ms** (marked-3M) / **35 ms** (big2g) — shipped config |
| 4 | Memory / footprint (< 120 MB, O(viewport)+index) | **PASS** | phys_footprint **40 MB** workout; file-size-flat (33 MB @2.6 GB vs 35 MB @5.4 GB); fv8 holds |
| 5 | Backend↔frontend integration | **PASS** | bridge tests link+run vs fresh core; jump/find exact; filtered-views bridge tests green |
| 6 | Structure / maintainability | **PASS** | `root.zig` thin (21/23 exports are 1-line delegators); modules cohesive; no new duplication |

Six non-blocking `[impl]` findings (ranked below). **Zero `[contract]` findings** — the split
touches no `api/` C-ABI surface, and every finding is solvable in code within the frozen contract.

---

## Area 1 — Reorg correctness: PASS

The "no logic changed, only moved" claim was verified structurally, not assumed.

- **Non-src surfaces untouched.** `git diff --stat 4a392ad^ 4a392ad -- backend/contracts backend/tests
  backend/build.zig api/` is **empty**. The contract, tests, build script, and the frozen C headers
  are byte-for-byte unchanged by the commit.
- **Body equivalence — 97 moved decls compared, 1 behavior-neutral delta.** Method: extracted every
  top-level decl from `4a392ad^:root.zig` (3118 lines) and from the 11 post-split files; normalized
  both sides (strip leading/member `pub`, strip module-qualifier prefixes with identifier-boundary
  guards, drop comments/blank lines, collapse whitespace) and diffed name-by-name.
  - **96 of 97** real decls are byte-identical modulo the allowed transforms (added `pub`, qualifier
    prefixes e.g. `Document`→`base.Document`, relocated `@import` headers, doc-comment moves).
  - The **18 extracted `ls_*` helpers** (`window.windowSet`, `search.startSearch`, `filter.setFilter`,
    `index.rowCount`, …) reconstruct order-identically against the monolith bodies via `difflib` —
    zero added/removed/reordered statements. The 18 root decls that changed are *exactly* the 18
    delegators (set equality), nothing else. **No decl dropped, no definition duplicated across
    modules.**
  - **The single deviation** (Finding 1): `base.asDocMut` reorders its cast builtins. Behavior-neutral,
    but it is the sole non-move edit — recorded precisely below.
- **Dependency graph — ACYCLIC.** Edge set: `matcher→base`; `lexer→{base,encoding}`; `nav→{base,lexer,
  matcher}`; `sniff→lexer`; `filter→{base,lexer,matcher,nav}`; `search,window→{base,filter,lexer,matcher,
  nav}`; `index→{base,filter,lexer,search}`; `root→` all nine. Kahn topo-sort completes all 11 nodes,
  zero back edges: `L0 base,encoding · L1 lexer,matcher · L2 nav,sniff · L3 filter · L4 search,window
  · L5 index · L6 root`.
- **`zig fmt --check backend/src/*.zig`** → exit 0, no output. All 11 files formatting-clean.

The reorg is a faithful move-only refactor (with one canonical-cast tidy-up). Its correctness is
further proven objectively by Area 2: the untouched 108-test suite passes against the reassembled core.

## Area 2 — Gates: PASS (all three run by the reviewer)

- `bash backend/.aidev/gate.sh backend` → `GATE: PASS`. `zig build test --summary all` confirms
  **`108/108 tests passed`** (conformance pins Zig **0.16.0**). The `asDocMut` cast reorder compiles
  and passes under 0.16.0 — the analyst's one open question, now settled objectively.
- `bash apps/macos/.aidev/gate.sh apps/macos` → `GATE: PASS`, **`65 tests in 1 suite passed`**.
- `bash .aidev/gate.sh` (root) → `GATE: PASS` (api/ integrity + both component gates chained).
- **Stale-.a guard fired.** The macOS gate's `CONFORMANCE_CMD` rebuilds the backend, deletes the
  SwiftPM link products, then `swift build` — so `swift test`'s bridge tests link and run against the
  **freshly-assembled current core**, not a stale archive.

## Area 3 — Times: PASS (cold < 500 ms, landing < 100 ms)

Measured on **both** the gate/test config (Debug core) and the actually-shipped config (ReleaseFast
core, per `apps/macos/scripts/assemble-app.sh`). Shipped-config numbers are the ones that matter:

| Metric | Debug core | **ReleaseFast (shipped)** | Budget | Margin (shipped) |
|---|---|---|---|---|
| Cold start big2g (5 runs, ms) | 260/277/279/275/270 | **223/201/214/203/198** | < 500 | worst 223 → **55%** |
| Landing stall big2g (3 runs, ms) | 17/25/17 | **24/26/35** | < 100 | worst 35 → 65 ms |
| Landing stall marked-3M (3 runs, ms) | 21/32/26 | **60/54/46** | < 100 | worst 60 → **40 ms** |

- Shipped cold-start 198–223 ms reproduces the REVIEW-7 baseline band (185–236 ms).
- The **marked-3M landing** (a far-FIND landing *with* highlight re-render) is the honest worst case:
  worst 60 ms, 40 ms margin — comfortably inside budget but the tightest margin observed. Flagged as
  "within budget, tightest," not a failure.
- No STALL markers (heartbeat > 500 ms) and no timeouts in any run. Reported jump/find `max_gap_ms`
  (273/309) is dominated by the probe's *intended* 250 ms main-actor heartbeat sleep; real main-thread
  excess is only ~23–59 ms, consistent with the dedicated landing-stall probe.

The added live-pass main-thread work (per-tick `refreshVisibleRows`, per-materialize width measurement)
did **not** erode either budget after the reorg.

## Area 4 — Memory / footprint: PASS (< 120 MB, O(viewport)+index)

`phys_footprint` (the ARCH metric — NOT `ru_maxrss`/ps RSS, which counts resident mmap'd file pages):

| Scenario | Debug | **ReleaseFast** | ps RSS (mmap pages — NOT the metric) |
|---|---|---|---|
| big2g workout (jumps 80M/25M + finds) | 42 MB (peak 49) | **40 MB (peak 43)** | 2.6 GB |
| big2g open-idle | 33 MB (peak 34) | — | 2.23 GB |
| sparse5g open-idle | 35 MB (peak 39) | — | 4.99 GB |

- All **≪ 120 MB** (78–87 MB margin), and optimize-independent (Debug ≈ ReleaseFast).
- **File-size independence CONFIRMED:** big2g (2.6 GB, 100M tiny rows) 33 MB vs sparse5g (5.4 GB,
  53,836 × ~100 KB rows) 35 MB — flat (~6%) across ~2× file size *and* opposite row shapes. Meanwhile
  ps RSS scaled 2.23 → 4.99 GB with the files, which is exactly why RSS is not the metric.
- **Filter's O(index-checkpoint) memory survived the split.** Backend test **fv8** (`tests/all_tests.zig:2753`,
  part of the 108) tracks allocator bytes across a sparse (10-match) vs dense (200k-match) filter on a
  200k-row fixture and asserts `delta_dense ≤ delta_sparse + 64 KiB`. A materialized match list would add
  ≥ 1.6 MB; the counters-not-lists design holds after the module move. (The sibling find-memory assertion
  at line 1730 also holds.)

## Area 5 — Backend↔frontend integration: PASS

- **Bridge tests vs the fresh core.** The stale-.a guard (Area 2) means every bridge test linked+ran
  against the freshly-assembled current core. `FilteredViewsTests.swift` (12 `@Test`, 9 `bridge*`
  driving the real `CoreDocumentSession`) all pass — e.g. `bridgeAppliesAWhereFilterAndRemapsRowsTo
  FilteredCoordinates` opens a real fixture, applies a `.predicate` filter through the core, waits for
  the scan, and verifies `total==5` with the filtered-coordinate `sourceRow` remap `[0,1,2,4,6]`. The
  `CoreDocumentSession` bridge tests (`FindSeekTests.swift`) pass too.
- **Assembled app opens/scrolls/jumps** (release binary, headless probes):
  - Open — cold-start marker fires (Area 3).
  - Jump big2g `10000000, 999999999999, 50000000` → `9999999` exact; far past-EOF **rejected** with
    the viewport **restored** to the pre-jump top (never clamped); `49999999` exact. (Reported-total
    nuance → Finding 2.)
  - Find marked-3M `ZQZmark` → 4 exact landings `200000/1400000/2000000/2800000`, `count_final total=4`,
    `seq_complete landings=4`, on both configs.
- **App-level filter is bridge-tested, not GUI-probed.** There is no `LESSSHEET_*FILTER*` env hook, so
  the assembled-app filter path is exercised by the headless bridge `FilteredViewsTests` against the
  linked current core. GUI-driven apply/clear/banner is human-eyes (see below) — no GUI-filter
  measurement is claimed.

## Area 6 — Structure / maintainability: PASS

- **`root.zig` is genuinely thin:** 21 of 23 `export fn` are one-line delegators. The only business
  logic left is the `open` path (`openWithAllocator`/`buildShape` + validators, ~290 lines dominated by
  the ~90-field `Document` initializer) — the legitimate **composition root**, which inherently wires
  encoding+sniff+lexer+index and which `root` already imports. Defensible, not leaked logic.
- **Ten cohesive, correctly-named modules**, each with a single-responsibility `//!` header. No
  god-module (largest: root 514, search 499, index 406). No misplaced decl; no new duplication.
- **Pre-existing validation duplication is now cross-module** (Finding 3): the ~20-line request-validation
  + up-front allocation block is byte-identical in `search.zig:319–352` (`startSearch`) and
  `filter.zig:248–282` (`setFilter`) — moved verbatim from the monolith. Correctly *not* extracted by a
  move-only commit; a shared `validateAndCopyRequest` is the natural follow-up.

---

## Findings — all `[impl]`, none blocking, ranked most-severe first

1. **`[impl]` LOW–MEDIUM — Past-EOF jump's reported total is nondeterministic (scan-vs-estimate race).**
   For the absurd target `999999999999` on big2g the rejection and viewport-restore are *always* correct
   and all valid far jumps land exactly. But the reported total races: the slow path scans to true EOF
   (`exact_total=100000000 exact=true`) while faster runs reject on the byte-offset **estimate** first
   (`exact_total=103696753/105680122 exact=false`, at ~0.3–1 s) before the forward scan confirms EOF.
   PROJECT states past-frontier jumps are "served by scanning forward … never guessed from byte offsets";
   the glossary permits estimates until the index completes — so this is a consistency/feedback nuance,
   not a navigation-correctness or budget failure. (It is why the task's stated expectation
   `exact_total=100000000` only holds when the scan wins the race.) Fix: confirm-by-scan before reporting
   a total on a past-frontier reject, or mark the total estimated in the UI. `api/` not implicated.

2. **`[impl]` TRIVIAL — `asDocMut` is the one non-move edit in a move-only commit.** `base.zig:249`
   reorders cast builtins: monolith `@constCast(@ptrCast(@alignCast(doc)))` → new
   `@ptrCast(@alignCast(@constCast(doc)))`. Same result pointer, same alignment assertion on the same
   address; compiles and passes 108/108 under Zig 0.16.0. Accept as canonicalization, or revert to keep
   the refactor strictly move-only. (Called out only because the commit claims "no logic changed.")

3. **`[impl]` LOW (continuity) — Duplicated request-validation, now cross-module.** Byte-identical in
   `search.zig:319–352` and `filter.zig:248–282`. Correctly left verbatim here; recommend a follow-up
   extracting a shared `validateAndCopyRequest` into a common ancestor (`base` or `matcher` — not
   `search`, since `search→filter` already exists). Carried from REVIEW-filtered-views-backend-1 obs. 2.

4. **`[impl]` TRIVIAL (tidiness) — Over-broad `pub`.** `matcher.compareDecimal` (:180),
   `matcher.asciiLower` (:193), and `pub const Order` (:74) have no cross-module caller. The split
   exposed them wider than needed; drop `pub` on the module-internal decls.

5. **`[impl]` LOW (outlier-specific) — Uninformative progress % on huge-row files.** On sparse5g
   (53,836 rows × ~100 KB) a past-EOF jump ran an ~86 s (Debug) forward scan during which
   `jump.progress` stayed at **0%**, because progress = scanned/`known_total` and `known_total` was
   byte-estimated at ~275M vs the true 53,836. The scanning indicator *was* shown and the main thread
   stayed responsive (heartbeat excess ~49 ms, no STALL) — outlier-budget policy honored (responsiveness
   never sacrificed; only the percentage is uninformative on pathological huge-row files). Low priority.

6. **`[impl]` (frontend, pre-existing, known) — Dead reveal/fade machinery.** Confirmed unread-except-
   self-referential: `overlayRevealed` has **zero reads** (only decl `ViewerModel.swift:99` + writes
   :868/:892/:933); `fadeTask` still spawns a repeating ~2 s `Task` toggling a value nothing observes;
   `overlayPinned` (:817) feeds only that dead loop. Removal is behavior-neutral (controls are always
   visible now). Not introduced by `4a392ad` — carried from REVIEW-livepass-1 note 1. **Exact removal
   list:**
   - `ViewerModel.swift`: `overlayRevealed` (:99), `fadeTask` (:144), `overlayPinned` prop+doc (:814–821),
     `revealOverlay()` (:867–870), `scheduleFade()` (:884–895); the `revealOverlay()` call inside
     `requestJumpFocus` (:875) and `requestFindFocus` (:881) — keep the `…Requests += 1`; the
     `revealed: Bool` param of `dumpSnapshot` (:915) and its write (:933); the now-empty
     "Overlay reveal / fade" MARK (:812).
   - Callers: `model.revealOverlay()` at `OverlayView.swift:130`, `FindControls.swift:44`,
     `AppUI.swift:321` & :328, `GuessPills.swift:30` & :99 (drop any closure/`onChange` left empty).
   - `FrameDump.swift`: the `revealed: true` argument on the 5 `dumpSnapshot(...)` calls (:208/:223/:239/
     :260/:293).

---

## Note (resolved — no finding): Debug gate core vs ReleaseFast ship core

The component gates build a **Debug** core (`zig build`, correct for tests); `assemble-app.sh` ships a
**ReleaseFast** core (`zig build -Doptimize=ReleaseFast`, `.a` 337 KB vs 3.4 MB). Budgets were verified
on **both**, so there is no Debug-ships-by-accident gap. Scan throughput is ~7–10× faster on the shipped
ReleaseFast core (jump-to-10M 683 ms vs 4996 ms), which affects only the "slow-with-feedback" scan
operations, never the hard budgets. Recorded for awareness — the gate deliberately tests the Debug core
and the assembly step handles optimization.

## Human-eyes-only / not headlessly measurable (no TCC-triggering tools used)

- GUI-driven filter apply/clear, the persistent filter banner (%/estimate/empty-result message), and
  the always-visible controls/traffic-lights/filename — hand to the author.
- Live Liquid-Glass frost, wheel/trackpad 60 Hz scroll feel, VoiceOver — human-eyes.

## Measurement provenance

- **Fixtures:** `/private/tmp/lsprobe/big2g.csv` (2.6 GB, exact_total 100,000,000),
  `/private/tmp/lsprobe/sparse5g.csv` (5.4 GB, exact_total 53,836), `$TMPDIR/lesssheet-native-grid-
  fixture-v1.csv` (3M marked, regenerated by the macOS gate's probe tests). `bigmark.csv` present, unused.
- **Builds:** backend Debug (`zig build`, .a 3.4 MB) and ReleaseFast (`-Doptimize=ReleaseFast`, .a
  337 KB); app `swift build -c release` with release link products purged first (stale-.a discipline).
  Binary: `apps/macos/.build/arm64-apple-macosx/release/LessSheet`. Machine: Apple Silicon arm64,
  Zig 0.16.0. Single-machine numbers = order-of-magnitude evidence, all far from the boundary.
- **Probes:** `first_rows_visible_ms` (cold), `LESSSHEET_LANDING_STALL` → `landing.worst_max_gap_ms`,
  `LESSSHEET_JUMP`, `LESSSHEET_FIND`+`FIND_STEP_SEQ`; `footprint -p`/`vmmap --summary` for phys_footprint.
