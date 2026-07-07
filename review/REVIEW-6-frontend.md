# REVIEW-6-frontend — find-seek, apps/macos only

Verdict: **FAIL** — one [impl] finding (live wrap notice is unobservable); everything else
conforms. No contract defects; no frozen-path drift. Fix is small and implementer-owned.

Reviewed at contract d640911 against `docs/architecture/ARCH-find-seek.md` app reqs 6–10 and
acceptance criteria 7–9. Parallel-cell discipline honored: no gate.sh, no zig build; one
`swift test` run; live checks via direct execution of the already-built debug binary
(`apps/macos/.build/arm64-apple-macosx/debug/LessSheet`).

## Evidence gathered

- `swift test` (1 run): **42 tests, 37 pass, 5 red** — exactly the claimed stub-blocked set
  (`bridgeRunsATextSearch…`, `bridgeRunsAWhereSearch…`, `bridgeScopesTextSearchesExactly`,
  `frontendMatcherVerdictsAreIdenticalToTheCore`, `aFreshOrReopenedSessionHasZeroSearchState`).
  All five fail FAST (~0.004 s each, whole run 0.005 s) at the `#require(startSearch)` guard —
  no polls, no hangs. Nothing else is red (all viewer-ui baseline tests green).
- Frozen-path check: `git diff d640911 -- api apps/macos/Sources/Contracts apps/macos/Tests
  apps/macos/Package.swift` → empty. Changes confined to implementer-owned Sources + new
  `FindControls.swift`.
- Live run, find probe (`LESSSHEET_FIND=needle` on find.csv, seed core):
  `first_rows_visible_ms=192` → `find.submit at_ms=0` → `find.rejected at_ms=0` → dump → exit.
  Real popup submit path, fail-fast against the stub, no hang.
- Live run, regression (`LESSSHEET_JUMP=20000000` on the 2.6 GB big2g.csv, debug build):
  `first_rows_visible_ms=231` (< 500 ms budget with all find code present — find machinery is
  lazy); beyond-frontier jump scan with monotone progress; heartbeat gaps max ~323 ms
  (< 500 ms, no stall); arrival dump shows the gutter starting exactly at row 20000000.
  Jump semantics, marker, launch mode intact.
- Dumps (existing /tmp/lsprobe/find_*.png, cross-read against the fixture): popup Text and
  Where states correct; Find button leftmost ([Find][Jump][Header][Sep][Quote][Settings]);
  highlights are exactly the six smart-case "needle" rows with the current match visually
  distinct (stronger fill + border) and Gizmo/café rows clean; "Match 3 of 47…" + 34% bar +
  Cancel; "No matches"; "Wrapped to start". VoiceOver labels present in code on the mode
  switch, column/operator pickers, value field, nav buttons, scanning row. Reduce Motion
  honored (shake skipped, blink kept) in the reused rejection components.

## Semantics review (matcher + state machine + bridge)

- **CellMatcher** (`Sources/LessSheetKit/FindLogic.swift`): smart case folds ASCII 0x41–0x5A on
  BOTH sides only when the query has no ASCII-uppercase byte; bytes >= 0x80 never fold (and
  fold cannot corrupt multi-byte UTF-8 — continuation/lead bytes are outside 0x41–0x5A).
  Equality uses `Array(cell.utf8) == Array(value.utf8)` — byte-exact, avoiding the Swift
  `String ==` canonical-equivalence (NFC) hazard; Swift String preserves exact bytes for valid
  UTF-8, matching the pin's valid-UTF-8 scope. Ordering never touches Float/Double: exact
  `D × 10^exp` decimal with verbatim pinned-grammar parse (accepts/rejects identically to
  `NumericGrammar` — checked case by case), correct sign/zero canonicalization ("-0.0" == "0",
  canonical zero non-negative), leading-zero strip (no exp shift) / trailing-zero strip
  (exp+1) both value-preserving, MSD-position alignment (`exp + digits.count - 1`, saturating),
  longer-equal-prefix ⇒ strictly greater (sound because trailing zeros are stripped), and
  int64-saturating exponents per the header's documented latitude ("1e400" > "1e399" works).
  I found no semantic divergence from `api/lesssheet.h ls_search_request`; the verdict-identity
  test will confirm at integration.
