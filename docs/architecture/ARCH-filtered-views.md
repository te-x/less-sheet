# ARCH — filtered-views

Brief slice 10. Show only the rows where a predicate holds — a **filter view**: a derived row set over
the same windowed, O(viewport) machinery, built by a progress-reporting streaming scan. This is the
"new view kind" the addressing model was designed for from day one (PROJECT.md): the unfiltered
document is the *identity view*, and a filter is a second view over the same document, addressed by the
same view-relative row indices.

The slice is largely **cashing in prior design**, not new machinery: the find-seek match-scan already
builds exactly what a filter needs — a streaming predicate scan with per-block match counters, a
converging `total` (n of m), progress, cancellation, and the shared single-scan-slot / monotone
frontier model. A filter reuses that scan and additionally **exposes the matched rows as an
addressable view**. The predicate grammar is the existing `ls_search_request` (TEXT / WHERE), verbatim.

## Problem & scope

A user peeking at a large CSV wants "show me only the rows where `status = error`" (or containing
`timeout`) without waiting and without losing their place — then scroll, find within those rows, and
clear back to the full file. Today there is no way to hide non-matching rows; Find/Where only *navigate*
between matches.

**In scope**
- A **single-predicate filter** (one `ls_search_request`: TEXT substring over a column set, or WHERE
  typed single-column `= ≠ < > ≤ ≥`) that defines the active view.
- **In-place remap**: while a filter is active, all existing row accessors address the *filtered* rows
  (row `i` = the i-th matching row in file order); clearing restores the identity view.
- A **streaming filter-scan** with visible progress that reuses the find-seek per-block counters and the
  shared frontier; the grid fills with matching rows as the scan advances — never O(file) up front,
  never blocking the UI.
- **Original (unfiltered) row numbers** shown in the gutter for each matching row.
- **Find composes within the filter**: running Find while filtered searches only the filtered rows,
  with filter-relative counts/positions.
- **Jump under a filter** interprets the target as an original row number, landing on the nearest match.
- **Clear re-anchors** near the row you were viewing.
- Frontend UX to define / apply / clear a filter, reusing the existing Find popup.

### Non-goals (this slice)
- **No compound predicates** (no AND/OR, no multi-column conjunction) — one predicate per filter.
  Compound filtering is a later slice; the request type stays the single `ls_search_request`.
- **No multiple simultaneous views / saved views / filter-of-a-filter** — exactly one active filter at a
  time (in-place mode, not a view-handle object).
- No new predicate operators, no regex, no Unicode case-folding beyond the existing ASCII smart-case.
- No editing, no writing filtered output; the source and the base parse are untouched.
- No column filtering (hiding columns is the existing orthogonal presentation feature).

## Inputs / Outputs

**Inputs**
- **Set filter**: one `ls_search_request` — identical shape, grammar, and validation to Find:
  - TEXT: a UTF-8 query (len > 0) + a column scope set (NULL = all columns), ASCII smart case.
  - WHERE: a column index + operator (`= ≠` byte-exact; `< > ≤ ≥` numeric under the pinned grammar) +
    value bytes. A non-numeric value for an ordering operator is rejected (as in Find).
- **Clear filter**.
- All existing view operations, now interpreted in the active view's coordinates: window set, cell read,
  row-count query, jump, find (start/nav/cancel), index/progress polls.

**Outputs**
- While filtered, the document **presents only matching rows**, indexed `0 … m-1` in file order:
  - Row count reports the **match count `m`** — an estimate that converges, `exact` once the filter-scan
    completes (identical semantics to the unfiltered count during indexing).
  - Window/cell reads serve the matching rows and their cells (all existing cell rules apply: quoting,
    truncate/pad, 4 KiB display cap, truncation flag).
  - The **source (original) row number** of any served filtered row is retrievable, for the gutter.
- **Filter progress**: a pollable status — state (idle / scanning / done / cancelled), progress fraction
  [0,1] monotone within a filter, and the converging match count (`total`, `total_exact`).
