# ARCH — thin-frontend-shared-core (move platform-neutral data-logic DOWN behind the C ABI)

**Feature:** reduce cross-frontend duplication by moving PLATFORM-NEUTRAL *data-logic* out of the Swift
frontend and DOWN into the shared Zig core behind the frozen C ABI, so a future Linux/GTK frontend — and
any frontend — REUSES it instead of re-implementing. The macOS frontend shrinks toward widgets + event
wiring + platform rendering. This is a **surgical, incremental** delta on an already well-layered
codebase, not a rewrite.

**Read first:** the frozen `api/lesssheet.h` (borrow rules, result-enum + job-handle idioms, the
`LS_BYTES_TOTAL_UNKNOWN` additive-amendment precedent), `backend/src/matcher.zig` +
`backend/src/search.zig` + `backend/src/window.zig` (the match/window machinery the additions ride),
`apps/macos/Sources/LessSheetKit/FindLogic.swift` (`CellMatcher` — the byte-identical duplicate to delete)
and `SelectCopyLogic.swift` (`TSVCopyBuilder` — the per-cell copy loop to delete),
`apps/macos/Sources/LessSheetApp/ViewerModel.swift` (`highlights(...)`, `copySelection(...)`),
`docs/architecture/ARCH-select-copy.md`, `ARCH-column-windowing.md`, `ARCH-find-seek.md`. Project brief:
`docs/architecture/PROJECT.md`. Interview decisions with the author (2026-07-15) are pinned in **Technology
decisions** below — do not re-litigate.

---

## Problem (survey-confirmed)

The frontend is ALREADY cleanly layered: ~17 pure value-transform collaborators (`Contracts` protocols +
`LessSheetKit` impls) hold the "logic," isolated from AppKit and pinned by frozen tests. But that reuse is
**Swift-only** — a Linux/GTK frontend must re-port all of it. Meanwhile the Zig core ALREADY owns nearly
all the heavy data machinery (text + typed-predicate matching, incremental search with match counting and
nav, persistent filtered views, windowed row access, jump/scan, dialect sniffing, column-type inference).

So most "candidates to move down" are either (a) genuine DUPLICATES of core logic, or (b) presentation/UX
glue that is correctly per-frontend. The survey found exactly two concerns worth moving — and the line is
sharp:

- **The cell matcher is a deliberate, acknowledged byte-identical DUPLICATE of `matcher.zig`**
  (`FindLogic.swift` `CellMatcher` + its private exact-decimal `Decimal10`), pinned by a frozen
  cross-check fixture. It exists only to paint viewport highlights without an ABI round-trip. Pure waste:
  the same KMP + exact-decimal grammar lives twice, and every future frontend would triple it.
- **Selection copy is O(document) per-cell FFI.** `TSVCopyBuilder` drives an injected fetch closure that
  calls `ls_cell_copy` once PER CELL; because each call re-locates from an index checkpoint independently,
  a 100k×3 copy was measured at **~80 s** off-main. The TSV framing/quoting also duplicates per frontend.

Everything else the frontend "logic" does — the Find/Filter/Jump control state machines, poll-fold,
`WindowPoll`, column layout / pixel-width math, `SelectionModel` rect algebra, `DialectComposer`, the
column-config reducers, and ALL number/date FORMATTING and locale RENDERING — is presentation or UX glue
that is correctly per-frontend (event-loop / observation / native-locale coupled). Moving it down would
force the core to hold per-frontend UI session state or reimplement ICU/CLDR, for near-zero reuse payoff.

## Goal & scope

Grow the single frozen `api/lesssheet.h` **additively** by exactly TWO entry points, and re-point the
macOS frontend to them, deleting the two duplicated Swift concerns — in two independently-gated phases:

1. **Phase 1 — match-flags:** a batched per-window match-flags companion call; delete the Swift
   `CellMatcher` + its frozen cross-check fixture. Highlights become a core-computed, memoized,
   O(viewport) signal.
