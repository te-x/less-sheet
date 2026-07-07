# ARCH — find-seek

Streaming search over any-size files: plain-text match and typed column predicates, served by
the core (shared by all future frontends), navigated match-to-match with visible progress over
not-yet-indexed regions — the slice-4 machinery of the project brief, riding the existing
frontier/index/scan infrastructure from viewer-ui. Filtering to matching-rows-only remains a
later slice (10); this design must not preclude it.

Decisions made interactively with the author on 2026-07-06.

## Problem & scope

viewer-ui gave instant open, full scrolling, and exact jumps. What's missing is content-driven
navigation: "take me to the row that says X" without knowing its number. This slice adds:

1. **Core**: a streaming matcher (plain text + typed predicates) scanning the file with
   progress, feeding a bounded match-count index; match navigation primitives (first/next/
   previous relative to a row); same job discipline as jump-scans.
2. **App**: a Find button in the floating control row with a two-mode popup (Text | Where),
   match highlighting in the grid, incremental match counts, next/previous navigation.

### Non-goals (this slice)
- Regular expressions (decided out; plain text + predicates only).
- Filtering the view to matching rows (slice 10 — but see Compatibility below).
- Full Unicode case folding (smart-case folds ASCII only in v1; documented limitation).
- Search history, saved searches, multi-query. Search-as-you-type (explicitly: the scan fires
  on Enter, never per keystroke — a keystroke must never trigger a multi-GB scan).
- Cross-column compound predicates (AND/OR) — single column per Where query in v1.

## Inputs / Outputs

**Inputs**
- A search request, either:
  - **Text**: a UTF-8 query string, matched as a substring of any *visible* column's cell text,
    with **smart case**: an all-lowercase query matches case-insensitively (ASCII folding);
    any uppercase byte makes the match exact. Empty query = no search.
  - **Where (predicate)**: a column index (any column, hidden included — the picker marks
    hidden ones), an operator from { = ≠ < > ≤ ≥ }, and a value string.
    - = and ≠ compare cell text to the value **byte-exactly** (no case folding — predicates
      are precise tools; smart case belongs to Text mode only).
    - < > ≤ ≥ are **numeric**: both cell and value must parse under the core's pinned numeric
      grammar; a non-numeric cell never matches an ordering predicate (and a non-numeric
      value is a UI-level validation error — shake, same language as invalid jumps).
- Navigation commands: first (Enter), next (⌘G / Enter again), previous (⇧⌘G), each relative
  to the current match (or viewport when there is none).
- Cancel (Esc) while a search scan runs.

**Outputs**
- Landings: the viewport moves to the matched row (same landing mechanics as jump); the
  matched cell is strongly highlighted; all other matching cells currently in the viewport get
  a subtle highlight (frontend re-evaluates the same pinned matcher on materialized cells —
  O(viewport), zero core calls).
- Counts: "match *n* of *m*", where *n* is the 1-based position of the current match in file
  order and *m* is the total **found so far** by the background match-scan; the popup shows
  scan progress (%) until the scan completes, after which *m* is final and stops growing.
- Wrap: Next on the last known match wraps to the first match and the popup briefly shows a
  "wrapped" notice (same for Previous on the first match, wrapping to the last).
- No match anywhere (scan complete, zero matches): the popup states it plainly ("No matches")
  — the viewport does not move. A search whose scan is cancelled reports what it knew so far
  and stops (viewport stays wherever the last landing put it).

**Error cases**
- Ordering predicate with a non-numeric value: rejected at the popup (red blink + shake,
  Reduce Motion = blink only) before any core call.
- Search on an empty document / query matching nothing: "No matches", no movement, no error.
- Dialect re-open (pill/Settings change) or a new open: active search results and highlights
  are cleared (content changed); the popup keeps the typed query text so re-running is one
  Enter. Hidden-column changes re-scope Text searches from the next run (running scans finish
  under the scope they started with).

## Functional requirements

**Core machinery**
1. One matcher engine, two match kinds (text with smart-case ASCII folding; column predicate
   with byte-equality and numeric ordering per the pinned grammar), evaluated per data row on
   raw cell text (quoting already removed). The header record is never searched. Matching is
   defined per-cell; a row matches if any in-scope cell matches (Text) or the target column's
   cell matches (Where). Text-mode scope (the visible-column set) is part of the search
   request, fixed for that scan.