- **Find within a filter**: the existing search outputs, but scoped to the filtered view — `total`/
  `position` count rows that satisfy **both** the filter and the find predicate; `found_row` is a
  filtered index; navigation lands within the filtered view.
- **Jump within a filter**: lands on the nearest matching row at-or-after the requested original row
  number (clamped to the last match at EOF); `landed_row` is the filtered index of that row.

**Error cases**
- Invalid filter request (empty TEXT query, out-of-range column/scope, non-numeric value for an ordering
  op) → rejected exactly as `ls_search_start` rejects it; the current view is unchanged.
- Filter matches nothing (scan complete): the filtered view has **0 rows** (row count exact 0); the grid
  is empty with a plain "no matching rows" message. While still scanning with 0 matches so far: progress
  shown, grid empty-so-far.
- Setting or clearing a filter, or a dialect/encoding re-open, **resets any active find** (the coordinate
  space changed) — mirroring how a dialect change clears search today. A dialect/encoding change (a
  re-open, new document identity) also clears the filter.

## Functional requirements

**Core — the filter view**
1. **Set/clear.** A new call sets the active filter from an `ls_search_request` (validated identically to
   Find); another clears it. At most one filter is active. Setting a filter enters filtered mode; clearing
   returns to the identity view. Setting an equivalent request while already filtered is allowed (re-runs).
2. **In-place remap.** While a filter is active, `ls_row_count_get`, `ls_window_set`, `ls_cell` /
   `ls_cell_truncated`, `ls_jump_*`, and `ls_search_*` operate in **filtered coordinates** (row `i` = the
   i-th matching data row in file order). The effective header record is unaffected (it is not a data row;
   `ls_header_cell` is unchanged). Clearing restores identity-view coordinates.
3. **Streaming filter-scan, counters not lists.** The set of matching rows is tracked with **per-block
   match counters aligned to the sparse row-index checkpoints** (the find-seek mechanism) — never a
   materialized list of matching row numbers. Memory for a filter is O(index checkpoints), independent of
   the match count. Mapping a filtered index ↔ its source row, and materializing a filtered window, are
   served by counting into blocks + a bounded in-block re-lex (O(checkpoints) + O(block)), not O(matches).
4. **Shared frontier, paid once.** The filter-scan advances the same monotone frontier as the background
   index / jump / find scans and **feeds the base row index** as it goes (bytes scanned for the filter
   also index the document). It shares the single background scan slot: starting a jump or find scan may
   take the slot from the filter-scan (frontier and counter gains are kept); the **filter mode itself
   persists** regardless (it is a view mode, not a transient job) and its discovered-match frontier only
   advances, never regresses. Progress and counts are pollable ≤ 100 ms, monotone within the filter.
5. **First filtered rows are O(viewport).** Setting a filter never scans the whole file before returning;
   the first screen of matching rows is served as soon as they are found behind the frontier (the scan
   continues in the background with progress), so the UI never blocks. Rows beyond the filter frontier
   become servable as it advances (background, jump, or find), then re-issuing the window serves them.
6. **Source-row mapping.** For any filtered row currently servable, the core reports its **original
   (unfiltered) data-row number** (for the gutter). Total/zero-alloc, same window/borrow rules as cells.
7. **Jump under a filter.** `go to N` interprets `N` as an **original data-row number**: the jump advances
   the filter-scan (if needed, with progress) to the **first matching row whose original index ≥ N**
   (clamped to the last match at/after EOF), and reports that row's **filtered index** as the landing row.
   Behind the frontier it completes without a scan (as jumps do today).
8. **Find within a filter.** While filtered, `ls_search_*` evaluates the find predicate **only over rows
   that satisfy the filter**; `total`/`position` count rows satisfying **both** predicates, `found_row` is
   a filtered index, and navigation (first/next/prev, wrap) moves within the filtered view. Counts are
   exact for the scanned region and converge with progress, exactly as Find does today. The filter and
   find scans share the single slot per requirement 4.
9. **Reset semantics.** Setting a filter, clearing a filter, and a dialect/encoding re-open each reset any
   active find (new coordinate space); a re-open additionally clears the filter.