2. **Phase 2 — streaming copy:** a core-framed streaming TSV copy job family; delete `TSVCopyBuilder`.
   Fixes the ~80 s stall and centralizes the TSV quoting.

Each phase: add the ABI, freeze it, implement in the core with a backend behavior test, re-point the
frontend, and land only when the backend gate + the macOS component gate + all inert probes + the root
gate are green. Phase 1 lands before Phase 2 is designed into the tree.

## NON-GOALS (explicit — these stay per-frontend / unchanged)

- **NOT moving down:** the Find / Filter / Jump **control state machines**, the **poll-fold** driver,
  `WindowPoll`, **column layout / width / pixel** math (`ColumnLayout`, `ColumnSizer` — coupled to
  `NSFont` measurement; the core deliberately holds zero pixels), the **selection rect algebra**
  (`SelectionModel` — trivial, event-coupled), `DialectComposer`, and the column-config reducers
  (`SettingsLifecycleReducer`, `ColumnDiscovery`, `ColumnSessionModel`, `ColumnPanelLayout`). They are the
  frontend's thin driver over the core's data ABI — presentation/UX, not data.
- **NOT adding a per-cell type / conformance ABI signal.** Per the author's ruling, the core owns
  **column-level** type inference (unchanged `ls_column_*` surface); the frontend derives the per-cell
  "valid int/date? formatted vs. raw?" **render** decision from the column type + the cell bytes.
- **NOT moving formatting / locale rendering down.** All number/date formatting, thousands separators,
  date formats, alignment, and the displayed string stay client-side, on each platform's native locale
  stack.
- **NOT moving the search-WRAP policy down.** Wrap ("after the last match, loop to the first") stays a
  per-frontend UX affordance; the core reports `LS_SEARCH_NAV_EXHAUSTED` and navigates from any anchor.
- **NOT building the Linux/GTK frontend.** This feature only makes the shared surface reusable; the second
  frontend is slice 8, out of scope here.
- **NOT changing any existing ABI semantics.** Additive only (new entry points + new types); no existing
  signature, field, or behavior changes.
- **NOT touching the open / cold-start path.** Both additions are post-open and viewport-scoped.

## NFR constraints (must hold — verified by measurement, not claim)

- **Cold-start < 500 ms and O(viewport) open are UNCHANGED.** Both additions are post-open and read only
  the already-materialized window (match-flags) or a demand-served rectangle (copy). Neither reads the
  whole file or touches the open path. A launch/first-rows probe confirms the budget holds.
- **Match-flags is O(viewport), once per materialize — a per-frame IMPROVEMENT.** Today `CellMatcher` runs
  per visible cell **per repaint** (O(viewport) KMP per frame while a search is active). The new signal is
  computed by the core once per window materialization (O(window rows × visible cols), from bytes it
  already holds in `win_buf`), returned as a borrowed buffer the frontend reads by array-index per repaint
  — **no per-frame per-cell FFI, no per-frame matching.** Recompute only on a window or search change;
  invalidated by the next `ls_window_set` / `ls_close`.
- **Copy streams O(rows-read) with NO main-thread stall.** The in-core row-major sweep reuses the existing
  O(1) forward copy cursor (`copy_cursor_*`) instead of per-cell independent re-location, so the ~80 s
  path drops to a bounded budget. It runs on the caller's background thread (poll/control lane, like
  `ls_cell_copy`); the UI thread never blocks; cancel is prompt.
- **No chatty / O(rows) ABI traffic introduced.** Match-flags is ONE call per materialize; copy is a
  pull-model stream of caller-sized chunks (not one FFI per cell).

---

## Inputs / Outputs — the exact additive ABI shapes (planner freezes signatures + constants)