2. **Match navigation is streaming**: "first/next/previous match from row R, direction D" scans
   from R in D, returning the first matching row (and the matching column for highlight/
   landing). Behind the frontier this is served from mmap re-lex (fast, bounded by disk);
   beyond it, the same scan advances the shared frontier (paid once, kept — identical to
   jump-scans) with progress. Never blocks the caller thread beyond the sanctioned fast path.
3. **Match counting is bounded**: the background match-scan maintains match COUNTS per index
   block (aligned with the existing sparse row-index checkpoints), never a materialized list
   of match rows. Memory for a search is O(index checkpoints), independent of match density.
   Position *n* of a landed match = sum of block counts before it + in-block scan; total *m*
   = sum so far. Counts are exact for scanned regions, never estimated.
4. **Job discipline**: search scans and jump scans share the single background-scan slot —
   starting either cancels the other (frontier and count gains are kept; the cancelled job
   reports terminal state). One active search per document; a new query/predicate replaces
   the previous search entirely (counts reset). All progress observable by polling ≤ 100 ms,
   monotone within a job.
5. A dialect re-open invalidates all search state in the core (new document identity).

**App UX**
6. A **Find button** joins the floating control row (leftmost: [Find][Jump][Header][Separator]
   [Quote][Settings]), magnifying-glass glyph, same glass/reveal behavior. ⌘F reveals the
   overlay and opens the popup focused; Esc closes it (highlights clear on close).
7. The popup (same upward same-width pill pattern) has a segmented switch: **Text** (one query
   field) | **Where** (column picker listing all columns — hidden ones marked — operator
   picker = ≠ < > ≤ ≥, value field). Enter runs the search: **first match in the FILE** (from
   the top), then Enter/⌘G = next, ⇧⌘G = previous, with wrap + notice both directions.
8. While a scan runs the popup shows progress (%) + the growing "match n of m…" count + cancel
   affordance; the main window stays fully interactive (scroll, other controls). Landing on a
   match moves the viewport exactly like a jump landing (including the overscroll allowance
   near EOF).