- **FindControl**: conforms line-by-line to the frozen doc-comment pins — submit scope
  derivation (nil iff all visible, else ascending), ordering/empty-value/out-of-range-column
  rejection, began reset, max-fold counts with latched `totalIsFinal`, progress max-fold →
  nil on done/cancelled, notice derived purely from the snapshot (self-clearing), noMatches
  only on final zero, step anchors (forward row+1 saturating / backward row, viewport when no
  landing), wrapNav mapping, stopped-keeps-partials, closed/invalidated clear display + retain
  draft. All 12 frozen view-model tests pass.
- **Bridge** (`Sources/LessSheetKit/CoreDocumentSession.swift`): request buffers scoped by
  `withUnsafeBufferPointer` across the whole `ls_search_start` (borrow rule honored); scope
  nil → NULL ptr / len 0; predicate ignores scope; op/dir/status enums mapped 1:1 (ABI pin
  test green); `LS_SEARCH_IDLE → nil` snapshot; no `ls_str` retained anywhere in the search
  path; poll/control lane needs no lock (matches the jump bridge convention), close still
  lock-guarded + idempotent, and both open() and closeDocument() cancel AND await the poll
  task before `ls_close`.
- **Threading/poll lifecycle**: the sustained ≤100 ms poll loop runs off the main actor
  (`Task.detached(.utility)`) and stops itself once index complete + no jump scanning + search
  neither scanning nor nav-searching; submit/step restart it. The one-shot
  startSearch/navigateSearch/cancelSearch/searchStatus calls in submit/step paths run on the
  main actor — sanctioned: the frozen `DocumentSession` contract pins all four as never
  blocking, identical to the accepted jump convention, and the 2.6 GB heartbeat run showed no
  main-thread gap > ~323 ms during a full background scan.
- **UX wiring**: ⌘F reveal+focus, Enter submits, Enter-on-unchanged-request steps forward
  (req 7), ⌘G/⇧⌘G in the Find menu, Esc closes + clears highlights + cancels the core scan
  while the draft survives (and survives dialect re-open via `invalidated` in
  `DocumentModel.open`); scanning popup stays reachable past the click-away scrim with its
  Cancel affordance ("Stopped", partials kept); landings page the window before scrolling,
  same mechanics as jump. Highlight painting is O(viewport), zero core calls, header/filler
  rows never highlighted.
- **FindProbe**: drives the REAL submit path (`openFindField` + draft + the same
  `submitFind()` the TextField's onSubmit calls); heartbeat is a genuine 250 ms main-actor
  task logging inter-tick gaps with a STALL marker and 90 s safety timeout;
  `noteScanningShown` is render-layer evidence via the popup's onChange.

## Findings

1. **[impl] The wrap notice is never user-visible in live use.** `DocumentModel.foldSearch`
   (`Sources/LessSheetApp/ViewerModel.swift`) folds the exhausted poll (notice set), then
   auto-issues `wrapNav` and immediately re-folds `session.searchStatus()` — all within one
   synchronous main-actor turn. On a completed scan the wrap navigation resolves synchronously
   (pinned), so the second `resolved` returns `.found` and the purely-snapshot-derived notice
   is nil again before SwiftUI ever renders (@Observable coalesces per turn — zero-frame
   lifetime). When the wrap must scan, the immediate re-fold sees nav `.searching` — notice
   also cleared. So ARCH Outputs "the popup briefly shows a 'wrapped' notice" / req 7 "wrap +
   notice both directions" cannot be observed live in ANY path; the find_findwrapped.png dump
   proves only the rendering (synthetic session), not reachability. Sub-symptom: with exactly
   one match, wrap lands on the same row, `current` is unchanged, so no re-scroll either —
   ⌘G past the last match gives zero visible feedback if the user scrolled away.
   Fix within the contract (the frozen `FindControlling` deliberately leaves WHEN the caller
   issues `wrapNav` open): e.g. latch the last non-nil notice in popup presentation state for
   a minimum display duration, or defer the auto wrap-nav a beat. Frozen tests are untouched
   by either.

## Notes / nits (non-gating)

- N1. Scanning row shows bar + "34%" + Cancel but not the literal "Scanning…" word from the
  ARCH req-10 copy examples (the VoiceOver label does say "Scanning"). Copy is declared
  presentation-iterable in the ARCH; consider adding the word while fixing finding 1.
- N2. `startSearch` maps `Int` columns/scope via `UInt32(...)`, which traps on a negative or
  > UInt32.max value instead of returning `false` ("out-of-range column" per the protocol
  doc). Unreachable through `FindControlling.submit` (validates 0..<columnCount first) and
  through the UI pickers; worth a clamp/guard whenever the bridge is next touched.
- N3. Pre-existing (present at d640911, not introduced here): `startPolling` cancels but does
  not await the task it replaces, leaving a microsecond-scale theoretical window where an
  already-replaced poll iteration's C calls could overlap a subsequent `ls_close`. The find
  slice only added `searchStatus()` to the existing loop. Consider awaiting the replaced task
  or a single generation-checked poller in a future round.

## Deferred to the integration review (blocked on the real core)

- Criterion 8 (bridge landings/counts/navigation/cancel exactness; matcher-verdict identity)
  — the 5 red tests; machinery verified, must go green against the real archive.
- Criterion 9's heartbeat proof for a FULL-FILE SEARCH on big2g.csv (probe exists and works;
  today it can only prove the rejection path), and req 8 "window stays interactive" live.
