# REVIEW — sort-by-column

Feature: sort the document view by one column, ascending or descending, session-only, with a converging
sorted prefix served while the key pass runs (design: `docs/architecture/ARCH-sort-by-column.md`, base +
Amendment 1 "latency over throughput" + Amendment 2 (memory bound wording) + Amendment 3 (sort triggers:
keyboard shortcut and header context menu), all signed by the author on 2026-09-06). Contract frozen in
`798a893`, amended in `fb84d32`, `b12d51a` and `4da0753`; harness fix `45e0289` (the write guard honors
nested component profiles) preceded the build. Final verdict: **all three cells PASS** — backend `cd28b40`
+ `a2d286b` + `68b29ed`, GTK `f456f6b`, macOS `8ea2b13`. This record was written per converged cell.

## Backend cell — `build-sort-by-column-backend` — **PASS (round 3; reopened and PASSED again in rounds 4 and 5)**

Roles: implementer + reviewer (native runner, the configured models), orchestrator as switchboard; every
handoff relayed by reference and journaled (`verify-relay`: PASS, 13 ledgered turns, byte-exact). The
trusted backend gate was run by the orchestrator on every round's tree: 330/330 natively and 330/330 in the
`fedora:43` container, three ReleaseSafe builds, `zig fmt` clean, zero warnings. Only `backend/src/**`
changed (11 files, +2970/−101); `api/`, contracts, tests, build files and the other components are
byte-identical to the freeze. Reviewed tree: workspace digest `9b88c202…`, backend `aabeda5f…`.

### Rounds
- **Round 1** — implementer delivered the feature (key encoding + exact comparator grounded in the
  column-inference grammar, chunk/run/merge engine, top-K prefix, on-disk permutation + inverse mapping,
  the single `tempdir.resolve()` now also used by the gzip spill and net spool) and found two perf defects
  itself (linear k-way merge → heap, 233 s → 88 s; offset-chasing chunk sort → fixed-width prefix keys,
  88 s → 64.5 s) plus a merge that held the document mutex for its whole 6 s. Reviewer: 7 `[impl]`
  findings — a use-after-free on the last-chunk OOM path (unreachable by the frozen injected-failure test
  because `allocOk` was consulted in the wrong place), find-under-sort implemented as a synchronous
  double re-lex under the mutex instead of FR7's sorted-position counters, BOOLEAN keys read the untrimmed
  cell, two accessors allocated under a sort, two knob literals bypassing the resolver, a net document
  with no worker could download the whole resource under the mutex, stale `ls_window_match_flags` after a
  prefix refinement. Both of the implementer's deliberate §8 deviations were ACCEPTED (a BUILDING pass
  outranks a jump in the worker; no PARKED report under LS_INDEX_AUTO on a local document) and left for the
  planner to reconcile in the header prose.
- **Round 2** — all seven fixed; find-under-sort reimplemented as FR7 (match-scan tallies per sorted block
  via the inverse mapping, navigation examines one block off-lock on the worker, cached per block).
  Reviewer: 2 small `[impl]` findings in the new tally staging (a dropped staged match silently shortened
  the counters; a shared bool read off-lock).
- **Round 3** — both closed (complete-or-nothing tally with a contiguity proof; the flag snapshotted under
  the mutex and passed as a parameter, which also caught a test seam an atomic would have missed).
  Implementer proved the fallback path by temporary injection against an oracle, then reverted it
  (verified byte-identical). Reviewer: PASS.