**App UX (macOS)**
10. **Define/apply via the Find popup.** The existing Find popup (Text | Where) gains an **"Apply as
    filter"** action: you compose a predicate as you do for Find, then apply it as the active filter view.
    No new predicate UI is introduced (the grammar is identical).
11. **Filtered banner.** While a filter is active, a persistent, unobtrusive indicator shows **"Filtered —
    N of M rows"** (N = matching rows, converging with a scan % until the filter-scan completes; M = total
    document rows) plus a **Clear (✕)** affordance. Clearing is also available from the Find popup.
12. **Find-within-filter is just Find.** With a filter active, running Find searches within the filtered
    rows (requirement 8); the match count and "match n of k" read within the filtered view.
13. **Gutter shows original numbers.** The row-number gutter displays each matching row's **original
    (unfiltered) row number** (non-contiguous under a filter), via requirement 6 — not a 1..m position.
14. **Jump box takes original numbers** (requirement 7): the number the user types matches the numbers on
    screen; it lands on the nearest matching row at-or-after it.
15. **Clear re-anchors.** Clearing the filter lands the grid on/near the **source row of the top visible
    filtered row**, keeping the user's place (reusing the header-toggle re-anchoring already implemented),
    rather than resetting to row 0.
16. **Empty / scanning states.** Zero matches (scan complete) shows an empty grid with "no matching rows";
    a still-scanning filter shows progress and the rows found so far. Cold-start and the unfiltered view
    are unaffected when no filter is set.

## Non-functional constraints
- **Cold start < 500 ms is unaffected** — a filter is opt-in after open; setting one is O(viewport) to the
  first matching rows + a background scan, never O(file) up front, never UI-blocking.
- **Memory O(index checkpoints) per filter** — per-block counters, never a match-row list; a filter over a
  10 GB file with millions of matches uses the same bounded memory as the base index. Window memory stays
  O(viewport) in filtered coordinates.
- **Filter-scan cost is paid once** — it advances and feeds the shared base index; re-deriving a filtered
  window behind the frontier is O(window) re-lex + O(checkpoints) counting, safe on the UI thread.
- **No silent stalls** — every filter-scan, jump, and find shows constant progress and is cancellable; the
  single scan slot's contention is observable (states/progress), never a freeze.
- **Read-only** — filtering selects rows for display; the source file and base parse are never modified.
- **ABI**: additions only (filter set/clear, filter status poll, source-row accessor, and the documented
  coordinate reinterpretation of the existing accessors while a filter is active). No existing signature
  changes.

## Component decomposition & data flow
- **`api/lesssheet.h` (root planner)** — new surface: set-filter (from an `ls_search_request`), clear-
  filter, a filter status poll (state / progress / converging count, analogous to `ls_search_status`
  without a nav slot), and a filtered-row → source-row accessor. Plus documented prose that, while a
  filter is active, the row-addressing accessors and jump/find operate in filtered coordinates (with the
  jump-target-as-original-row and find-within-filter semantics above). One filter per document.
- **`backend/` (Zig core)** — a **filter layer** over the existing scan/index machinery: reuse the
  find-seek per-block match counters to (a) count `m`, (b) map filtered index ↔ source row, (c) materialize
  a filtered window by counting into blocks then re-lexing the needed source rows. The filter-scan is the
  existing frontier-advancing match-scan, tallying filter matches; jump/find while filtered layer their
  logic over the filtered index. `root.zig` is the implementation area.
- **`apps/macos/` (Swift)** — `Contracts`: a filter request/state mirror + the source-row mapping on the
  row window. App: the Find popup's "Apply as filter" action, the filtered banner (N of M + Clear), the
  gutter switching to source row numbers, the jump box interpreting original numbers while filtered, and
  clear re-anchoring. The grid otherwise addresses rows 0..N-1 exactly as today (in-place remap ⇒ minimal
  churn).
- **Data flow (set filter)**: predicate → validate (as Find) → enter filtered mode → filter-scan advances
  the shared frontier, tallying per-block match counts → grid polls count/progress and window-sets in
  filtered coords → cells + source row numbers served as matches are found. **Clear**: capture the top
  visible filtered row's source row → clear mode → re-anchor the identity view near that row.