- Criterion 10 (release wall-clock/throughput of a full-file search, steady-state RSS
  < 120 MB during/after search, < 50 ms behind-frontier landings, no > 17 ms scroll hitch
  with highlights active).

Reviewer: frontend cell, 2026-07-07.

---

# Addendum — round-2 re-verdict (2026-07-07)

Verdict: **PASS**.

Re-reviewed after the implementer's round-2 changes (wrap-notice latch + poll-task join in
ViewerModel.swift, "Scanning…" copy + wrap-trace probe in FindControls.swift, seam fix +
UInt32(exactly:) bounds in CoreDocumentSession.swift) with the real core landed. My own runs:
`swift test` 42/42 green (matcher identity matrix included) and `bash apps/macos/.aidev/gate.sh
apps/macos` → GATE: PASS. Frozen paths still untouched.

## 1. Finding 1 (wrap notice) — RESOLVED, verified live

Mechanism: `foldSearch` no longer issues the wrap navigation synchronously; `scheduleWrapNav`
latches the notice for 900 ms and then navigates on a fresh main-actor turn; an explicit
step/submit/cancel/close cancels the pending latch. The frozen seam is untouched (FindLogic.swift
byte-identical to round 1; the pinned notice-is-a-pure-function-of-snapshot self-clear still
holds — all frozen tests green).

Live traces (debug binary, find.csv, `LESSSHEET_FIND` + `LESSSHEET_FIND_WRAP=1`):
- Multi-match ("needle", m=6): landed pos 1 row 0 → wrap backward → `notice=wrappedToEnd at_ms=62`,
  held through heartbeat ticks at 329/594/846 ms, `notice=none at_ms=1016` exactly at
  `wrap_landed pos=6 row_0based=7`. Terminal dump shows the viewport on row 8 with the strong
  highlight on "end needle" and "Match 6 of 6". Reproduces the implementer's claimed 72→1034 ms
  trace (mine 62→1016 — same shape).
- Single-match ("Needle", m=1): notice at 67 ms, held (ticks 318/585/838), cleared at 1072 ms with
  `wrap_landed pos=1 row_0based=3` — the same-row wrap now gives clear feedback (round-1
  sub-symptom closed).
- Forward direction: the probe only drives the backward wrap; forward is covered by the green
  frozen pin (`wrappedToStart` → `.fromTop`) riding the identical notice-agnostic latch path.
  Residual gap is probe coverage only, not behavior.

## 2. Adversarial experiment — seam root cause: STALE LINK, bool-ABI claim REFUTED

Procedure (file backed up byte-exact, sha 1ab19958…, restored byte-exact afterwards — NOT via
`git checkout`, which would have reverted the uncommitted implementer work to the d640911 seed):
1. Reverted both `startSearch` return sites to the round-1 tail-expression form
   (`return ls_search_start(doc, &req)`), removing the local-binding "fix".
2. `rm -rf .build` (guaranteed-fresh link against the current real archive) + `swift test`.
3. Result: **42/42 PASS — all 5 bridge tests green with the reverted form.**
4. Restored the file (sha verified identical), re-ran the component gate: GATE: PASS, 42/42.