9. Highlighting: all matching cells in the viewport get a subtle highlight; the current match
   is distinct; both use semantic colors legible in light/dark and on the glass band if the
   header region is in view (header cells never highlight — they're never matched).
10. All popup copy in user vocabulary, sentence case ("No matches", "Wrapped to start",
    "Scanning… 34%"); VoiceOver labels on the mode switch, pickers, and navigation buttons;
    keyboard-only operation fully possible.

## Non-functional constraints
- Cold start unaffected (< 500 ms; find machinery is lazy — zero cost until first search).
- **No silent stalls**: any search that can exceed ~100 ms perceived latency shows progress
  from its first moment; cancellable at any time; UI thread never blocks on search calls.
- **Memory**: search adds O(index checkpoints) + O(1) job state — bounded regardless of match
  density; total app steady-state budget stays < 120 MB on multi-GB files, search active.
- Search scan throughput: reviewer-measured; must saturate the same order as the background
  indexer (it is the same scan loop with a matcher inlined); a full-file text search on the
  2.6 GB fixture completes in reviewer-measured single-digit minutes worst case on Apple
  Silicon, with the UI live throughout. Landings behind the frontier feel instant (< 50 ms
  core-side, same as jumps).
- Zig 0.16.0 docs-first, read-only core, no new dependencies, bundle stays single-digit MB.
- The frozen TimingMarker and all viewer-ui behavior (launch modes, marker, dialect flow,
  jump semantics incl. rejection UX) are unchanged.

## Component decomposition & data flow
- **api/lesssheet.h (root-frozen, amended)**: search request representation (kind, query
  bytes/column/operator/value, visible-column scope), search job control (start/cancel),
  polling (state, progress, found row+col, position/total counts + exactness), navigation
  (next/previous from a row). Exact shapes are the planner's. The single-scan-slot rule and
  its interaction with ls_jump_* must be pinned explicitly. 64-bit rows throughout.
- **backend/**: matcher (smart-case ASCII fold, byte equality, numeric compare via the
  existing pinned grammar); scan-loop integration with the existing worker thread + frontier;
  per-block match counters hung off the existing checkpoint structure; job replacement logic.
- **apps/macos Contracts (frozen, amended)**: search view-model protocols (query composing,
  mode switch, count/progress state machine, wrap semantics, rejection validation), bridged
  search session API; frozen tests for all of it.
- **LessSheetKit**: bridge (search start/poll/navigate off main actor, same discipline as
  jumps); viewport matcher re-evaluation for highlights (pinned to identical semantics via
  contract tests comparing frontend and core matcher verdicts on fixture cells).
- **LessSheetApp**: Find button + popup (Text|Where), highlight rendering in SheetRow,
  count/progress/wrap copy, shortcuts (⌘F, ⌘G, ⇧⌘G), Esc/clear behavior.

Flow: Enter → core search job (from row 0) → first landing (viewport moves, highlights on) →
background match-scan continues filling counts (popup count grows to final) → ⌘G/⇧⌘G stream
next/previous (instant behind frontier; progress+cancel beyond) → Esc closes popup, clears
highlights; query text retained for the session.

**Compatibility with filtering (slice 10)**: the per-block match counters are exactly the
structure a filtered view needs to map view-relative rows to physical rows block-by-block;
the matcher and its request representation are view-agnostic. Nothing here assumes a search
is transient UI state — the planner should keep the search-job handle opaque so slice 10 can
promote one into a view definition.

## External interfaces
Only the C ABI between core and frontends. No network, no persistence, no new dependencies.

## Acceptance criteria (each testable)

*Core (gate-enforced)*
1. Text matcher: smart-case behavior pinned (lowercase query matches mixed-case cell; query
   with an uppercase byte requires exact bytes); substring at cell start/middle/end; UTF-8
   bytes beyond ASCII match byte-exactly (no folding); header record never matches; hidden
   columns excluded exactly per the request's scope set.
2. Predicate matcher: = and ≠ byte-exact; < > ≤ ≥ true iff both sides parse under the pinned
   numeric grammar and compare accordingly (fixtures: integers, decimals, exponents, signs,
   whitespace-padded, non-numeric cells never matching; boundary equality cases for ≤ ≥).
3. Streaming navigation: first/next/previous from arbitrary anchor rows land on the exactly
   correct match row+col in both directions, behind and beyond the frontier; beyond-frontier
   search advances the shared frontier (verified by a subsequent instant re-scan) and reports
   monotone progress to 1.0 or terminal cancel.
4. Counts: per-block counters sum to the exact total on scan completion for fixtures with
   known match layouts (incl. zero matches, every-row matches, matches straddling checkpoint
   boundaries); position-of-match n correct at block boundaries; memory for a
   dense-match search stays O(checkpoints) (probe: counter storage does not grow with match
   count).
5. Job discipline: starting a search cancels a running jump and vice versa (both report
   terminal states; frontier gains kept); a new search replaces the old (counts reset);
   ls_close during a search scan is safe; progress monotone within a job.
6. A search on a re-opened (dialect-changed) document starts from zero state.

*App (gate-enforced where headless; reviewer-measured otherwise)*
7. Frozen view-model tests: mode switch, ordering-predicate value validation (non-numeric →
   rejection state), count state machine (growing → final), wrap-with-notice both directions,
   Esc-clears-highlights, query-retained-across-reopen semantics.
8. Bridge tests against the real core: run a Text and a Where search over fixtures through
   CoreDocumentSession — landings, counts, navigation, cancellation all exact; frontend
   viewport matcher verdicts byte-identical to core verdicts over a fixture cell matrix.
9. Dump-verified: popup Text and Where states; viewport with subtle+strong highlights; count
   copy ("match 3 of 47", scanning state with %); "No matches" state; wrapped notice.
   LESSSHEET_FIND=<query> driver hook (like LESSSHEET_JUMP) drives the real UI path headlessly;
   heartbeat proof that a full-file search on big2g.csv keeps main-thread gaps < 500 ms.
10. Reviewer-measured on the 2.6 GB fixture (release): full-file text search wall-clock and
    throughput reported; steady-state RSS < 120 MB during and after; landings behind frontier
    < 50 ms core-side; no main-thread hitch > 17 ms while scrolling with highlights active.

## Open Questions
None. (Popup layout/copy details and highlight colors are presentation state, iterable in
build rounds; the Find button's leftmost position was set by the architect consistent with
the author's explicit control-row order and is trivially movable.)