Both follow the existing header conventions: `ls_str` = borrowed `{ptr, len}` UTF-8, NOT NUL-terminated,
invalidated by the next `ls_window_set` / `ls_close`; rows are 0-based, 64-bit, **view-relative**
(FILTERED indices while a filter is active); cols are 0-based physical column indices; result enums are
distinct stable values; job handles are opaque and core-owned, released exactly once.

### Phase 1 — match-flags companion call

```
ls_str ls_window_match_flags(const ls_doc *doc, uint32_t first_col, uint32_t col_count);
```

- **Purpose:** for the window set by the last `ls_window_set` and the predicate from the last
  `ls_search_start`, report which visible cells match — the exact per-cell verdict the deleted
  `CellMatcher` produced, so the frontend paints highlights with zero matching logic of its own.
- **Return:** a borrowed buffer of **one byte per cell** (value 1 = matches, 0 = does not), row-major over
  the window's materialized rows × the requested column range `[first_col, first_col + col_count)`. Stride
  = `col_count`; total length = `window_row_count × col_count`, where `window_row_count` is the count last
  returned by `ls_window_set`. The frontend indexes `flags[(row − window_first_row) * col_count +
  (col − first_col)]`.
- **`first_col` / `col_count`:** the visible COLUMN window (the same subset the frontend reads via
  `ls_cell`), so the call is O(visible columns), never O(column_count) — matching the column-windowing
  discipline of `ARCH-column-windowing.md`. An empty or out-of-range column range returns the empty
  `ls_str` (len 0).
- **Predicate & scope:** evaluates the ACTIVE `ls_search_request` — for `LS_SEARCH_TEXT`, smart-case
  substring over the request's in-scope columns (a byte is 1 only for an in-scope matching column); for
  `LS_SEARCH_PREDICATE`, the typed comparison on the target column only (1 only there). Byte-identical to
  `matcher.zig`, which already backs `ls_search_*`. A filter changes only WHICH rows the window holds, not
  the per-cell verdict.
- **IDLE / no highlight:** when the search state is `LS_SEARCH_IDLE` (no search since open) the call
  returns the empty `ls_str` — matching the frontend's current "no find request → no highlights". (The
  "current match" strong-highlight needs no flags: the frontend already has `found_row` / `found_col` from
  `ls_search_poll`.)
- **Ownership / cost:** BORROWED like `ls_cell` — the flags buffer is core-owned, invalidated by the next
  `ls_window_set` / `ls_close`; recomputed lazily on the first call after a window or search change and
  memoized until then. ZERO per-call allocation beyond the reused flags buffer; never fails; **never
  scans** (evaluates only already-materialized window cells). One byte per cell, NOT packed bits: the
  window is tiny (O(viewport)); bit-packing would only burden the C/GTK consumer.

### Phase 2 — streaming copy job family

```
typedef struct ls_copy_rect {
    uint64_t first_row;   /* view-relative, filtered-aware (like ls_window_set) */
    uint64_t row_count;
    uint32_t first_col;   /* physical column index */
    uint32_t col_count;
} ls_copy_rect;

typedef enum ls_copy_step {
    LS_COPY_STEP_MORE    = 0, /* wrote *written bytes; more chunks remain — call again */
    LS_COPY_STEP_DONE    = 1, /* wrote the final *written bytes; the selection is complete */
    LS_COPY_STEP_STALLED = 2, /* next row is at/beyond the frontier; nothing written — advance the
                               * frontier (ls_jump_start to stalled_row) and retry */
} ls_copy_step;

typedef struct ls_copy_progress {
    ls_copy_step step;
    size_t   written;      /* bytes written into buf this call (<= buf_len) */
    uint64_t rows_done;    /* cumulative selection rows fully emitted (monotone) — progress =
                            * rows_done / rect.row_count */
    uint64_t stalled_row;  /* on STALLED: the view row to jump to; 0 otherwise */
    bool     budget_capped;/* on DONE: true iff the core's safety cap cut the selection short
                            * (mirrors today's TSVCopyBuilder cap) */
} ls_copy_progress;

ls_copy_job    *ls_copy_open(const ls_doc *doc, const ls_copy_rect *rect);
ls_copy_progress ls_copy_next(ls_copy_job *job, uint8_t *buf, size_t buf_len);
void             ls_copy_close(ls_copy_job *job);
```

