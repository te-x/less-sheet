# ARCH — window-budget

**Feature:** bound the total synchronous work of window materialization and prove or repair the
filtered-navigation lane over giant rows. **Type:** P0 responsiveness safety repair spanning `backend/`
and the existing macOS polling flow. `api/lesssheet.h` remains byte-identical.

**Agreed decisions:** the author approved the short-range result shape, a fixed 8 MiB charged-work ceiling,
the existing 100 ms poll/loading-placeholder flow, and inclusion of the filtered-navigation proof and
conditional repair in this feature.

## Problem & scope

`ls_window_set` is the synchronous window lane used from the UI thread. The existing
`LS_WINDOW_ROW_SCAN_MAX_BYTES` limit bounds one row to 1 MiB of source scanning, but the public window
limit is 4096 rows. The current worst-case synchronous work is therefore approximately 4 GiB
(4096 × 1 MiB), before accounting for filtered-window passes that visit the same source bytes more than
once. That violates the project rule that potentially long work never silently blocks the UI and that
work approaching 500 ms exposes loading or progress.

This feature makes one `ls_window_set` call consume at most 8 MiB of charged source work. It returns the
completed contiguous prefix immediately and leaves the requested suffix pending. Repeating the identical
request resumes retained work and grows that prefix monotonically rather than evicting it and re-scanning
from the beginning. Moving to a different row window retains the existing eviction behavior.

The feature also closes backlog item #6. Search navigation over an already-counted filtered region still
uses synchronous full-row re-lexing in `backend/src/nav.zig` (`relexBlock` and `countInBlockUpTo`), reached
from `ls_search_nav` through `backend/src/search.zig`. One checkpoint block contains up to 2048 rows, so a
giant-row file has no useful synchronous time or work bound on this lane. The feature first commits a
timing/work-bound proof. If the proof is red—either measured work crosses the responsiveness limit or no
finite synchronous upper bound exists—exact navigation resolution moves off-main and reports the existing
`LS_SEARCH_NAV_SEARCHING` state until it resolves.

### In scope

- A fixed aggregate charged-work ceiling for identity and filtered `ls_window_set` paths.
- Request-local continuation state that preserves completed rows and forward progress across identical
  calls, including progress made while locating the first requested row.
- The existing short `ls_row_range` as the only budget-pending result signal.
- The macOS model's existing 100 ms poll loop as the retry driver even after indexing is complete.
- The existing static per-cell loading placeholder for requested rows outside the returned prefix.
- A measured and instrumented proof for filtered Find navigation across giant rows and a conditional
  off-main repair using the existing search worker/state model.
- Preservation of identity/filtered view semantics, borrow validity, eviction, oversized-row signaling,
  cell truncation, exact full-cell matching, and current landing behavior.

### Non-goals

- No C ABI addition, layout change, symbol, aggregate-budget constant, pending flag, or notification in
  `api/lesssheet.h`.
- No use of `ls_row_oversized` for aggregate-window exhaustion. It continues to mean only that a present
  row exceeded the existing 1 MiB per-row source-scan cap and was served as a bounded row prefix.
- No change to `LS_WINDOW_ROW_SCAN_MAX_BYTES`, `LS_CELL_MAX_BYTES`, `LS_WINDOW_MAX_ROWS`, matching
  semantics, row-count estimation, checkpoint density, scroll-buffer size, or file-format behavior.
- No percentage calculation or new spinner for window completion. Missing visible cells already supply
  continuous loading feedback.
- No full-row match decision from a bounded prefix. Filter and Find continue to inspect complete cells.
- No new background worker, process, runtime dependency, persistent cache, or copied source file.
- No attempt to make pathological input finish quickly in total; it must remain responsive while making
  monotone progress.

## Inputs / Outputs

### Window input

The input remains the existing document handle, 0-based view-relative `first_row`, and unsigned requested
row count. The row count remains clamped to `LS_WINDOW_MAX_ROWS` (4096). With a filter active, row
coordinates remain filtered-view coordinates. Empty documents, zero-row requests, out-of-range starts,
and arithmetic edge cases retain their current total-function behavior.