## External interfaces
- The C ABI in `api/lesssheet.h` is the only cross-component surface; the additions above are frozen by the
  root planner pass. The Swift `Contracts` types mirror the new calls/fields.

## Acceptance criteria (each testable)

**Filter view & addressing**
1. With no filter, all accessors behave exactly as today (identity view unchanged; a regression guard).
2. Setting a WHERE filter (`col = "error"`) makes `ls_row_count_get` report the number of matching rows
   (converging, then exact), and `ls_window_set`/`ls_cell` over `[0, m)` serve the matching rows' cells in
   file order — verified against a fixture with known matches interleaved among non-matches.
3. Setting a TEXT filter (substring over a column scope) yields the rows containing the substring in-scope;
   the same smart-case rules as Find apply.
4. Clearing the filter restores the identity view: row count = full document count, row `i` = physical data
   row `i` again.
5. An invalid filter request (empty TEXT; out-of-range column/scope; non-numeric value for `< > ≤ ≥`) is
   rejected and leaves the current view unchanged (same rejection as `ls_search_start`).
6. A filter matching zero rows yields a filtered view of exactly 0 rows (row count exact 0 once scanned).

**Scan, progress, memory**
7. Setting a filter returns without scanning the whole file: the first screen of matching rows is servable
   O(viewport), and the filter status reports scanning with monotone progress until done (then `total`
   exact). Setting a filter on a multi-GB file stays within the cold-start budget to first matching rows.
8. The filter uses O(index-checkpoint) memory: a filter over a large fixture with a very large match count
   does not allocate memory proportional to the number of matches (per-block counters, not a row list) —
   asserted by a memory/allocation bound in the test.
9. The filter-scan feeds the base index: after a filter-scan reaches EOF, the base row index is complete
   (bytes scanned for the filter also indexed the document — paid once).
10. Filter-scan / jump / find share the single scan slot: starting a jump while the filter-scan runs takes
    the slot (frontier + match-count gains kept) and the filter **mode persists**; the discovered-match
    frontier never regresses.

**Source rows, jump, clear**
11. For each served filtered row, the core reports its correct **original** data-row number (the gutter
    value) — verified against the fixture's known match positions.
12. `go to N` while filtered lands on the nearest matching row whose original index ≥ N (and clamps to the
    last match past EOF); the reported landing is that row's filtered index, and its gutter shows an
    original number ≥ N (or the last match's number when clamped).
13. Clearing the filter re-anchors the identity view on/near the source row of the top visible filtered row
    (not row 0).

**Find within a filter**
14. With a filter active, a Find (TEXT or WHERE) matches only rows that satisfy **both** predicates;
    `total`/`position` count within the filtered view, `found_row` is a filtered index, and next/prev/wrap
    navigate within the filtered view.
15. Setting or clearing a filter, and a dialect/encoding re-open, reset an active find (poll returns idle /
    the search is cleared); a re-open also clears the filter.

**App UX (macOS)**
16. The Find popup offers "Apply as filter"; applying it enters the filtered view and shows the "Filtered —
    N of M rows" banner with a working Clear (✕); N converges with a scan % until complete.
17. The row-number gutter shows original (non-contiguous) row numbers while filtered; the jump box accepts
    those original numbers (criterion 12).
18. Running Find while filtered searches within the filtered rows and the count reads "match n of k" within
    the filter (criterion 14); an empty filter result shows "no matching rows"; clearing keeps the user's
    place (criterion 13).

## Open Questions
None. (Resolved in the design interview: in-place document-mode remap — one filter at a time, reusing the
existing accessors in filtered coordinates; a single `ls_search_request` predicate — compound AND/OR
deferred; Find composes within the active filter; the gutter shows original row numbers via a source-row
accessor; jump interprets the target as an original row number landing on the nearest match; clearing
re-anchors near the current row; the filter UI extends the existing Find popup with an "Apply as filter"
action and a "Filtered N of M ✕" banner.)