- **`ls_copy_open`:** starts a pull-model TSV serialization of `rect`. Validates synchronously
  (`first_col + col_count <= ls_column_count`; an empty rect is a valid job that steps DONE with 0 bytes).
  Returns a handle immediately, or NULL only if the handle itself couldn't be allocated. `rect` is copied;
  the caller keeps ownership. The caller MUST `ls_copy_close` exactly once.
- **`ls_copy_next`:** frames the next TSV chunk into the caller's `buf` (up to `buf_len` bytes, cut only at
  a row/field boundary so chunks concatenate to a well-formed whole; never splits a UTF-8 code point) and
  returns progress. The core owns the framing: TAB field separator, LF row terminator, spreadsheet quoting
  (a cell containing TAB / newline / double-quote is wrapped in double-quotes with interior quotes
  doubled), and the single-cell-selection raw special-case — all **byte-identical to today's
  `TSVCopyBuilder`** (pinned by the existing copy fixtures). Cells are read losslessly (no
  `LS_CELL_MAX_BYTES` display cap), reusing the O(1) forward copy cursor for the row-major sweep. A row
  at/beyond the frontier yields `LS_COPY_STEP_STALLED` with `stalled_row` (caller advances via
  `ls_jump_start`, waits for DONE, retries) — the same servability model as `ls_cell_copy`.
- **`ls_copy_close`:** releases the job (call exactly once; invalid afterward). Cancel = stop calling
  `ls_copy_next` and close. The job holds NO background thread (it is a pull-model cursor over the caller's
  thread), so close has nothing to join — but it is safe against a concurrent `ls_close` under the same
  discipline as the copy/jump lane today (`copyBufferLock`).
- **Ownership / threading:** `ls_copy_next` COPIES into the caller's buffer (no borrow, no tie to the
  `ls_str` eviction rule); safe on the poll/control lane from any thread concurrently with the window lane
  and background scans — which is what lets a large copy run off the UI thread. Single-consumer per job
  (do not call `ls_copy_next` concurrently on one job).