An **identical request** has the same document generation, view/filter generation, `first_row`, and
clamped row count as the retained request. A filter set/clear, document reopen, or different row range is
a different request. Frontend-only column selection does not alter the core row request and does not
invalidate its row continuation.

### Exact byte/work model

The two synchronous limits are independent:

| Limit | Amount | Applies to | Observable result when reached |
|---|---:|---|---|
| Existing per-row scan cap | 1 MiB = 1,048,576 source bytes | One row materialized for display | That present row is a bounded row prefix and `ls_row_oversized` is true. |
| New aggregate window cap | 8 MiB = 8,388,608 charged source-byte visits | All synchronous source work performed by one `ls_window_set` call | Only completed rows are returned; the remaining window suffix is pending. No row is marked oversized merely because this cap was reached. |

One charged-work unit is one source byte visited by synchronous window work. A byte is charged every time
it is visited, not once per distinct file offset. Consequently:

- bytes walked while advancing from a regular or post-oversized checkpoint to the requested row count;
- bytes tested while locating filtered matches;
- bytes visited again while materializing a matching row for display; and
- any other synchronous Reader/Source replay or repeated parse pass needed by the window request

all consume the same call's budget. A filtered row visited once for its match test and again for display is
charged twice. Checkpoint-skip work is charged even when the call returns no new row.

For mmap CSV, source bytes are the mapped CSV byte stream after the existing leading-BOM treatment. For
gzip CSV, they are logical inflated source bytes, consistent with the existing per-row cap; physical gzip
progress remains on its existing separate axis. Accounting occurs at Reader/Source operation or span
boundaries so the mmap specialization continues to expose direct immutable spans: the meter must not copy
the mapping, wrap every byte in a new dispatch layer, or replace the direct lexer path.

The 8 MiB amount is a hard maximum, not a target that every call must consume. Work already completed and
retained by an identical prior call is not charged again. If the budget expires inside work that cannot be
published as a complete row, that row is not appended and is not mislabeled oversized. The continuation
retains the furthest safe parsing/location state available. At most an unfinished boundary operation may
be restarted; completed returned rows and completed checkpoint-to-target advances are never restarted.
The existing 1 MiB per-row ceiling ensures a fresh call can finish any bounded display-row pass, while
filtered multi-pass state may carry the completed test decision into the next call before display
materialization.

### Window output

The output remains the existing contiguous `ls_row_range` beginning at the requested `first_row`.

- A full result means every currently servable requested row, up to the request clamp or exact end of
  view, was materialized.
- A short result is the completed prefix. Its suffix may be waiting for the scan/filter frontier, the
  aggregate work budget, or both. The distinction is intentionally not exposed because the caller action
  and user presentation are identical: show loading and retry.
- Budget exhaustion is not an error and does not create a synthetic blank row.
- A row is added only after its normal cells, cell-truncation flags, source-row mapping, and oversized flag
  are internally consistent.
- Existing best-effort allocation failure behavior remains a short result; no new error status is added.

For repeated identical requests, returned `row_count` is monotone non-decreasing. Some calls may advance
an internal source/match cursor without increasing `row_count`, for example while crossing non-matching
rows before the first requested filtered row. Such calls must still retain their advanced continuation;
they may not re-scan the same completed prefix indefinitely. Given unchanged finite input, sufficient
memory, and a frontier that reaches the relevant rows, retries eventually fill the requested range or an
exact row count proves its suffix is beyond the end of the view.

### Navigation input and output (#6)

Find/filter requests, anchors, directions, filtered coordinates, full-cell semantics, exact 1-based match
position, and cancellation/replacement rules remain unchanged. The proof exercises `ls_search_nav` when
the filter and Find counted regions already include giant rows in the target checkpoint block.

If synchronous resolution is not provably bounded below the responsiveness threshold, the call returns
promptly with the existing navigation state `LS_SEARCH_NAV_SEARCHING`. The existing poll surface later
reports the same exact `FOUND` or `EXHAUSTED` outcome the synchronous path would have produced. A match in
a giant row's tail remains a match even when the display window can show only its bounded prefix.

## Functional requirements

1. Every identity or filtered window call enforces one 8 MiB aggregate budget across all of its
   synchronous source visits, including repeated visits.
2. Aggregate exhaustion publishes only complete rows. It never changes a row's oversized or per-cell
   truncation meaning.