### Measurements (orchestrator-run, ReleaseSafe, native builds of the reviewed trees, idle machine; fixture
`c10-10GB.csv`, 135,178,871 rows, and its `.csv.gz`)
| criterion | bound | measured |
|---|---|---|
| AC-s10a key pass vs same-session full-file search scan | ≤ 3× | 61.8 s vs 30.0 s = 2.06× (decimal), 62.9 s = 2.09× (text); round 2: 2.01× |
| AC-s16(b) first sorted window after `ls_sort_set` | ≤ 100 ms | 6.4 ms (decimal), 7.3 ms (text), 21.8 ms (gzip) |
| AC-s9 scratch disk, text column | ≤ 48 B/row peak, ≤ 16 retained | 36.0 B/row peak (run 20 + perm 8 + inv 8), exactly 16.0 retained, 0 files after close |
| AC-s10b gzip sorted scroll (report only) | — | 1,753 ms cold / 1,749 ms warm per 50-row window |
| plain sorted scroll | — | 9–17 ms per 50-row window, 0 re-issues |
| AC-s5 find-under-sort navigation | responsive | call returns 0.0 ms; resolves 367 ms first hop, then 1.3 ms (round 1: 50.1 s blocking); answers byte-identical across both implementations |
| AC-s8 open + first window | unchanged | 58 ms before and after (implementer's interleaved runs) |
| boolean whitespace discriminator (M5) | `1 0` | `0 1` in round 1 → `1 0` in rounds 2–3 |
| hostile corpus × type override (M6) | no crash | 56 cases × ≤ 4 columns × 6 override kinds = 1050 combinations, 0 non-zero exits, all terminal ACTIVE |

### Durable notes
- **ARCH §4 build-time RSS is imprecise, not violated.** `ru_maxrss` over the control scan grows by
  0.73–1.26 GB and scales with rows, because the two temp mappings' file-backed, evictable pages count as
  resident; the core's anonymous residency stays inside 2× the chunk knob + O(K) and is row-independent
  (`srt_memory_bound`). The planner should add one clause excluding mapped temp storage from that sentence.
- **§8 slot prose to reconcile (planner):** a BUILDING pass outranks a jump in the worker; under
  LS_INDEX_AUTO on a local document a jump does not report PARKED (the pass never yields).
- **The gate's last step leaves an x86_64 ELF `liblesssheet.a` in `backend/zig-out`.** Rebuild natively before
  linking any probe or bench against it (the stale-archive hazard, again).
- **"A clean library build is not evidence of a clean gate":** a Zig-only test seam in `root.zig` compiles
  only under the test step; the implementer's round-3 edit broke it and only the full gate caught it.
- **For the frontend cells:** a wide, short document (2000 columns × 626 rows) converges over ~290 window
  re-issues per cold sorted window (571 ms cold, 19 ms warm) — a repaint-loop hazard the UI must absorb.
  Gzip sorted scrolling costs ~1.75 s per 50-row window (accepted ship-and-measure); the UI must show the
  loading state.
- **Pending (not against this cell):** the `tools/fuzz` sort entry (AC-s13's campaign half) is the
  planner's, per the author's decision; it must iterate type overrides per column or it only re-walks the
  text path.

### Round 4 — reopened by the fuzzer, closed the same day
After the round-3 PASS and the `cd28b40` commit, the planner added the `tools/fuzz` sort target (AC-s13's
campaign half, iterating all seven type overrides per column), reconciled the header's slot prose with the two
accepted deviations, re-pinned the macOS header-SHA guard, and the architect added the signed Amendment 2
(§4 / AC-s9: the build-time memory bound is on anonymous residency and excludes file-backed pages of the
scratch mappings). The fuzz target's FIRST campaign found **F2**: `ls_sort_set` decided keep-or-replace,
waited for the scan slot (releasing the mutex), then unwrapped the build pointer; a pass failing from disk-full
or out-of-memory in that window had already torn the build down, so a clean FAILED became a ReleaseSafe panic.
Reproduced independently by the orchestrator (`zig build --fuzz=800 -Donly="fuzz sort"`, panic at
`sort.zig:888`). The planner froze `srt_failure_race`, a forked-child race driver that reproduces the
interleaving 6/6 and turns the panic into a failing assertion (RED 330/331 on both legs); all of it committed
as `b12d51a`. The implementer's fix (round 4, `backend/src/sort.zig` only): `awaitScanIdle` returns the build
as it stands after the wait, `keepableBuild` re-decides under one continuous hold of the mutex, the merge
re-validates generation and pointer locally, `sort_build.?` no longer appears anywhere in `backend/src`, and
the worker no longer holds a build pointer across its pause. Gate 331/331 on both legs; the fuzz target clean
over 2,801 runs with the crashing input preserved in the corpus. Reviewer: PASS, "fixes the class rather than
the instance". Acceptance gate with the relay-chain check: PASS.

Digest note: the per-component tree digest embeds the repository-wide `git status`, so the backend digest
moved during the review while the planner edited `tools/fuzz` concurrently; no file under `backend/` changed
(the fixed file predates the gate run and the review, same blob), so the verdict binds to the reviewed content.

### Carried forward for the frontend cells and the record
- The 20-minute fuzz campaign (`bash tools/fuzz/fuzz.sh --minutes 20 --fresh`) is the AC-s13 campaign record;
  the reviewer asked that its log be attached here when it lands and that the cell reopen if it finds a crash.
- `tools/fuzz/fuzz.sh` aborted on a clean `/tmp` under `set -euo pipefail` (an `ls` glob with no match); the
  implementer diagnosed it, the planner replaced the pipeline with a glob-safe count.

### Round 5 — reopened by the planner's amended frontend test, closed the same day
While converging the two frontend "serves immediately" bridge tests (see the contract amendment below), the
planner probed the core directly and found **F3**: one `ls_window_set` over a LIVE converging prefix could
return rows from two prefix generations — ~5 % of served rows answered `ls_source_row` but returned an empty
`ls_cell` inside the returned range, and ~0.3 % of adjacent pairs ran the wrong way, always by about one
checkpoint interval. Every AC-s16(a) test read its window at a paused scan point, so the frozen suite could not
see it. The planner froze `srt_prefix_window_consistency` (RED, 2370 violations; 331/332) in `4da0753`. Root
cause (implementer, undisputed): the retain-vs-clear decision and the materialization ran under two separate
holds of the mutex, and the cell accessor resolved rows through the live mapping rather than the buffer the
window was built from. Fix (`backend/src/base.zig`, `backend/src/window.zig`, +8/+100): `windowSetSorted`
decides identity under the same hold that materializes; while the sort itself is unchanged
(`sort_gen == win_sort_build_gen`) `windowSlot` and `sourceRow` serve rows inside the window by offset from
the same buffer, so cell and gutter cannot name different rows; a sort change (new column, flip, rebuild)
still re-maps through the live mapping, so the round-2 `srt_numeric_order` requirement holds; `matchFlags`
keys its staleness guard on the same build identity. Before/after on the implementer's 300k-row probe:
2629/2497/2478 empty cells → 0, 144/144/145 inversions → 0. Gate 332/332 on both legs; acceptance gate with
the relay-chain check: PASS. Reviewer: PASS — "correct by construction, not only by the probe".

Hot path re-measured on the 11 GB reference in one session: key pass 1.54× (decimal) / 1.57× (text) the
same-session search scan (≤ 3×); first sorted window 6.6 / 7.5 ms (≤ 100 ms); retained scratch exactly
8 B/row per mapping; sorted scroll 12.5–14.7 ms cold / 9.4–9.5 ms warm per 50-row window (12.4 / 9.0 before —
noise). The stated consequence — a window is rebuilt rather than extended whenever the prefix refined since
the last call — is what a converging view means and was already the behavior; frontends should size their
poll tick around a full window re-materialization.

**AC-s13 campaign record.** `bash tools/fuzz/fuzz.sh --minutes 20 --fresh` on the round-4 core exited 1 only
because seven zero-byte `/tmp/lesssheet-sort-*` files appeared while the frontend cells' test suites ran
concurrently on the same machine; a quiet 8-minute re-run found 0 stray files and exit 0, and the round-5
5-minute campaign (sort target 562/845 PCs, window target 355/523) was clean with 0 stray files. Logs:
`tools/fuzz/campaign/campaign-darwin-20260906-225147.log`, `…-234011.log`, `…-20260907-030936.log`.

**Recorded by the reviewer, non-blocking, for the planner:** after ANY view-mode change (`ls_sort_set`,
`ls_filter_set`, `ls_filter_clear`) the materialized window is still read in the coordinate space it was built
in until the caller re-issues `ls_window_set` — `ls_cell(0,0)` returns the old view's text for one frame while
`ls_source_row(0)` already answers in the new view. Not introduced by this cell and not specific to sort
(filtered views have had the same shape since they shipped); the core's standing convention is "re-issue
`ls_window_set` after a view-mode change before reading". Worth one sentence in the header where the borrow
rule is stated, or a small cross-mode follow-up cell.

## Contract amendment during the build — Amendment 3 and the "serves immediately" change requests

Both frontend cells' round-1 reviews carried a `[contract]` finding on the same frozen assertion: the two bridge
tests required a NON-EMPTY sorted window on the statement after the sort request returned, while
`api/lesssheet.h` §4 promises only `min(K, rows scanned so far)` servable rows — zero before the worker's
first chunk commit — and that the call never blocks. Measured by the orchestrator: 0 rows at return on 5/5
trials (macOS probe), 0/30 passes of the frozen GTK test, and no pre-sort order served at any observation
(GTK probe, 40 samples at 200 µs); first servable rows landed 1.0–3.6 ms after the call on a 4M-row fixture,
and the shared 8-row fixture reached ACTIVE within 0.4 ms. The macOS implementer had satisfied its test only
with a 5 ms busy-wait inside the bridge that also reset the materialized window; the GTK implementer left its
test red and drafted the change request. Both requests were implementer-signed and reviewer-co-signed (each
reviewer re-derived the premise from source). The planner APPROVED both on ground A (DECISION-1 macOS,
DECISION-2 GTK): the tests now poll within a bound and assert that every non-empty window is already in sorted
order (the GTK reviewer's strengthening), with a separate generated-fixture test on macOS for whether the
bridge waited; the bridge's internal wait was ordered out; `api/lesssheet.h` unchanged.

In the same planner turn, the author's decision on the header gesture ("keep the sort under keyboard shortcut
or right-click on the column header") was applied as the signed **Amendment 3**: sorting is triggered only by
the keyboard shortcut (cycle on the cursor column) and the column header's context menu — "Sort Ascending" /
"Sort Descending" / "Clear Sort", the requested direction check-marked, Clear Sort enabled per document — and a
plain header click keeps its pre-feature meaning (macOS: whole-column selection). Committed with the re-pinned
baselines as `4da0753`.

## GTK cell — `build-sort-by-column-gtk` — **PASS (round 3)**

Roles as above; every handoff relayed by reference and journaled (`verify-relay`: PASS). The trusted GTK gate was
run by the orchestrator on each round's tree inside the pinned `fedora:43` image; the round-3 and acceptance
runs cross-built the core from the round-5 backend tree, i.e. the fixed core. Only `apps/gtk/src/lsg_sort.c`
and `apps/gtk/src/main.c` changed. Committed `f456f6b`.

### Rounds
- **Round 1** — 1 `[contract]` (the bridge test above; co-signed, adjudicated as the planner's own test
  defect) + 4 `[impl]`: `do_clear_filter` re-anchored on a SOURCE row while the view was in sorted coordinates;
  a PARKED sort on a network document was never re-driven ("Sorting…" frozen forever); the network-download
  confirmation lived one level too high (the coming context menu would have bypassed it); the indicator size
  was derived at three sites. The header-click cycle the implementer had built was superseded by Amendment 3.
- **Round 2** — Amendment 3 delivered: one `GtkPopoverMenu` with a `GSimpleActionGroup`, model rebuilt on
  every open so check marks and Clear Sort follow the live snapshot, labels from the contract's title macros,
  AT-SPI labels; secondary-button `GtkGestureClick` (the drag gesture is primary-button, no contention); the
  press/release arming retired outright. Findings fixed: land at 0 when clearing a filter under a sort; a
  `sort_request(App*, LsgSortIntent)` funnel owning the no-op guard, the instant-flip exemption and the
  network dialog; one `ind_size`. PARKED on network: the bar says the pass is paused and a guarded re-drive
  re-issues the request only when the ABI-mandated search/jump reset is unobservable (no live find, no jump
  scanning, no net drive), spaced 1 s — judged SOUND. Reviewer: 3 low `[impl]` (the 16 ms settle chain
  viewport-scoped and unbounded while the window stays empty; a repaint requested every tick while parked
  over the network although the prefix is frozen; "Sorting paused" not actionable).
- **Round 3** — settle chain capped at `LSG_SORT_SETTLE_MAX_TICKS` (6 ≈ 100 ms; the reviewer agreed a
  top-row test would have left the network case unbounded); no repaint while paused over the network; one
  `sort_progress_label` resolver naming the cause ("a search is using the scan" / "a jump is using the scan" /
  "resuming"). The two mid-build screenshots first rendered against the defective core were retaken on the
  fixed core: every served row carries gutter and text, order monotone in the signed comparator at the
  interleaving that exposed F3, a deep viewport shows the not-yet-servable blank and fills in at ACTIVE.
  Reviewer: PASS; AC-s15 as amended met clause by clause.

### Durable notes (GTK)
- **Open follow-up for the planner, not a defect:** no keyboard route to the header context menu. The
  `lsg_a11y` shortcuts table's invariant is "everything that fires is listed" and its command enum is frozen,
  so the implementer correctly declined to add an unlisted Menu / Shift+F10 binding. Residual gap: with a sort
  on column 5 and the cursor on column 2, a keyboard-only user reaches Clear Sort only by moving the cursor and
  cycling. Closing it is one planner-side table row plus a handler.
- **Ship-and-measure risk (architect/author):** with a sort active on a `.csv.gz`, each scroll landing costs a
  scattered checkpoint replay (~1.75 s per 50-row window, backend measurement) and `grid_materialize` runs on
  the GTK main thread — a multi-second main-loop stall per scroll against the standing progress rule.
- **Accepted trade-offs:** selection stays in place across a sort (visible, moves with the view, copy job
  stopped first, matches the filter precedent — do not change without asking the author); `hp_owner` as the
  single owner of the shared header progress bar; the PARKED-on-network split above.
- **Headless evidence** lives in the session record, not the repo; the author's GNOME pass covers: indicator
  legibility at HiDPI and in dark; the context menu's check marks and Clear Sort sensitivity and whether
  secondary-click is discoverable; Orca on the Sorting group, the menu items and the changing grid description
  during a build; the failure toast wording (code-reviewed only — no frontend run can produce
  `LS_SORT_FAILED`); whether a blank grid body past the prefix during a 1–2 s build reads as loading; the
  "Sorting paused" state on a network CSV.

## macOS cell — `build-sort-by-column-macos` — **PASS (round 4)**

Roles as above; every handoff relayed by reference and journaled (`verify-relay`: PASS). The trusted macOS gate
was run by the orchestrator on each round's tree (build with warnings-as-errors, `swiftlint --strict`, `swift
test`): 193 tests green in round 1, 197/197 in rounds 2 and 3, 0 lint violations, the only warning the
pre-existing linker deployment-target line. Only `Sources/LessSheetApp` and `Sources/LessSheetKit` changed
(24 files, four of them new: the sort view-model extension, the banner, the headless sort probe, the frame-dump
sort scenes). Acceptance gate with the relay-chain check: PASS. Committed `8ea2b13`.

### Rounds
- **Round 1** — the implementer delivered the feature on the pre-amendment gesture (header click cycling) and,
  to satisfy the frozen "serves immediately" test, put a 5 ms bounded wait inside the bridge that also reset the
  materialized window. Reviewer: 8 findings — 1 `[contract]` (the bridge wait, second key on the change
  request above) + 7 `[impl]`: a jump under a sort was rejected as out of range (view-row vs source-row domain
  mismatch in the short-scan guard); no re-materialize on the BUILDING→ACTIVE tick, so a superseded prefix could
  stay on screen under a "Sorted by …" banner; convergence paced by the 100 ms poll tick with a synchronous
  main-actor materialize and no loading state (290 re-issues ≈ 29 s on the wide/short reference; ~1.75 s per
  gzip window as a silent freeze); clear transitions re-anchored with a source row in a non-identity view; a
  parked network sort never re-driven; dead elapsed-clock state; one rebuild path not bumping the view
  generation. The author then decided the header gesture (Amendment 3).
- **Round 2** — Amendment 3 delivered: `SortCycle.headerMenu` per the frozen truth table, the header's context
  menu built through one factored seam the headless probe also drives, plain click back to whole-column
  selection, ⌘-click and "Select Column" removed. All seven `[impl]` findings fixed; the bridge wait deleted per
  DECISION-1; convergence moved to bounded 8 ms slices (wide/short reference fills by 115 ms, settles at
  265 ms); a "Loading rows…" state in front of slow materializations (6.1–6.8 s per sorted gzip window, shown
  rather than silent). Reviewer: 3 `[impl]` — `NSMenu` autoenabling overrode the Clear Sort `isEnabled`
  (a dead menu item on an unsorted document; the probe read the items before AppKit's validation pass); the
  parked-sort re-drive would reset a COMPLETED find without invalidating the app's find UI; the converge slice
  loop had no no-progress bound while rows were not yet servable. Residual, not blocking: bound the request
  size after a slow fetch.
- **Round 3** — `autoenablesItems = false` with the probe reading the real menu after `update()`; the re-drive
  now refuses while any find request exists and the banner says "paused for find" (the pass resumes when the
  find goes, or on an explicit re-pick); the slice loop requires growth (the implementer reported honestly that
  it could not reproduce the predicted busy-wait — a single slow fetch already exceeds the 8 ms slice — and kept
  the guard as insurance). The residual note was taken up: past the slow-window threshold the request is
  clamped to the visible rows plus 20, taking a sorted gzip window from 6.1–7.0 s to 1.19–1.20 s. Orchestrator
  measurement over a local HTTP server (3M-row fixture, find submitted mid-build): the pass parks at 432 ms,
  the find's 307 matches survive 6 s of ticks with zero re-drives and an honest banner, and the pass resumes
  224 ms after the find is dropped. Reviewer: one `[impl]` finding — `clearSort` under an active filter with a
  scanning re-anchor jump left the sorted view's cells on screen beside a blank gutter until the jump landed (no
  re-issue behind that one path) — with a one-line fix described precisely, and PASS on the condition that the
  hunk matched.
- **Round 4** — the single statement (`materialize` of the current geometry before the jump hand-off in
  `reanchor`) plus its comment; the orchestrator verified by diff that nothing else changed since round 3, which
  the reviewer had set as the condition for closing without another review turn. Gate 197/197.

### Durable notes (macOS)
- **Sorted gzip scrolling** now shows a loading state and requests viewport-sized windows once a fetch has
  proven slow; the fetch still occupies the main thread (the reviewer sanctioned staying on the window lane).
  ~1.2 s per window is the shipped ship-and-measure number.
- **Headless verification** used frame dumps and the env-gated sort probe (`LESSSHEET_SORT`, `_CANCEL`,
  `_SCROLL`, `_FILTER`, `_FIND`, `LESSSHEET_DUMP_EXIT`); no screen capture, no permission prompts.
- **The author's visual pass** (reassembled bundle): right-click a header (three entries, check mark on the
  requested direction, Clear Sort greyed on an unsorted document); ⇧⌘S and View ▸ Sort by Column on the
  cursor's column; a plain header click still selects the whole column; chevron weight and its suppression on a
  narrow column; the sort banner and the "Loading rows…" capsule beside the filter banner in Liquid Glass; a
  completed sort's top rows stable; the "paused for find" banner on a network document.

## Cross-cell follow-ups collected for the author and the planner (none blocking)
1. **Keyboard route to the header sort menu (GTK).** One planner-side row in the frozen `lsg_a11y` table
   (Menu / Shift+F10, display scope, Sorting group) plus a handler. Until then a keyboard-only user reaches
   Clear Sort on another column only by moving the cursor there and cycling.
2. **Header prose: re-issue `ls_window_set` after any view-mode change before reading cells** (backend
   reviewer, round 5) — or a small cross-mode cell making the materialized window follow the view kind.
3. **Window-vs-prefix servability can disagree at the instant a sort starts** (macOS reviewer, round 3, on the
   `68b29ed` core): `ls_source_row` answered for view rows 0–3 while `ls_window_set` served zero rows for a
   window covering them — gutter numbers beside blank cells for one tick during a build. Same family as F3;
   attribute to the core, not the frontends.
4. **Gzip sorted scrolling** stays a ship-and-measure item: ~1.75 s per 50-row window in the core; the macOS
   frontend now bounds the request so a window costs ~1.2 s and shows a loading state; GTK materializes on the
   main loop without a loading state for that case.
5. **Both frontends' first-frame behavior after a sort request** is now measured (core first servable rows
   1.0–3.6 ms on a 4M-row file; 6.6–7.5 ms first window on the 11 GB reference), and both cells' mid-build
   evidence was re-taken or re-run on the fixed core.