- **Budget:** the caller bounds total output by choosing when to stop pulling + close; the core
  additionally enforces the same overall safety cap the current builder does (a core constant, pinned by
  the planner from today's value), reported via `budget_capped` on the DONE step.

---

## Functional requirements

1. **Highlights unchanged, sourced from the core.** Find highlights render exactly as today (current match
   strong; every other in-scope matching visible cell subtle; header cells never highlighted), but the
   per-cell verdict comes from `ls_window_match_flags`, not a frontend matcher. TEXT smart-case and
   PREDICATE (eq/ne + exact-decimal ordering) verdicts are byte-identical to the deleted `CellMatcher`.
2. **Selection copy unchanged in output, fixed in cost.** Cmd+C on a rectangular selection writes TSV to
   the pasteboard byte-identical to today (ordering, quoting, single-cell raw, cap/truncation), but built
   by streaming `ls_copy_*` on a background thread with no per-cell FFI and no main-thread stall.
3. **Filter / search / jump orchestration, formatting, layout, selection, and dialect handling stay
   entirely on the frontend** and behave exactly as before (they are non-goals; the change must not
   perturb them).
4. **Additive-only ABI.** Existing entry points, types, and semantics are untouched; only the two new
   entry points (+ the copy types) are added, frozen by the two-key root-planner amendment.

## Component decomposition & data flow (reused / added / deleted / re-pointed)

**Backend (Zig core):**
- *Reused:* `matcher.zig` (the exact per-cell match already backing `ls_search_*` — Phase 1 exposes its
  verdict over the window); `window.zig` / `win_buf` (the materialized window Phase 1 reads); the O(1)
  forward copy cursor and lossless per-cell decode already behind `ls_cell_copy` (Phase 2's sweep).
- *Added:* `ls_window_match_flags` (Phase 1) computing a per-window flag byte buffer over `win_buf` using
  the active search predicate; the `ls_copy_*` job (Phase 2) framing TSV over a demand-served rectangle.
  Each with a backend behavior test.
- *Unchanged:* `ls_column_*` type inference, dialect sniff, filter/search/jump execution.

**API (`api/lesssheet.h`):** the two additive entry points + the copy types, frozen by the root planner
(the `api/` component's only owner) — the `LS_BYTES_TOTAL_UNKNOWN` amendment is the precedent.

**Swift binding (`Sources/CLessSheet` + `Sources/LessSheetKit/CoreDocumentSession.swift`):** additive
wrappers — a `windowMatchFlags(firstCol:colCount:) -> [UInt8]` (copied out of the borrow immediately, per
the existing UTF-8-copy-out discipline) for Phase 1; a streaming `copy(rect:)` API driving
`ls_copy_open/next/close` (append chunks, handle STALLED via the existing jump primitives, report
progress) for Phase 2.

**Frontend (`Sources/LessSheetApp/ViewerModel.swift`):** `highlights(...)` re-points from
`cellMatcher.matches(...)` to reading the flags buffer (Phase 1); `copySelection(...)` re-points from the
`TSVCopyBuilder` + per-cell fetch closure to the session's streaming copy (Phase 2). The pasteboard write,
progress/cancel/notice lifecycle, and off-main dispatch are unchanged (platform).

**Deleted (frozen-path removals — planner-executed as part of pinning each phase):** Phase 1 — the
`CellMatcher` impl (`FindLogic.swift`), its private exact-decimal matcher, the `CellMatching` protocol +
the matching `NumericGrammar` in `Contracts/FindControl.swift`, and the frozen cross-check fixture. Phase 2
— the `TSVCopyBuilder` impl (`SelectCopyLogic.swift`), the `CopyBuilder` protocol in `Contracts`, and its
frozen fixture (its behavior is re-pinned by the byte-identical copy AC + the backend behavior test).

## External interfaces

- **New `ls_*` entry points:** `ls_window_match_flags` (Phase 1); `ls_copy_open` / `ls_copy_next` /
  `ls_copy_close` + `ls_copy_rect` / `ls_copy_step` / `ls_copy_progress` (Phase 2). Signatures + the copy
  safety-cap constant are frozen by the root planner.
- **Swift `Contracts` / `CLessSheet` binding:** additive `DocumentSession` methods mirroring the two calls;
  removal of the now-redundant `CellMatching` / `CopyBuilder` protocols + fixtures (frozen change).
- No other component, dependency, or manifest changes.

---

## Technology decisions (DECIDED with the author 2026-07-15 — rationale + alternatives; do not re-litigate)

1. **One ABI, grown additively — not a second shared library.** The moved concerns need data the core
   already holds in-process (cell bytes, the live window buffer, the search predicate); a separate
   UI-logic lib would just call back into the core (a needless layer) and double the freeze/gate/contract
   machinery. *Alternative rejected:* a distinct `lessview` static lib. *Mechanism:* a two-key
   root-planner ADDITIVE amendment, following the `LS_BYTES_TOTAL_UNKNOWN` precedent.
2. **Per-cell type = CLIENT-CLASSIFIES; the core stays presentation-free.** The core owns **column-level**
   type inference (reading a column's bytes → Int/Double/Date/Text — unchanged `ls_column_*`). The
   frontend derives the per-cell "is this cell a valid int/date? show it formatted vs. raw?" RENDER
   decision from the column type + the cell bytes, and does all formatting/locale rendering natively.
   *Accepted trade-off (the author's deliberate choice, noted once):* each frontend re-derives the small
   per-cell parse/round-trip rule — a minor, intentional duplication, the price of a fully
   presentation-free core. *Alternative considered:* CORE-CONFORMANCE (a per-cell type-byte companion
   call) — declined to keep the core free of any presentation concern.
3. **Highlights via a batched per-window match-flags call — not per-cell FFI.** One byte per visible cell,
   computed once per materialize from bytes the core already holds, memoized across repaints, borrow-freed
   on the next window/close. This deletes the byte-identical Swift duplicate + fixture and *improves*
   per-frame cost (array read vs. per-cell KMP). *Alternative rejected:* a stateless `ls_cell_matches`
   per-cell FFI (per-repaint per-cell traffic, against the O(viewport)-not-per-frame budget). *One byte
   per cell, not packed bits* — the window is tiny; bit-twiddling would only burden the C/GTK consumer.
4. **Copy = core-framed streaming (`ls_copy_open/next/close`).** Fixes the ~80 s/100k-row stall (in-core
   O(1) copy cursor vs. per-cell independent re-location) AND removes the per-frontend TSV-quoting
   duplication (the feature's whole point). Pull-model, caller-owned buffer, cancel-by-stop, progress from
   rows-done/rect-rows. *Alternative considered:* bulk-raw cells (frontend frames TSV) — rejected because
   it re-duplicates the fiddly Excel/Numbers quoting per frontend.
5. **Search-wrap stays a per-frontend UX policy.** The core reports `LS_SEARCH_NAV_EXHAUSTED` and can nav
   from any anchor; wrap is ~3 frontend lines and keeping it out avoids baking a UX choice into the data
   ABI (a frontend may want wrap-off or a two-step). *Alternative rejected:* a core-side wrap flag on nav.
6. **Safe incremental phasing, matcher first.** Two independently-gated phases; Phase 1 (match-flags) is
   the smallest ABI and lowest risk (one read call, no lifecycle) so it freezes first; Phase 2 (the copy
   job family) touches the known-slow path and lands gated on a perf measurement. *Alternative
   considered:* copy first (fix the live stall sooner) — coupling is near-zero either way; matcher-first
   chosen (per the author) for the simpler first freeze.

---

## Acceptance criteria (testable — GROUPED BY PHASE)

### Phase 1 — match-flags (delete `CellMatcher`)

1. **Byte-identical verdicts.** For every row in the current window and every column in the requested
   range, `ls_window_match_flags` reports 1 iff the cell satisfies the active `ls_search_request` —
   byte-identical to the verdicts the deleted `CellMatcher` produced, verified across the existing
   find/filter fixture matrix: TEXT smart-case (ASCII fold only when the query has no ASCII uppercase;
   bytes ≥ 0x80 exact), PREDICATE eq/ne (byte-exact, empty value legal), and ordering ops with the
   exact-decimal edge cases (`"2.0" == "2"`, `"1e2" == "100"`, 40-digit ints ordered correctly,
   `"1e400" > "1e399"`, non-numeric cell never matches an ordering op). Backend behavior test + a bridge
   test over the former cross-check matrix.
2. **Scope respected.** TEXT flags 1 only on in-scope columns containing the substring; PREDICATE flags 1
   only on its target column — byte-identical to the matcher.
3. **IDLE → empty.** With no active search (`LS_SEARCH_IDLE`), the call returns the empty `ls_str` and the
   grid shows no highlights — matching today's "no find request → `.none`".
4. **Column-windowed & bounded.** The call is O(window rows × requested cols), never O(column_count); an
   empty/out-of-range column range returns the empty `ls_str`. A wide-doc (e.g. 100k-col) probe confirms
   no O(column_count) cost when a search is active.
5. **Borrow discipline & recompute cadence.** The flags buffer invalidates on the next `ls_window_set` /
   `ls_close`; it is computed once per window materialization (or search change) and reused across
   repaints — an inert probe asserts one flags fetch per materialize (NOT per repaint) and no per-cell
   match FFI. Repaint stays O(viewport) with no per-frame matching.
6. **Duplicate removed.** The Swift `CellMatcher`, its exact-decimal matcher, the `CellMatching` protocol +
   matching `NumericGrammar`, and the frozen cross-check fixture are gone; the frontend derives highlights
   solely from the flags buffer.
7. **No regression.** `FindProbe`, `FindEscapeProbe`, `FrameDump`, `FilterRepaintProbe`,
   `RepaintAuditProbe` and the rest stay green; cold-start < 500 ms and O(viewport) open unchanged
   (launch/first-rows probe). Backend gate + macOS component gate + root gate all pass; the `api/`
   addition is frozen by the root planner with its backend behavior test.

### Phase 2 — streaming copy (delete `TSVCopyBuilder`)

1. **Byte-identical TSV.** For every selection rect in the existing copy fixtures, the concatenated
   `ls_copy_next` chunks equal today's `TSVCopyBuilder` output byte-for-byte — TAB/LF separators,
   spreadsheet quoting (quote cells with TAB/newline/quote; double interior quotes), the single-cell raw
   special-case, lossless cells (no display cap), and the safety-cap/`budget_capped` behavior. Backend
   behavior test + a bridge test over the copy fixtures.
2. **Perf fixed, no stall.** The former ~80 s / 100k-row×3 copy completes within a bounded budget (exact
   ceiling pinned by the planner from a measured baseline — target ≪ the old ~80 s), with the UI thread
   never blocking (copy runs on the caller's background thread) — verified by `SelectCopyProbe` / a
   copy-latency probe. Bounded by the in-core O(1) copy-cursor sweep, not per-cell re-location.
3. **Streaming, cancel, progress.** Chunks concatenate to a well-formed whole (boundary-cut, never a split
   code point); `rows_done` increases monotonically toward `rect.row_count`; cancelling mid-stream (stop +
   `ls_copy_close`) leaks nothing and is safe against a concurrent `ls_close`.
4. **Frontier stall handled.** A selection extending past the scan frontier yields `LS_COPY_STEP_STALLED`
   with `stalled_row`; the frontend advances via `ls_jump_start`, then resumes and completes — verified on
   a copy whose range crosses the frontier.
5. **Duplicate removed.** `TSVCopyBuilder`, the `CopyBuilder` protocol, and its fixture are gone; the
   per-cell `ls_cell_copy` selection-copy loop is replaced by the streaming call; the pasteboard write +
   notice/cancel lifecycle are unchanged.
6. **No regression.** `SelectCopyProbe` and all other probes stay green; cold-start / landing / steady
   memory unchanged; backend gate + macOS component gate + root gate all pass; the `api/` copy addition is
   frozen by the root planner with its backend behavior test.

---

## Contract surface (planners freeze) — MULTI-COMPONENT, TWO PHASES

- **ROOT `api/lesssheet.h` + `backend/contracts`:** Phase 1 — `ls_window_match_flags`. Phase 2 —
  `ls_copy_open` / `ls_copy_next` / `ls_copy_close` + `ls_copy_rect` / `ls_copy_step` /
  `ls_copy_progress` + the copy safety-cap constant. Root-planner additive amendment per phase; backend
  implements + a backend behavior test per addition.
- **macOS `apps/macos/Sources/Contracts` + `Tests`:** Phase 1 — additive `DocumentSession` match-flags
  method; REMOVE the `CellMatching` protocol + matching `NumericGrammar` + cross-check fixture. Phase 2 —
  additive streaming-copy `DocumentSession` method; REMOVE the `CopyBuilder` protocol + fixture. Frozen
  tests re-pinned to the byte-identical ACs.
- **Frontend impl (`Sources/LessSheetApp` + `Sources/LessSheetKit` + `Sources/CLessSheet`):** the binding
  wrappers, the `highlights(...)` / `copySelection(...)` re-points, and deletion of the `CellMatcher` /
  `TSVCopyBuilder` impls.