3. The core retains the materialized prefix and request-local continuation for an identical request.
   Each retry either lengthens the prefix, advances the hidden location/match continuation, reaches a
   terminal range, or reports an existing resource failure; it never restarts completed work.
4. A different row request or view generation uses current eviction semantics. If the caller later
   returns to the old range, byte-identical cells are re-derived from the immutable source as today.
5. Every call continues to invalidate prior borrowed `ls_str` values. Retaining internal storage or
   capacity across an identical call does not extend caller borrow lifetime.
6. Background frontier, filter, and search work continues to make rows/matches locatable off-main without
   invalidating the window's borrows. Window retries use newly available frontier state without losing
   their retained completed prefix.
7. The macOS model regards a requested row outside the returned prefix but inside current row-count
   knowledge as pending. Its existing row view draws the existing subtle loading placeholder.
8. The 100 ms poll loop remains active while the desired window is short, even when base indexing is
   complete and no jump/search/filter scan would otherwise keep polling alive. It retries the identical
   desired range and redraws as the prefix grows. It stops retrying when the desired range is filled, an
   exact row count proves the remainder is past EOF, the request changes, or the document closes.
9. Filter matching and Find matching remain full-cell and exact. Neither aggregate window budgeting nor
   the navigation repair may infer a match/non-match from a displayed prefix.
10. The #6 proof covers forward and backward filtered navigation, found and exhausted outcomes, giant
    matching and non-matching rows, and exact filtered row/position calculation.
11. If #6 is red, expensive counted-region resolution runs as resumable search-navigation work on the
    existing worker/single-scan-slot model. Source parsing occurs outside the short document commit lock,
    so a background navigation cannot make polls or `ls_window_set` wait behind a giant-row parse.
12. An off-main navigation obeys existing generations and slot rules: a replacement navigation supersedes
    the old one; search cancellation resolves a pending navigation as currently specified; jumps and
    filters retain their documented contention behavior; stale worker results never publish.

## Non-functional constraints

- **Work:** one synchronous window call performs no more than 8,388,608 charged source-byte visits.
- **Responsiveness:** release `ls_window_set` measurements on the target Apple Silicon host must remain
  below 500 ms in every acceptance fixture and target at most 100 ms. Any measurement at or above 500 ms
  is a hard failure; a target-host result above 100 ms requires recalibration or optimization rather than
  silently increasing the budget.
- **Cold start:** app launch to first visible rows remains below 500 ms. The first window uses the same
  aggregate budget and may return a loading suffix rather than delaying first paint.
- **Landing:** normal viewport and jump landing work remains O(viewport) with the established sub-100 ms
  target-host landing budget. A normal small-row scroll buffer should still fill in one call.
- **Memory:** added retained state is O(materialized window) plus O(1) continuation state. It is never
  O(file rows), O(filtered matches), or O(file bytes). Existing sparse checkpoints and oversized-row
  metadata bounds remain unchanged.
- **Threading:** the caller-serialized window lane and poll/control lane rules remain intact. Heavy #6
  repair work must not hold the mutex across source parsing.
- **Source behavior:** mmap remains read-only and direct-span/zero-copy at the Source seam. Gzip retains
  its existing bounded cache/checkpoint behavior. Source files are never copied, modified, or locked.
- **Correctness:** row order, source-row mapping, quoting/encoding, ragged-row padding, full-cell matching,
  and estimate-to-exact convergence remain byte-for-byte/semantically identical.
- **Dependencies and size:** Zig std and existing platform frameworks only. No production dependency,
  service, IPC, or bundle-size increase beyond the small in-house state and control flow.

## Component decomposition & data flow

### Existing components changed or reused

- **`backend/src/window.zig`** owns the aggregate budget for identity and filtered materialization, stages
  only complete rows, and resumes an identical request from retained progress.
- **`backend/src/base.zig`** owns the document-local request identity, retained prefix metadata, and
  bounded continuation state alongside the existing window buffers. It resets that state on window/view
  identity changes and document teardown.
- **`backend/src/reader.zig`, `backend/src/csv_reader.zig`, and `backend/src/source.zig`** provide bounded
  Reader/Source operations and work measurements at span/operation granularity. The existing mmap direct
  path is reused rather than replaced. Exact implementation names remain planner-owned.