Conclusion — outcome (b): the failure does not travel with the source form; it traveled with the
link. The AAPCS64 upper-bits story is refuted (and was implausible: Swift's importer narrows C
bool returns; also `ls_search_start` is the ONLY bool-returning function in the whole C surface —
bool struct fields are memory loads, immune to any return-register theory). The real mechanism:
Package.swift links `liblesssheet.a` via `.linkedLibrary` + `-L` unsafeFlags, so SwiftPM does NOT
track the archive as a build input; when the backend landed, `swift test` reran the OLD binary
still linked against the SEED core (startSearch always false). The implementer's source edit
dirtied LessSheetKit and forced the relink that actually fixed it — the local binding was a
coincidental passenger.

Hazards from this outcome:
- 2a. **[impl]** The comments at the two `startSearch` return sites in
  `apps/macos/Sources/LessSheetKit/CoreDocumentSession.swift` assert the false ABI mechanism as
  fact. They must be corrected (or the now-pointless local bindings dropped); as written they
  will cargo-cult "bind every C bool" and misdirect future debugging. The binding itself is
  harmless — this is a documentation-truth fix, small.
- 2b. **[contract]** (build-harness defect, planner/root-owned — not solvable by the implementer:
  gate.sh is .aidev/*, Package.swift is frozen; independently VALIDATED by the experiment above):
  gates can certify against a STALE archive. The macos CONFORMANCE_CMD rebuilds the backend and
  then `swift build`/`swift test` — but a fresh `liblesssheet.a` does not dirty the Swift link, so
  the gate can run tests against a binary linked with an outdated core (false green after backend
  changes; false red as happened here). Recommend the gate force a relink when the archive is
  newer than the built products (mtime compare + delete the stale products, or restructure the
  link so SwiftPM tracks the artifact). Until then, every cross-component verdict should follow a
  clean build.
- Note: release link emits a benign toolchain-skew warning (archive object built for macOS 26.5.2
  vs 26.0 deployment target) — cosmetic, backend/root may want to align `-target` someday.

## 3. Round-1 nits — all resolved

- N1: scanning row now reads "Scanning… NN%" (FindControls.swift `scanningRow`).
- N2: `UInt32(exactly:)` guards on predicate column and text scope — out-of-range returns false
  (matching the protocol's reject semantics) instead of trapping.
- N3: poll-task join — each new detached poll task cancels AND awaits its predecessor before its
  first poll (and `stopPolling` still awaits the newest), closing the replaced-task-vs-`ls_close`
  window by induction. Join happens off the main actor; startPolling stays non-blocking.

## 4. Deferred measurements — now taken (release build, Apple Silicon, single machine —
order-of-magnitude evidence)

| Measure | Target | Measured |
| --- | --- | --- |
| Full-file worst-case text search, 2.6 GB (no-match query scans every byte) | single-digit minutes | **70.9 s / 73.4 s** (two runs, ~37–39 MB/s app-observed); progress monotone 0→100%, exact final count 0, "No matches" terminal |
| Main-thread gaps during that full scan (criterion 9 heartbeat on big2g.csv) | < 500 ms | **max 328 ms** (runs: 325 / 328), zero STALL ticks |
| Memory during + after search (pinned methodology: phys_footprint, not ru_maxrss) | < 120 MB | **39.1–40.1 MB during, 40.0 MB steady after** (~85 s of post-scan samples); resident grows to ~2.55 GB of clean file-backed mmap pages, excluded per the REVIEW-5 pinned methodology |
| Landing behind the frontier (early match, big2g.csv) | < 50 ms core-side | **64 ms app-level end-to-end** submit→landed, which includes the 100 ms poll cadence — consistent with the core-side pin; the precise core-side number belongs to the backend review |
| Cold start with find machinery linked, 2.6 GB | < 500 ms | **198–247 ms** (release), 181–192 ms debug on the small fixture |
| Scroll hitch with highlights active | < 17 ms/frame | Not headlessly measurable (needs interactive scroll under Instruments). Code-level: highlight painting is O(viewport) byte-matcher work, no per-frame core calls; no main-thread degradation at the 250 ms heartbeat resolution. Flagged for the interactive pass. |

## Final verdict line

**PASS** — round-1 finding and nits resolved and verified live; 42/42 green through the gate;
non-functional targets measured within budget. Carry-forward items for the coordinator: 2a
([impl], comment truthfulness at the seam) and 2b ([contract], stale-archive relink hazard in the
build harness) — neither blocks find-seek.

Reviewer: frontend cell, round 2, 2026-07-07.