- **`backend/src/nav.zig` and `backend/src/search.zig`** supply the #6 work instrumentation and, if red,
  resumable counted-region navigation using the existing search worker and poll states.
- **Existing frontier/filter/search machinery** remains the sole owner of full-file and full-cell scans;
  every byte it advances still feeds the shared sparse index as today.
- **`apps/macos/Sources/LessSheetApp/ViewerModel.swift`** extends poll continuation/termination to include a
  short desired window independently of index completion and reissues the same desired row request.
- **`apps/macos/Sources/LessSheetApp/NativeGrid.swift`** reuses `rowLoaded` and the current static pending
  placeholder. No new visual state or notification is introduced.
- **Existing Swift `DocumentSession` and `RowWindow` contracts** are reused unchanged: `rows.count` already
  represents the returned contiguous prefix.

### Pending-to-resolved flow

1. The frontend requests its viewport plus scroll buffer.
2. The core compares the row/view identity with its retained window request. A new request evicts and resets;
   an identical request resumes.
3. The window lane spends at most 8 MiB of charged work, appends only internally complete rows, and returns
   the current contiguous prefix.
4. Swift copies the returned cells and existing truncation/oversized flags before the next borrow-invalidating
   call.
5. Visible requested rows outside that prefix have `rowLoaded == false` and draw the existing static
   loading placeholder.
6. The off-main 100 ms poll obtains current frontier/filter/search state. On the main actor it retries the
   identical desired window while that window is short, even if index progress is already complete.
7. The core resumes retained work; the model replaces its copied `RowWindow` with the longer prefix and
   the grid redraws. Polling ends when the range is filled or exact end-of-view is reached.

### Filtered-navigation flow when #6 is red

1. `ls_search_nav` performs only bounded synchronous resolution work.
2. If exact row/position resolution would cross the bound, the existing navigation slot remains
   `LS_SEARCH_NAV_SEARCHING`; no partial or guessed landing is published.
3. The existing search worker resumes the match/location/count state outside the long-held document lock,
   preserving full-cell matching and exact positions.
4. A short locked commit validates the search/filter/navigation generations and publishes `FOUND` or
   `EXHAUSTED`.
5. The existing frontend poll and Find UI observe the terminal state; no new callback or ABI field exists.

## External interfaces

- **C ABI:** `api/lesssheet.h` is unchanged byte-for-byte. The feature adds no exported constant, field,
  flag, enum value, function, or callback. Existing `ls_row_range`, `ls_row_oversized`,
  `ls_index_poll`/`ls_filter_poll`, and `LS_SEARCH_NAV_SEARCHING` carry the complete observable behavior.
- **Window semantics:** callers already must accept a short range and retry after frontier progress. This
  feature adds aggregate-budget exhaustion as another reason for that same short range.
- **Swift surface:** `DocumentSession.setWindow`, `RowWindow`, `ScanProgress`, and Find/filter status types
  are unchanged. Retry policy changes only inside the app model.
- **Files and formats:** no on-disk format, sidecar, preference, cache contract, network interface, or
  source-file mutation is introduced.

## Technology decisions

### 1. Reuse the short range; do not add pending ABI

**Chosen:** a completed row prefix is returned through the existing short `ls_row_range`; its suffix is
pending. `ls_row_oversized` retains its existing, narrower per-row meaning.

**Alternatives considered:** a new per-window flag, per-row pending flags, overloading
`ls_row_oversized`, or a distinct result status. Explicit flags would distinguish budget-pending from
frontier-pending, but callers perform the same action for both and the current macOS model already derives
loading from range membership. They would also change the ROOT-frozen ABI. Overloading oversized would be
incorrect because an absent row has not been measured as oversized.

**Rationale/scope:** preserves ABI stability and semantic clarity with no lost caller capability.
Feature-local; no project-wide stack change.

### 2. Fixed 8 MiB charged-work budget, not an adaptive deadline

**Chosen:** count every synchronous source-byte visit and stop at 8,388,608 units per window call.

**Alternatives considered:** retain only the 1 MiB per-row cap; use a wall-clock deadline; adapt the byte
budget to recent speed; or move every window to a background task. The per-row-only model permits ~4 GiB
per call. Time/adaptive limits are nondeterministic, difficult to freeze in tests, and can change result
shape with host load. Moving all windows off-main adds scheduling and ownership complexity to the product's
most frequent fast path and is unnecessary for ordinary viewports.

**Rationale/scope:** a fixed work ceiling is deterministic, portable across the current Reader/Source
variants, and measurable independently of noisy timing while the wall-clock gate verifies the proxy.
Feature-local; it does not establish a universal budget for unrelated operations.

### 3. Retain a request-local prefix and continuation in the core

**Chosen:** identical calls reuse completed window storage plus bounded cursor/match continuation; changed
requests keep current eviction behavior.

**Alternatives considered:** have the frontend request only the missing suffix, restart the full range on
every poll, or materialize a second complete window on a worker. Suffix requests would make the frontend
merge independent borrow/copy generations and would no longer exercise the existing contiguous-window
contract. Restarting livelocks on the same prefix. A second worker-owned window duplicates memory and
complicates eviction and generation races.

**Rationale/scope:** core retention keeps progress monotone at the layer that owns parsing and borrows,
uses O(window) memory already allowed, and leaves every caller on the established interface.
Feature-local.

### 4. Reuse the 100 ms poll and loading placeholder

**Chosen:** a short desired window keeps the current poll loop alive and the existing static cell
placeholder visible; retries occur at the existing cadence without a callback or percentage.

**Alternatives considered:** a new core notification, a separate window timer, a global progress bar, or
blank cells. Notifications add cross-platform ABI/concurrency surface. A second timer duplicates polling
and creates ordering races. A percentage has no stable denominator when work includes filtering and
checkpoint skips. Blank cells are indistinguishable from real empty data and violate the no-silent-stall
rule.

**Rationale/scope:** this is the smallest honest feedback loop and already matches frontier-pending UX.
Feature-local macOS behavior; future frontends use the same short-range fact with native scheduling.

### 5. Measure #6 first; if red, reuse asynchronous search navigation

**Chosen:** freeze the actual filtered-navigation timing and work proof first. A red/unbounded result uses
the existing search worker, single scan slot, and `LS_SEARCH_NAV_SEARCHING` state for exact counted-region
resolution.

**Alternatives considered:** always keep synchronous one-block re-lex; store every match row; decide giant
rows from a bounded prefix; add another worker/state enum; or split #6 into a later feature. The current
block can contain too much source work. Match-row lists violate O(checkpoints) memory. Prefix decisions
violate full-cell semantics. Another worker/state expands contention and ABI. Deferral leaves a known P0
responsiveness exposure open.

**Rationale/scope:** measurement prevents speculative changes if a genuine bound already exists, while the
repair path reuses poll behavior callers understand and keeps exact results/memory bounds. Feature-local;
no dependency or project-wide technology choice.

### 6. In-house std-only implementation

**Chosen:** existing Zig Reader/Source, worker, atomics/mutexes, and native Swift/AppKit state only.

**Alternatives considered:** third-party schedulers, parsers, or observability libraries. None supplies a
useful primitive that the existing stack lacks, and each would add licensing, maintenance, size, and hot-
path integration cost.

**Rationale/scope:** required by the current project stack and single-digit-MB/std-only constraint.
Project-wide choice already settled by `PROJECT.md`; this feature introduces no new production technology.

## Acceptance criteria

1. **Frozen external surface.** `api/lesssheet.h` is byte-identical before and after the feature; exported
   symbols, layouts, constants, and enum values are unchanged. The Swift `DocumentSession`/`RowWindow`
   contract files require no new pending field. Root integrity and component gates pass.

2. **Exact 8 MiB accounting.** Test-only instrumentation reports no more than 8,388,608 charged source-
   byte visits for each `ls_window_set` call. Separate identity and filtered fixtures prove checkpoint
   skips are charged, filtered test-plus-display visits are charged twice, and repeated visits to the same
   source offset are not deduplicated. The assertion covers both current mmap and gzip Source paths at the
   logical-source-byte layer.

3. **Short-prefix result.** A request whose rows require more than 8 MiB returns a contiguous range
   beginning at the requested row with fewer rows than requested. Every returned row has correct cells,
   truncation flags, source-row mapping, and oversized flag. The first unreturned row is absent—not a row
   of empty cells—and aggregate exhaustion alone never makes `ls_row_oversized` true.

4. **Monotone retry / no livelock.** With all requested rows behind the frontier, repeated identical calls
   produce non-decreasing returned counts and eventually return the full requested range. Instrumentation
   proves no completed returned row or completed checkpoint-to-target advance is re-scanned. A filtered
   request that spends one or more calls crossing non-matching rows may temporarily return the same count,
   but its internal source/match cursor strictly advances and it eventually produces the next row or proves
   end-of-view.

5. **Eviction and borrows preserved.** A changed row request discards the old continuation according to
   existing eviction rules; returning later yields byte-identical cell text. Every call still invalidates
   previous borrowed strings, including an identical call that reuses capacity. Concurrent background
   index/filter/search progress never invalidates a borrow.

6. **Row and cell caps remain distinct.** A row larger than 1 MiB remains a present bounded prefix with
   `ls_row_oversized == true`; a normal row deferred only by the aggregate budget reports no oversized
   flag until it is actually present. `LS_CELL_MAX_BYTES` truncation flags remain byte-identical. Giant
   filter/search tail matches still use the complete cell and retain existing counts/navigation results.

7. **Pending-to-resolved frontend flow.** In a model test where indexing already reports complete but the
   first window is budget-short, polling continues at no more than 100 ms intervals, reissues the identical
   desired range, and stops only after the range fills or exact EOF is reached. While short, visible missing
   rows have `rowLoaded == false` and configure the existing pending placeholder; after growth they redraw
   with data and `rowLoaded == true`. No new callback, progress percentage, or ABI signal is used.

8. **Window timing bound.** On the target Apple Silicon host, release measurements cover identity and
   filtered windows made of near-cap rows, a large checkpoint skip, a filtered non-match walk, and a
   filtered test/display double pass. Every measured `ls_window_set` call is below 500 ms and the target-
   host acceptance result is at most 100 ms. Work remains capped as fixture row count/file size grows; a
   result above 100 ms is investigated/recalibrated without raising the 8 MiB ceiling, and 500 ms or above
   fails the feature.

9. **Normal-window and landing regression.** A normal small-row macOS scroll-buffer request fills in one
   call. Existing cold start remains below 500 ms; existing normal and huge-row landing probes remain below
   their 100 ms target; window memory stays O(viewport); row order, filtering, source-row gutters,
   truncation markers, and oversized markers are unchanged.

10. **mmap fast path preserved.** Instrumentation/code inspection proves mmap parsing still consumes
    immutable direct spans without a copied source staging buffer or per-byte dynamic dispatch. Plain-CSV
    output is byte-identical, no full-file/page-in work is introduced, and release normal-window throughput
    shows no material regression outside measurement noise.

11. **Committed #6 proof.** A frozen giant-row fixture places matching and non-matching giant rows before,
    inside, and after the target counted checkpoint block under an active filter. It measures synchronous
    charged work and wall time for forward/backward `ls_search_nav`, FOUND and EXHAUSTED, plus exact filtered
    row and 1-based position. The proof varies giant-row length enough to distinguish a bound from linear
    full-row re-lex; a single small fixture or timing assertion without work evidence is insufficient.

12. **#6 pass/fix branch.** If criterion 11 proves a finite synchronous bound with every target-host call
    at most 100 ms and incapable of crossing 500 ms as giant rows grow, the committed proof closes #6
    without speculative behavior changes. Otherwise, `ls_search_nav` returns within the same timing limits
    with `LS_SEARCH_NAV_SEARCHING`, the existing worker resolves off-main, and polling reaches the exact
    FOUND/EXHAUSTED result and position. Tail-only matches remain correct; replacement/cancel/stale-generation
    tests pass; a concurrent window/poll call is not delayed by the worker's giant-row parse.

13. **No dependency or storage expansion.** Dependency manifests and deployed runtime dependencies are
    unchanged. Added state stays O(window) + O(1), teardown releases it, source files remain read-only, and
    no persistent artifact or full decompressed copy is created.

## Open Questions

None.
