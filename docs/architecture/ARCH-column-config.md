# ARCH — column-config

**Feature:** compact, session-scoped column type, visibility, and display-format control for the macOS
viewer.

**Status:** original column-config design shipped; inline-Settings amendment drafted and awaiting explicit
human sign-off.

**Decision dates:** 2026-07-13 (original design); 2026-07-14 (inline-Settings amendment draft).

The 2026-07-14 amendment supersedes the original decision to put column configuration behind a “Configure
Columns…” entry in a separate chromeless panel. Settings is now the sole column-configuration surface. The
underlying type, null, formatting, visibility, width, inference, raw-value, session, and performance semantics
remain unchanged. Existing Swift types and implementation state containing `ColumnPanel` / `panel` keep those
names as internal legacy terminology; they do not imply a second user-visible panel.

This design is a delta on the frozen C ABI in `api/lesssheet.h`, the bounded open/worker pipeline in
`backend/src/{root,base,sniff,encoding}.zig`, the horizontal window in `ARCH-column-windowing.md`, and the
macOS session/grid/settings code. It does not replace their row addressing, borrow rules, raw-cell semantics,
or column-width guarantees.

## Problem & scope

Before column-config shipped, the Settings “Columns” section constructed one SwiftUI checkbox for every column.
It was useful on a small document but violated the established wide-document contract: `wide_100k_cols` must
not create 100,000 controls, copy 100,000 Swift header strings, or infer 100,000 column types before first
paint. The shipped design removed that eager list and placed a bounded, virtualized list plus inspector behind
one “Configure Columns…” entry in a separate sheet. That solved the resource hazard, but it also hid the main
column options behind a second surface. This amendment moves the already-bounded controls directly into the
normal Settings window without restoring an all-column UI for wide documents.

The viewer also needs the shipped stable type metadata and display-format layer so values align and format
consistently and users can correct a guess; this amendment changes where those controls live, not their value
semantics.

This feature adds one compact column-control surface and the format-neutral metadata needed to support it:

- bounded, lazy CSV type inference for only requested column IDs;
- a future-compatible declared/inferred/override/effective type model;
- explicit, per-session type and null-sentinel overrides;
- stable conflict and proposed-revision states;
- display-only number/date formatting and type-based alignment in the macOS frontend;
- the existing visibility and width controls in the same embedded Settings surface; and
- bounded, caller-owned access to metadata and header labels through an additive C ABI.

The following are explicitly out of scope:

- persistence of any column setting, sidecars, extended attributes, source mutation, or cross-session profiles;
- Parquet or any other new reader, despite reserving the declared-type slot for a later feature;
- arbitrary date patterns, timezone conversion, scientific-notation display, currency, percent, duration,
  binary display, or arbitrary-precision numeric formatting;
- manual alignment;
- changing copy, Find, filter, search, or predicate semantics to operate on formatted or typed display text;
- merging Parsing into Columns (Parsing remains its own compact Settings section); and
- replacing the current Reader/Source, row-window, scan-frontier, or column-window architecture.

The inline-Settings amendment additionally does not:

- change the frozen C ABI or the public Swift contracts in `apps/macos/Sources/Contracts/ColumnPanel.swift`;
- add typo-tolerant or relevance-ranked search, a search dependency, persistence, or a header index;
- rename legacy `ColumnPanel` / `panel` implementation symbols merely because the surface moved; or
- expose an unfiltered browsing list when a document has more than ten columns.

## Inputs / Outputs

### Canonical cell input

Type inference and visible-cell validation consume the existing canonical raw cell: transcoded UTF-8 with CSV
quoting removed and the existing column-count truncate/pad rule applied, before any display formatting. The
effective header is never evidence. Source data-row identity is the unfiltered, zero-based data-row number;
filter/view coordinates never change inference identity.

Evidence is accepted only from a complete cell in a completely served row. A cell flagged by
`ls_cell_truncated`, and every cell served from a row flagged by `ls_row_oversized`, is displayed as its raw
served prefix and contributes neither inference nor conflict evidence. This conservative rule prevents a
bounded prefix or synthetic padding from being mistaken for a complete value.

Null matching happens before empty handling and before any type-specific whitespace handling:

1. When a column has a null sentinel, a byte-for-byte match is null. Matching is case-sensitive and preserves
   every whitespace byte. An empty sentinel is valid and is the explicit way to treat empty CSV fields as null.
2. Otherwise, a zero-length field is empty text. It displays blank, contributes no inference evidence, and
   never conflicts with any effective type.
3. Every other complete field is non-empty evidence and is classified by the grammar below.

### V1 type grammar

The base type is one of `unknown`, `unsupported`, `text`, `boolean`, `integer`, `decimal`, `date`, or
`datetime`. Null is an orthogonal cell state governed by the null policy; it is deliberately not a competing
base type. An all-null/all-empty column therefore has an unknown base type plus its null/empty counts.

| Type | Exact v1 recognition rule |
|---|---|
| Boolean | After stripping the same ASCII edge whitespace used by the numeric grammar (bytes `09`–`0D` and `20`), ASCII-case-insensitive `true` or `false`. `0`/`1` and `yes`/`no` are not booleans. |
| Integer | The existing `lesssheet.h` numeric grammar after ASCII edge-whitespace stripping, with no decimal point and no exponent: optional `+`/`-`, then one or more ASCII digits. |
| Decimal | The existing numeric grammar when the token contains a decimal point or exponent: `sign? (digits ('.' digits?)? \| '.' digits) (('e'\|'E') sign? digits)?`. Parsing and comparison remain decimal-string exact; no binary float is used. |
| Date | Exactly `YYYY-MM-DD`, ASCII only, with a valid proleptic-Gregorian calendar date. Whitespace, basic, week, ordinal, and reduced-precision forms are rejected. |
| Datetime | Exactly `YYYY-MM-DDTHH:MM:SS[.1–9 digits][Z\|±HH:MM]`, ASCII only, with valid date, clock, fraction, and offset. Uppercase `T`/`Z` and seconds are mandatory. No zone means naive; `Z` or an offset means zoned. Differing explicit offsets agree as zoned; naive and zoned values do not agree. |
| Text | The deterministic fallback for a non-empty value or a set of values that does not agree on one stricter type. |
| Unknown/unsupported | No eligible evidence, or a future reader/type that this frontend cannot interpret. The original value is always rendered. |

For a sample, all booleans agree as boolean; all integers agree as integer; a mixture of integers and decimals
widens to decimal; dates agree only with dates; datetimes agree only when they have the same naive-versus-zoned
semantics; every other non-empty mixture is text. Candidate selection is independent of traversal timing:
source-row order is primary and requested column ID is secondary.

Decimal metadata records the common exact decimal precision and scale needed by the observed values. Precision
is the count of coefficient digits after exact base-10 normalization; scale is the number of fractional decimal
places and may be negative for powers of ten. Both are computed with the existing exact digit/exponent model,
not Foundation `Decimal`. Datetime metadata records `naive` or `zoned` and the maximum observed fractional
second digit count, from 0 through 9. These are type parameters, not permission to change raw search/copy
semantics. When the existing numeric parser saturates an exponent outside `int64`, precision saturates at
`UINT64_MAX-1` and scale in `[INT64_MIN+1, INT64_MAX]`; the reserved sentinel values are never emitted as data.

### Type and state model

Each touched column has four descriptor slots:

- **declared:** reserved for a future self-describing Reader; absent for CSV v1;
- **inferred:** the current CSV candidate, marked provisional until publishable;
- **override:** the user's explicit type for this logical session; and
- **effective:** resolved as `override > published inferred > declared > unknown`.

An override never destroys inferred/declared metadata. Clearing it returns to Auto immediately. A provisional
candidate is visible to the inspector as “Guessing…” but does not become effective and cannot change alignment
or formatting. `unsupported` is a valid declared/effective fallback that always renders raw.

State orthogonal to those slots comprises:

- inference lifecycle and confidence;
- exact null policy and observed null/empty counts;
- conflict state and a bounded representative example;
- a proposed replacement descriptor, when enough contradictory evidence agrees; and
- per-column and document-global metadata generations.

A **cell conflict** is a complete, non-empty, non-null raw value that does not parse as the published effective
type and its parameters. Text, unknown, and unsupported never conflict. Override conflicts are reported but do
not propose changing the override. The visible cell keeps its original spelling and alignment and receives a
subtle warning with an accessible explanation. “Format unavailable” is separate and is not a type conflict.

For an Auto column, contradictory evidence sets `observed` immediately. A deterministic replacement becomes
`proposed` only after eight distinct eligible source rows agree on the same replacement/widening. The published
effective type does not move. Accepting the proposal replaces the **inferred** descriptor, clears the proposal
and its conflict aggregate, increments the generations, and leaves the column in Auto; it never creates a
hidden override. Rejecting/dismissing a warning leaves the published type unchanged.

### User-authored configuration input

The inspector accepts these session-only inputs:

- Auto or an explicit v1 base type; Reset to Auto clears only the override;
- for an explicit datetime, `naive` or `offset required` semantics (the existing effective semantic is the
  initial selection; absent evidence defaults to naive);
- no null sentinel, or an exact UTF-8 sentinel of 0–256 bytes;
- integer grouping on/off;
- decimal grouping on/off and optional fixed fraction digits from 0 through 38;
- date/datetime display preset: Original, Localized Short, Localized Medium, or Localized Long;
- visibility; and
- the already-existing manual width/auto-fit behavior.

Text, boolean, unknown, and unsupported have no v1 format controls. Decimal precision/scale remain metadata;
fixed displayed fraction digits are a separate frontend setting.

Invalid UTF-8, an over-limit sentinel, an invalid type/parameter combination, or an out-of-range column is
rejected atomically. Allocation failure leaves the previous configuration untouched. The UI explains the
validation error and never partially applies a setting.

### Settings surface input and output

The normal titled Settings window is resizable and is the only column-configuration surface. Its compact,
full-width Parsing section remains above a Columns section. Within Columns, the column discovery area and the
selected-column inspector are side by side and remain simultaneously present; there is no tab, navigation
stack, “Configure Columns…” entry, sheet, or second panel. The window's initial and minimum usable layout must
show Parsing, at least one discovery/result row when one exists, and the selected column's immediate controls
without a disclosure expansion or a transition to another surface.

The inspector exposes these controls immediately:

- Visible;
- Type, including Auto, guessed/effective state, explicit override, and Reset to Auto; and
- only the Number or Date format controls relevant to the selected effective type.

Null values and Width/Auto-fit are two independent advanced disclosures in the same inspector. Both are
collapsed whenever Settings opens; expanding either remains in effect while the user changes selected columns
during that opening. Neither disclosure state is persisted.

Column discovery is determined by the document's logical column count:

- zero columns: Columns shows an empty state and creates no column row, metadata request, or search;
- one through ten columns: the discovery area shows the complete unfiltered list in source-column order and
  does not show a search field;
- more than ten columns: no unfiltered list exists. The inspector still shows the restored/current selection,
  while the discovery area shows a search field and no result rows for an empty query.

A non-empty ordinary search query uses the existing localized, case-insensitive substring match against the
existing searchable label text and returns the first at most ten matches in source-column order. Finding an
eleventh match sets an overflow result and stops the scan; the UI shows “More matches—refine your search” but
neither renders nor retains the eleventh ID after the fixed batch completes. Between batches, search therefore
retains at most ten result IDs plus one Boolean, never all matching labels or IDs; one transient candidate/match
batch remains bounded by the existing 1024-item contract.

An input beginning with `#` is reserved for direct addressing, not ordinary label search. Its entire value must
be `#N`, where `N` matches `[1-9][0-9]*`. A value in `1...columnCount` resolves directly to that one column and
shows it as the sole result row and selection without a label scan; `#0`, a sign, whitespace, non-ASCII digits,
arithmetic overflow, or a value greater than `columnCount` is invalid, leaves the current selection unchanged,
and produces an inline “No such column” result. This direct address keeps every column reachable even when
labels are duplicated and ordinary results are capped at ten. It is frontend routing layered before
`ColumnLabelSearching`, so the approved Swift search contract is unchanged.

### Display output

The core continues to serve raw cells and type metadata; it never serves formatted strings. The macOS frontend
produces display strings as follows:

- Auto formatting preserves the original cell spelling exactly.
- Explicit integer/decimal formatting first parses with Foundation `Decimal` using an invariant decimal locale,
  then compares the parsed value's canonical base-10 spelling with the original under the exact core numeric
  grammar. Only an exact mathematical round trip may be passed to `Decimal.FormatStyle`.
- Grouping follows the system locale captured at logical-session start. Fixed fraction digits use half-even
  rounding. Neither path converts through `Double`.
- A value beyond Foundation Decimal's approximately 38-digit exact range, or any value that fails the exact
  round-trip guard, remains in its original spelling and receives a non-conflict “format unavailable” indicator.
  No in-house or third-party arbitrary-precision formatter is introduced in v1.
- Date/datetime input passes the strict lexical grammar before Foundation ISO/date-components parsing. Naive
  values keep their wall time. Zoned values are formatted in each value's source offset; differing offsets are
  not normalized to the system zone. The localized presets intentionally control presentation; Original keeps
  all source spelling, including 1–9 fractional digits.
- A null sentinel value keeps its source spelling (an empty sentinel remains blank) and may receive the subdued
  null treatment. Empty text remains blank.
- A conflict or truncated/oversized value remains raw. Unknown and unsupported values remain raw.

The logical session captures `Locale.current` once. Internal parse re-opens preserve that locale; explicit
close/open creates a fresh logical session and captures again. This prevents a locale notification or scroll
from silently changing already displayed values.

Automatic alignment is fixed: text/unknown/unsupported left, boolean centered, integer/decimal/date/datetime
right. Conflict cells retain their column's alignment. Headers are always left aligned. No v1 control overrides
these rules.

Copy, Find, search, and filter continue to consume the existing canonical raw value. They never see grouping,
fixed-place rounding, localized dates, null display treatment, or any other display output. Existing exact
full-cell copy and search behavior is therefore unchanged.

## Functional requirements

1. Opening a CSV creates no type-inference job and performs no type-metadata allocation. After the first grid
   column window is known, the frontend requests inference for the union of grid-visible and Settings-visible
   column IDs plus fixed overscan; the latter includes the selected inspector column and only live discovery or
   result rows.
2. The core coalesces duplicate IDs, samples only requested columns, and publishes metadata asynchronously on
   the existing document worker. Untouched CSV columns synthesize an unrequested/unknown snapshot without a
   stored per-column object.
3. The first deterministic sample is bounded by both 256 data rows and `LS_OPEN_HEAD_MAX_BYTES` (4 MiB of
   source). It runs after open by reusing the already-bounded Reader/head region; it does not enlarge or delay
   `ls_open`.
4. Each later materialized-window event contributes at most 256 KiB of decoded complete-cell bytes, visited in
   source-row/column-ID order. Events are coalesced and their queue is bounded; superseded off-screen work is
   discarded rather than accumulated.
5. Inference executes in chunks no larger than 256 KiB and yields at every chunk boundary to jump, Find,
   search, and filter work. It is cancellable. It does not advance the row frontier, await indexing, turn the
   sparse indexer into a cell scan, or scan the whole file merely to raise confidence.
6. A candidate publishes after eight agreeing non-empty, non-null eligible values. When the exact document has
   fewer than eight eligible values and every data row has been examined, it publishes exhaustively after the
   final row. One through seven values remain provisional in every non-exhaustive case; zero values resolve to
   exhaustive unknown only when the document is known exhausted.
7. Before publication, the provisional candidate may evolve deterministically but does not affect display.
   After publication, later scrolling can update evidence/counts/confidence but never silently change the
   effective kind, datetime semantic, alignment, or selected format. Contradictions use conflict/proposal state.
8. Setting/clearing an override changes effective metadata immediately and resets conflict aggregation against
   the prior effective descriptor without discarding inferred/declared slots. Changing the null sentinel resets
   inferred evidence, conflicts, and proposals for that column, then queues fresh inference if it is active.
9. Every metadata commit increments that column's generation and increments one document-global generation
   once for the commit batch. Polling the global value lets the frontend re-query only currently visible IDs;
   it never responds by enumerating all columns.
10. Work that is still active at 500 ms presents “Guessing…” with determinate progress when a finite queued
    sample is known and an indeterminate state otherwise. Cancellation, document close, and replacement
    requests terminate stale work without publishing into a new session.
11. Settings is the sole column-configuration surface. Parsing remains a compact, full-width section above
    Columns. Columns embeds the discovery list/results and selected-column inspector side by side, with both
    visible at once in a wider, resizable normal Settings window. The old “Configure Columns…” entry, separate
    sheet, chromeless shell, Done action, and any tab/navigation transition are removed. A column-header action
    raises this same Settings window and targets its column.
12. The selected-column inspector immediately shows Visible, Type with Auto/guessed/override state and reset,
    and only the relevant v1 Number or Date format controls. Null values and Width/Auto-fit are independent
    advanced disclosures in the same inspector. A discovery/result row shows visibility, effective label/type,
    and compact warning/format state. Show All and reset actions reuse the existing visibility/width rules,
    including the invariant that at least one column remains visible.
13. Discovery is adaptive. At zero columns it shows an empty state. At one through ten columns it shows every
    column in source order and no search field. Above ten it shows no unfiltered list: an empty query leaves the
    current selection in the inspector and displays zero result rows; a non-empty label query exposes at most
    the first ten localized case-insensitive substring matches in source order and reports when an eleventh
    match requires refinement. An exact `#N` query addresses one valid 1-based column directly and never scans
    labels; malformed, overflowing, zero, or out-of-range addresses leave selection unchanged and explain the
    error.
14. The reusable list/result control continues to use `ColumnPanelLayouting`. It requests labels and metadata
    only for live rows plus its fixed one-viewport overscan on each side, capped by the adaptive source's at
    most ten logical rows, plus the independently selected inspector column. Label search uses unchanged
    `ColumnLabelSearching` decisions off-main in batches of at most 1024, stops after finding an eleventh match
    or exhausting the labels, is cancellable on query replacement, Settings close, or document replacement,
    and does not fetch type metadata until a retained result enters the live list viewport. Headerless or
    empty-header columns retain the generic name plus 1-based index searchable text; headered search retains
    decoded source-label matching under the captured session locale. Truncated labels preserve and expose their
    existing truncation state.
15. Type/format/null changes invalidate and redraw only the affected visible column. An automatic-width column
    may be remeasured once for that direct user change and grow monotonically to fit the new display; it never
    shrinks implicitly. Apart from such a direct configuration change, content-driven growth remains triggered
    only by newly materialized vertical evidence. Manual width wins. Horizontal scrolling never changes an
    already-established width, and one column's content never affects another's width.
16. The embedded Settings surface is keyboard navigable and exposes labels, selected/effective type,
    Auto/override source, warning, format-unavailable, null, progress, overflow/refinement, direct-address
    errors, disclosure state, and reset actions to VoiceOver. Warning and search-overflow state are not
    color-only, and Reduce Motion/Increase Contrast behavior follows the existing macOS UI.
17. Opening Settings clears search/results, collapses both advanced disclosures, and restores the last selected
    column in the logical session, falling back to zero-based column 0 when that selection is absent or invalid
    and a column exists; an empty document has no selection.
    Closing Settings cancels search and clears search/results but preserves that selection. Disclosure expansion
    survives column changes only until Settings closes. A header action raises Settings and, when current
    discovery/result rows already contain the target, preserves the query (if any), selects the target, and
    scrolls it into view. Above ten columns, when current results exclude it, the action clears the old label
    query, resolves the target as direct `#N`, and selects and scrolls that sole result. Explicitly opening a new
    document resets selection and search; a safe internal Parsing re-open preserves the selected ordinal while
    clearing search, and an unsafe mapping falls back to column 0 when one exists.

## Non-functional constraints

- **Cold start:** existing launch-to-first-visible-rows remains below 500 ms on every frozen corpus fixture,
  including `wide_100k_cols`. Type inference is entirely outside `ls_open`; the feature adds no all-column
  strings, controls, metadata snapshots, or per-column FFI calls to first paint.
- **Interactive latency:** normal Settings open/raise, selection, result scroll, disclosure, type change, and
  redraw target at most 100 ms and must remain below 500 ms. Any search capable of crossing 500 ms runs off-main,
  reports loading/progress by that threshold, and remains cancellable. A broad search may take time proportional
  to labels examined before its eleventh match or exhaustion, but it never blocks the main thread.
- **Embedded-list complexity:** live row construction, reuse, label copies, and metadata retrieval are
  `O(Settings list viewport + overscan)` and are additionally capped by ten logical discovery/result rows,
  independent of total column count. Empty-query Settings on a document above ten columns requests only the
  selected inspector column, not all columns. Grid inference follows the established horizontal column window,
  not the non-hidden-column set.
- **Inference complexity:** work is `O(bounded head + requested materialized windows)`, never `O(file)`,
  `O(all rows)`, or `O(all columns)`. Per-event and per-chunk byte bounds are fixed above.
- **Memory:** new core type state is `O(columns requested/configured)`, plus bounded job/evidence state. It is
  sparse and not `O(total columns)` on an untouched wide document. The embedded Settings surface owns
  `O(viewport)` live row views and strings; between fixed-size search batches it retains at most ten matching IDs
  plus an overflow Boolean, never all matching labels, IDs, or controls. One transient candidate/match batch is
  bounded by 1024. Existing `O(columns)` visibility, width, and x-offset scalar arrays remain the sole accepted
  wide-column indexes.
- **Header strings:** the macOS session no longer owns `[String]` for every header. Actual header bytes are
  caller-copied only for the grid/Settings window or an off-main label search. The existing width/offset setup may
  perform a batched length-only preflight over columns because `ARCH-column-windowing` already requires compact
  per-column scalars; it may not allocate a Swift String or request type inference/metadata for every column.
- **Stability:** a published effective type and active format do not silently flip because the user scrolls,
  filters, searches, or changes view coordinates. Global/per-column generations make every visible update
  explicit and coherent.
- **Threading:** C metadata polls/copies are poll/control-lane operations synchronized with the existing worker.
  Inference uses the existing worker and yields to foreground scan work. It never invalidates an `ls_str` borrow.
- **Security/correctness:** lengths and IDs are validated before mutation; byte counts use checked arithmetic;
  caller buffers are never overrun or partially populated on an error; source files remain read-only.
- **Deployment:** macOS 26 is the project-wide minimum. `Package.swift` already declares 26; the corresponding
  `PROJECT.md` update lands with the root freeze. This feature adds no runtime, build, network, or third-party
  dependency.

## Component decomposition & data flow

### Existing components reused or changed

| Component | Delta |
|---|---|
| `api/lesssheet.h` | Append one column-metadata extension block. Existing constants, enums, structs, functions, comments governing existing symbols, numeric values, layouts, and borrow behavior remain unchanged. The root planner freezes the additive symbols before implementation. |
| `backend/src/root.zig` | Export the additive calls and route them to the document. `ls_open` order remains encoding detection → dialect sniff → shape/header → bounded ready head → existing worker; it performs no inference. |
| `backend/src/base.zig` | Own sparse per-column slots, request coalescing, generations, bounded evidence, and low-priority inference tasks on the existing worker. Existing row/window/index/search/filter state and raw access stay authoritative. |
| `backend/src/sniff.zig` | Reuse the pinned exact numeric grammar. Type inference does not alter delimiter/header sniffing and is not called from sniff/open. |
| `backend/src/encoding.zig` and Reader seam | Reuse bounded source/decode behavior and source-row identity. CSV has no declared type; a future Reader may fill the declared slot without changing precedence or frontend snapshots. |
| `LessSheetKit/CoreDocumentSession` | Bridge batch snapshots/copy operations and stop eagerly constructing `[String]` for every header. Serialize live-handle access with existing close safety and expose caller-owned Swift values. |
| `LessSheetKit/ColumnVisibility` | Remain the single visibility model. No second hide/show state is introduced by Settings. |
| `ViewerModel` and grid rendering/sizing | Coordinate requested grid/Settings IDs, poll one global generation, cache metadata/labels only around visible windows, validate/format visible raw cells, apply automatic alignment, and preserve monotone/manual width rules. Raw copy/Find/filter paths bypass this cache. Existing `columnPanel*` state names may remain internal. |
| `apps/macos/Sources/Contracts/ColumnPanel.swift` | **No change.** Reuse `ColumnPanelViewport`, `ColumnPanelLayouting`, and `ColumnLabelSearching` with their frozen geometry, batch, localized-substring, and source-order semantics. Exact `#N`, the ten-result cap, and the adaptive threshold are frontend composition/routing around those contracts. |
| `SettingsWindow` | Keep Parsing intact as the compact full-width section; make the normal titled Settings window wider and resizable; embed the adaptive list/search and inspector side by side beneath Parsing; own disclosure/open-close presentation state. |
| `ColumnPanelView` reusable components | Reuse the AppKit `NSTableView` row views, viewport planning, inspector controls, off-main search batching, progress, and accessibility presentation inside Settings. Remove the user-visible sheet shell, glass container, Done action, and sheet dismissal ownership. Internal legacy names need not change. |
| `AppUI` / `AppDelegate` | Remove the document-window column sheet route. The Settings command and column-header actions raise the one retained Settings window; a header action carries its target column into the embedded surface. |

### Data flow

```text
ls_open (unchanged bounded raw document)
    │
    ├── first row + horizontal column window ──► raw grid cells
    │                                              │
    │                                              └── Swift visible-cell validator
    │                                                   └── FormatStyle / raw fallback
    │
    └── requested grid ∪ Settings column IDs ──► existing worker, bounded chunks
                                                   │
                                                   ├── sparse evidence/state
                                                   └── atomic metadata commit
                                                          │
                         global-generation poll ◄──────────┘
                                   │
                         query only visible IDs
                                   │
                         redraw affected visible columns
```

The UI has one column-ID coordinator. Each grid/Settings viewport, result, or selected-inspector change computes
the union of requested IDs and issues one replacement inference request. This prevents UI consumers from racing
by independently replacing the worker's desired set. For a document above ten columns with an empty query, the
Settings contribution is exactly the selected inspector ID; during label search, IDs do not join the union
until one of the at most ten retained results enters the live result viewport.

The worker re-lexes the deterministic bounded head only after the first request. Later `ls_window_set` success
publishes source-row identities and eligible requested-column IDs into a bounded event queue; it does not pass
borrowed cell pointers to the worker. The worker re-reads through the Reader behind the known frontier, accounts
decoded complete-cell bytes, and commits at a chunk boundary. Jump/Find/search/filter demand preempts it at that
boundary. Cancelled or superseded work retains already committed evidence but cannot commit an obsolete batch.

### Logical-session internal re-open

An explicit document close/open is always a new logical session and resets every column type, inference, null,
format, visibility, automatic/manual width, and column-Settings selection/search state. Nothing is persisted.

Changing Parsing settings inside an open document is an **internal re-open** in the same logical session. Swift
owns a snapshot of user-authored column settings only: override, null sentinel, format, visibility, and manual
width. Inference, conflicts, proposals, automatic widths, active jobs, and metadata generations are never
replayed. Search text/results and advanced-disclosure expansion are presentation state and are never replayed.
An internal re-open clears search. A safe identity map preserves the selected column ordinal; an unsafe map
resets selection to column 0, matching the fresh column state.

The frontend opens the candidate handle while retaining the old live handle, then determines whether mapping is
safe:

- a header-only change maps ordinally only when column count is unchanged;
- a separator, quote, or encoding change maps only when column count is unchanged **and** the two documents have
  byte-identical ordered decoded header identities;
- a headerless dialect/encoding change is never safely mappable;
- a missing header on either side, a truncated header identity, count mismatch, order mismatch, or any label
  mismatch makes the mapping unsafe.

Identity comparison uses `ls_column_labels_copy_many` in bounded batches and retains no all-column String array.
If comparison crosses 500 ms it reports progress and is cancellable. On a safe map, Swift replays the snapshot
ordinally into the candidate, recalculates automatic widths, starts inference afresh only for the new visible
window, and atomically swaps handles. If candidate open or replay fails, it closes the candidate and keeps the
old handle and settings without a partial apply. On an unsafe map, the candidate becomes a fresh column state
and the UI explains that column settings were reset rather than applying them to the wrong identities.

## External interfaces

### Inline-Settings amendment boundary

The amendment changes UI composition and routing only. It adds, removes, or changes no symbol, numeric value,
layout, function, or behavior in the frozen C ABI described below. It also makes no change to the public Swift
declarations or pinned semantics in `apps/macos/Sources/Contracts/ColumnPanel.swift`:
`ColumnPanelViewport`, `ColumnPanelPlan`, `ColumnPanelLayouting`, `ColumnLabelCandidate`,
`columnLabelSearchBatchMax`, and `ColumnLabelSearching` remain byte/source compatible and keep their existing
meaning. Existing conformance tests must pass unchanged.

The user-visible macOS routing contract becomes:

- the Settings command raises the one normal titled Settings window;
- there is no “Configure Columns…” command, document-window sheet, second panel, or separate Done action; and
- a column-header configuration action raises that same Settings window with the target selected, using an
  existing matching result when possible or replacing an excluding label query with direct `#N` resolution.

The exact `#N` recognizer, adaptive ten-column threshold, result cap, overflow indicator, Settings open/close
state, and disclosure state are feature-local frontend behavior outside the frozen Swift search/layout
contracts. No production, runtime, build, or network dependency is added.

### Additive C ABI rules

`api/lesssheet.h` gains only the symbols described below, in one new extension block. No existing byte is edited
inside an existing definition or prototype; no existing enum gains a case; no existing struct grows; no existing
function changes signature, allocation behavior, threading lane, return semantics, or borrow lifetime. A client
built against the prior header continues to link and behave identically.

All new snapshots are fixed-layout plain values containing only fixed-width integers, `double`, nested fixed
values, and reserved storage—never pointers, `bool`, native-width enums, or `size_t`. Enum-valued fields are
stored as `uint32_t`. On supported 64-bit targets every explicit reserved field and output padding is zero. The
root planner freezes field offsets/sizes with C and Zig compile-time assertions.

Variable UTF-8 (header label, null sentinel, conflict example) crosses only through caller-buffer copy calls.
The caller owns every snapshot/span/copied byte immediately and it remains valid across every later
`ls_window_set`, worker commit, request, and cancel. `ls_close` does not affect caller-owned copies. No new call
returns an `ls_str`, and the existing “until next window/close” borrow rule is byte-for-byte unchanged.

#### Constants

| Symbol | Value / meaning |
|---|---|
| `LS_COLUMN_METADATA_ABI_VERSION` | `1` |
| `LS_COLUMN_BATCH_MAX` | `1024` column IDs/items per call |
| `LS_COLUMN_INFERENCE_HEAD_MAX_ROWS` | `256` data rows; the byte ceiling is existing `LS_OPEN_HEAD_MAX_BYTES` (4 MiB source bytes) |
| `LS_COLUMN_INFERENCE_WINDOW_MAX_BYTES` | `262144` decoded complete-cell bytes per later window event and per worker chunk |
| `LS_COLUMN_SENTINEL_MAX_BYTES` | `256` UTF-8 bytes; zero is valid |
| `LS_COLUMN_CONFLICT_EXAMPLE_MAX_BYTES` | `256` UTF-8 bytes, cut only at a code-point boundary |
| `LS_COLUMN_TYPE_PRECISION_UNSPECIFIED` | `UINT64_MAX` |
| `LS_COLUMN_TYPE_SCALE_UNSPECIFIED` | `INT64_MIN` |
| `LS_COLUMN_TYPE_FRACTION_DIGITS_UNSPECIFIED` | `UINT32_MAX` |

#### Stable enum/flag values

Each set below starts at the shown value and is frozen; future cases are additive only through a new ABI
version/surface, never by changing a v1 meaning.

| Type/set | Values |
|---|---|
| `ls_column_result` | `LS_COLUMN_OK=0`, `LS_COLUMN_INVALID_ARGUMENT=1`, `LS_COLUMN_NO_COLUMN=2`, `LS_COLUMN_NO_VALUE=3`, `LS_COLUMN_NO_PROPOSAL=4`, `LS_COLUMN_BUFFER_TOO_SMALL=5`, `LS_COLUMN_OUT_OF_MEMORY=6` |
| `ls_column_type_kind` | `LS_COLUMN_TYPE_UNKNOWN=0`, `UNSUPPORTED=1`, `TEXT=2`, `BOOLEAN=3`, `INTEGER=4`, `DECIMAL=5`, `DATE=6`, `DATETIME=7` |
| `ls_column_type_source` | `LS_COLUMN_SOURCE_NONE=0`, `DECLARED=1`, `INFERRED=2`, `OVERRIDE=3` |
| `ls_column_datetime_semantics` | `LS_COLUMN_DATETIME_NONE=0`, `NAIVE=1`, `ZONED=2` |
| `ls_column_inference_state` | `LS_COLUMN_INFERENCE_UNREQUESTED=0`, `QUEUED=1`, `SAMPLING=2`, `PROVISIONAL=3`, `PUBLISHED=4` |
| `ls_column_confidence` | `LS_COLUMN_CONFIDENCE_NONE=0`, `LOW=1`, `BOUNDED=2`, `EXHAUSTIVE=3` |
| `ls_column_null_policy_kind` | `LS_COLUMN_NULL_NONE=0`, `SENTINEL=1` |
| `ls_column_conflict_state` | `LS_COLUMN_CONFLICT_NONE=0`, `OBSERVED=1`, `PROPOSED=2` |
| `ls_column_inference_job_state` | `LS_COLUMN_JOB_IDLE=0`, `QUEUED=1`, `RUNNING=2`, `DONE=3`, `CANCELLED=4` |
| Metadata presence flags | `LS_COLUMN_HAS_DECLARED=1<<0`, `HAS_INFERRED=1<<1`, `HAS_OVERRIDE=1<<2`, `HAS_PROPOSAL=1<<3`, `HAS_NULL_SENTINEL=1<<4`, `HAS_CONFLICT_EXAMPLE=1<<5` |
| Label flags | `LS_COLUMN_LABEL_PRESENT=1<<0`, `LS_COLUMN_LABEL_TRUNCATED=1<<1` |

Null support is represented by `ls_column_null_policy_kind`, the sentinel presence/bytes, and per-column
null counts. There is intentionally no null base-type enum that would collapse nullability into type.

#### Fixed-layout structs

`ls_column_type` is 48 bytes, alignment 8:

| Offset | Field | Representation / v1 rule |
|---:|---|---|
| 0 | `struct_size` | `uint32_t`, 48 |
| 4 | `abi_version` | `uint32_t`, 1 |
| 8 | `kind` | `uint32_t ls_column_type_kind` |
| 12 | `flags` | `uint32_t`, zero in v1 |
| 16 | `decimal_precision` | `uint64_t`; unspecified sentinel for non-decimal/unknown |
| 24 | `decimal_scale` | `int64_t`; unspecified sentinel for non-decimal/unknown |
| 32 | `datetime_semantics` | `uint32_t ls_column_datetime_semantics`; NONE outside datetime |
| 36 | `datetime_fraction_digits` | `uint32_t`, 0–9 or unspecified |
| 40 | `reserved` | one `uint64_t`, zero |

`ls_column_metadata` is 384 bytes, alignment 8:

| Offset | Field | Representation / meaning |
|---:|---|---|
| 0, 4, 8, 12 | `struct_size`, `abi_version`, `column`, `presence_flags` | four `uint32_t`; size 384/version 1/absolute column ID/flags |
| 16 | `generation` | `uint64_t`, this column's committed metadata generation; zero means untouched |
| 24, 72, 120, 168, 216 | `declared`, `inferred`, `override`, `effective`, `proposal` | five 48-byte `ls_column_type` values; absent slots contain canonical unknown plus zeroed reserves |
| 264, 268, 272, 276, 280, 284 | `effective_source`, `inference_state`, `confidence`, `null_policy`, `conflict_state`, `null_sentinel_bytes` | six `uint32_t`; sentinel byte count is valid when present and may be zero |
| 288, 296, 304 | `evidence_count`, `sampled_row_count`, `sampled_decoded_bytes` | three `uint64_t`, cumulative committed values/rows/decoded bytes |
| 312, 320, 328 | `empty_count`, `null_count`, `conflict_count` | three `uint64_t` sampled, cumulative committed counts under the current null/effective epoch; not whole-document totals unless confidence is EXHAUSTIVE |
| 336 | `conflict_source_row` | `uint64_t` source data-row identity; `LS_NO_ROW` when absent |
| 344, 348 | `conflict_example_bytes`, `conflict_example_truncated` | two `uint32_t`; stored caller-copy length and 0/1 truncation flag |
| 352 | `reserved` | four `uint64_t`, zero |

`ls_column_inference_status` is 112 bytes, alignment 8:

| Offset | Field | Representation / meaning |
|---:|---|---|
| 0, 4, 8, 12 | `struct_size`, `abi_version`, `state`, `reserved0` | four `uint32_t`; size 112/version 1/job state/zero |
| 16, 24 | `request_generation`, `metadata_generation` | two `uint64_t`; desired-set epoch and latest global commit generation |
| 32, 36 | `requested_column_count`, `completed_column_count` | two `uint32_t` for the current finite work set |
| 40, 48, 56, 64 | `source_bytes_scanned`, `source_bytes_budget`, `rows_scanned`, `rows_budget` | four `uint64_t`; progress axes for the current finite queued sample |
| 72 | `progress` | `double` in `[0,1]`; 1 only when current finite work is done, frozen on cancel |
| 80 | `reserved` | four `uint64_t`, zero |

`ls_column_label_span` is 48 bytes, alignment 8:

| Offset | Field | Representation / meaning |
|---:|---|---|
| 0, 4, 8, 12 | `struct_size`, `abi_version`, `column`, `flags` | four `uint32_t`; size 48/version 1/requested ID/label flags |
| 16, 24 | `offset`, `len` | two `uint64_t` offsets into the successful caller arena; length is display-capped UTF-8 bytes |
| 32 | `reserved` | two `uint64_t`, zero |

#### Functions

For an output status, metadata item, or label span, the caller initializes only `struct_size` and `abi_version`
to the v1 values above; for an input `ls_column_type`, it initializes those fields and zeros `flags`/`reserved`.
The core validates every element before writing any element and overwrites the complete v1 output on success.
This makes a size/version mismatch an atomic `LS_COLUMN_INVALID_ARGUMENT` rather than an out-of-bounds write.

Every ID batch preserves caller order and permits duplicates. Unless stated otherwise, a zero-length batch is a
valid no-op/query; a non-zero batch requires non-null input/output pointers, count and capacity at most
`LS_COLUMN_BATCH_MAX`, and every ID below `ls_column_count`. Validation is all-or-nothing: an invalid ID, shape,
descriptor, or capacity produces no output and no mutation.

| Symbol | Exact operation and arguments | Allocation / result |
|---|---|---|
| `ls_column_inference_request` | Live mutable document, caller-owned `uint32_t` ID array, count. Replaces the desired active ID set; IDs are copied, sorted/coalesced internally, and a byte-identical repeated set is idempotent. Count must be 1–1024. | Poll/control lane; may allocate sparse state/copied IDs. Returns `ls_column_result`; OOM leaves the prior request intact. |
| `ls_column_inference_cancel` | Live mutable document. Cancels the current desired set/job. Committed evidence and published metadata remain; queued/no-evidence columns return to unrequested and partial columns remain provisional. | Poll/control lane, zero allocation, no failure. Status becomes CANCELLED until a replacement request. |
| `ls_column_metadata_poll` | Live const document and caller-owned `ls_column_inference_status`. Produces one coherent job/global-generation snapshot. | Poll/control lane, zero allocation, `LS_COLUMN_OK` after valid struct-size/version check. |
| `ls_column_metadata_get_many` | Live const document; input ID array/count; output metadata array/capacity; output global-generation pointer. Returns one-lock coherent items and the generation at which they were read. Untouched IDs are synthesized as generation-0 unrequested/unknown without creating state. | Poll/control lane, zero allocation. Output is untouched on error. Caller owns it permanently. |
| `ls_column_override_set` | Live mutable document, column ID, caller-owned `ls_column_type` descriptor. Copies a valid explicit v1 kind/parameters and makes it effective atomically. UNKNOWN/UNSUPPORTED and malformed parameter combinations are rejected as overrides. | May allocate first sparse state; result enum; OOM/validation leaves prior state. |
| `ls_column_override_clear` | Live mutable document and column ID. Idempotently removes the override, revealing published inferred/declared/unknown; resets conflicts against the old effective descriptor. | Zero allocation; result distinguishes invalid column only. |
| `ls_column_null_sentinel_set` | Live mutable document, column ID, UTF-8 pointer/byte length 0–256. Copies bytes exactly; null epoch change resets inference/conflicts/proposal and requeues an active column. A null pointer is valid only for length zero. | May allocate; atomic result; invalid UTF-8/length/OOM preserves old state. |
| `ls_column_null_sentinel_clear` | Live mutable document and column ID. Idempotently removes the sentinel and starts the same fresh-evidence epoch. | Zero allocation after existing state; invalid column is reported. |
| `ls_column_inference_accept_proposal` | Live mutable document and column ID. Atomically moves proposal into inferred/published, stays Auto, clears proposal/conflict aggregate, and commits new generations. | Zero allocation. Returns `NO_PROPOSAL` without mutation when absent. |
| `ls_column_labels_copy_many` | Live const document; ID array/count; caller-owned span array/capacity; optional byte arena/capacity; output required-byte count. With null arena and zero capacity it fills spans/required length only. With insufficient non-zero capacity it returns BUFFER_TOO_SMALL, reports required length, and leaves the arena untouched. Success copies source labels in requested order. Header-off/empty labels have no PRESENT flag/zero length; truncated labels carry TRUNCATED. Generic names remain frontend-owned. | Poll/control lane, zero allocation. Spans/arena are caller-owned and window-independent. |
| `ls_column_null_sentinel_copy` | Live const document, column ID, optional caller buffer/capacity, output required length. Standard two-pass copy; `OK` plus length zero distinguishes an empty sentinel from `NO_VALUE`. | Poll/control lane, zero allocation; no partial write. |
| `ls_column_conflict_example_copy` | Live const document, column ID, optional caller buffer/capacity, output required length. Two-pass copy of the bounded UTF-8 prefix identified by metadata; absent example returns `NO_VALUE`. | Poll/control lane, zero allocation; no partial write. |

`ls_column_inference_cancel` returns `void`; every other new function returns `ls_column_result`. ID counts and
item capacities are `uint32_t`; byte pointers are `uint8_t` pointers with `size_t` lengths/capacities; required
byte lengths are written through `size_t` pointers; generations are `uint64_t`. All input arrays/descriptors are
`const` and borrowed only for the duration of the call. On BUFFER_TOO_SMALL, a copy call may write its required
length (and label spans during label preflight), but writes no partial byte payload; all other errors leave all
outputs untouched.

Normative parameter order is:

- inference request: document, column-ID pointer, column count;
- inference cancel: document;
- metadata poll: document, output status pointer;
- metadata batch get: document, column-ID pointer, column count, output-item pointer, output capacity, output
  global-generation pointer;
- override set: document, column ID, input type-descriptor pointer; override clear: document, column ID;
- null-sentinel set: document, column ID, input-byte pointer, byte length; clear: document, column ID;
- proposal accept: document, column ID;
- label batch copy: document, column-ID pointer, column count, output-span pointer, span capacity, output-byte
  arena, arena capacity, output-required-byte pointer; and
- sentinel/conflict-example copy: document, column ID, output-byte buffer, buffer capacity,
  output-required-byte pointer.

Mutating calls are the only new calls allowed to allocate. Their appended extension documentation explicitly
adds them to the legacy allocation discipline without changing the behavior of any legacy symbol. Batch
snapshot, label/sentinel/example copy, poll, cancel, clear, and accept calls are zero-allocation. All new calls
are internally synchronized with the worker and may run concurrently with the serialized window lane; as with
every existing call, the frontend must not race them against `ls_close` on the same handle.

### Generation and publication semantics

The document starts with global metadata generation zero. Each successful atomic metadata commit allocates the
next non-zero global generation and stamps every column changed by that commit with that same value. Multiple
evidence/count/conflict changes produced by one worker chunk are one commit. Config mutations are their own
commit. Generation wrap is practically unreachable; if `UINT64_MAX` is reached it remains saturated and the
frontend conservatively re-queries visible IDs on every poll.

`request_generation` changes only when a normalized desired inference set changes or is cancelled; it identifies
progress, not metadata. A worker result carries its request generation and is discarded if superseded before
commit. A global-generation change tells Swift only that some column changed. Swift compares cached per-column
generations after one `get_many` for the grid/Settings viewport and redraws only changed visible columns. It never
uses the global value as a reason to query all column IDs.

Confidence/state publication is pinned:

- no eligible value: NONE/unrequested or EXHAUSTIVE unknown after known exhaustion;
- one through seven eligible agreeing values without exhaustion: LOW/PROVISIONAL;
- eight agreeing values: BOUNDED/PUBLISHED;
- every source data row examined under an exact row count: EXHAUSTIVE/PUBLISHED, including fewer than eight;
- later agreeing evidence may raise counts/confidence but cannot replace a published descriptor; and
- later contradiction changes only conflict/proposal state until explicit acceptance.

## Technology decisions

| Decision | Chosen option | Alternatives considered and rationale | Scope |
|---|---|---|---|
| C ABI metadata access | Caller-owned, fixed-layout batch snapshots (max 1024), one global and per-column generations, plus separate caller-buffer text copies. | One FFI call per column is simple but creates 100k-call traps; borrowed metadata/text would extend the fragile window lifetime; core-owned arrays expose allocation/layout. The chosen form is zero-allocation on the hot query path, coherent, Swift-safe, and additive. | Feature-local additive ABI; root-frozen. |
| Core type model | Sparse declared/inferred/override/effective descriptors with orthogonal null/conflict/proposal state; effective precedence `override > inferred > declared`. | A CSV-only enum blocks self-describing readers; frontend-only guesses duplicate evidence/state and cannot be shared; silently replacing a guess on scroll is unstable. Reserved fields/source slots keep later formats possible without implementing them now. | Project-wide metadata model; v1 kinds feature-local. |
| Inference execution | Deterministic 4 MiB/256-row head plus 256 KiB materialized-window contributions, only after requested, on the existing worker with foreground yielding. | Inference inside `ls_open`, full-file scanning, all-column inference, and adding a competing worker all violate cold-start/operational bounds or complicate scan arbitration. Frontend inference would duplicate the Reader grammar and lose future declared types. | Feature-local scheduling on existing project worker. |
| Publication/conflicts | Eight-value or exhaustive-small publication; freeze published type; contradictory values become a user-accepted proposal. | Confidence-driven silent flipping makes alignment/format depend on scroll order. “First value wins” is too brittle; waiting for EOF defeats laziness. Eight is a bounded, deterministic evidence floor while exhaustive small documents still resolve. | Project-wide behavior for inferred metadata. |
| Exact decimal display | Foundation `Decimal.FormatStyle` only after a string-exact Decimal round-trip guard; raw fallback plus non-conflict indication outside Foundation's exact range; half-even rounding. | `Double` violates exactness; an in-house/third-party arbitrary-precision formatter adds production maintenance, licensing, size, and locale burden for v1. Raw fallback is reversible and never lies. Foundation documents the native Decimal format style and decimal-number limits. | macOS feature-local; no dependency. |
| Date/datetime display | Strict project grammar followed by Foundation ISO/date-components parsing and native localized presets; preserve naive wall time or each source offset. | `DateFormatter` with arbitrary user patterns is locale-ambiguous and mutable; permissive ISO parsing accepts forms outside the contract; custom calendrical code is high-risk. A lexical gate plus native calendar validation is deterministic and locale-capable. | macOS feature-local; grammar is project-wide metadata behavior. |
| Embedded Settings composition | The existing normal titled Settings window becomes the sole, resizable column surface: compact Parsing above, reusable `NSTableView` discovery/results beside the SwiftUI inspector below. Main controls are immediate; Null and Width/Auto-fit use collapsed disclosures. | Retaining the separate sheet leaves the unwanted second transition; a tab or navigation destination fails the requirement that Parsing and main column controls remain visible together; restoring eager SwiftUI controls revives the wide-document hazard. Reusing the shipped native list/inspector preserves deterministic reuse, selection, and accessibility without a new package. | macOS feature-local amendment; no dependency or project-wide change. |
| Adaptive column discovery | Show the complete source-order list only for 1–10 columns. Above ten, use search-only discovery with at most ten existing localized-substring matches, an overflow/refine state, and direct exact `#N` addressing. No empty-query wide list exists. | A fully virtualized 100k list is memory-safe but poor to browse; a standard picker may eagerly materialize labels and controls; retaining every search match makes broad queries `O(total columns)` in frontend memory. True fuzzy ranking requires new scoring semantics, full-corpus ranking work, and likely a new contract or dependency. Existing substring batches plus a ten-ID cap are deterministic, bounded, reversible, and keep every column reachable through `#N`. | macOS feature-local amendment around unchanged Swift contracts. |
| Header labels | New zero-allocation batched caller-copy API; viewport/overscan String cache, off-main batch search, and length-only cold width preflight. | Eager `[String]` copies regress wide open; returning borrowed labels preserves the old invalidation hazard; storing all search labels duplicates memory. The chosen split preserves header truncation and strict re-open identity while keeping live strings bounded. | Cross-component feature-local. |
| Internal re-open ownership | Swift logical-session snapshot of user-authored settings, strict identity mapping, candidate-handle replay, then atomic swap. | Core persistence/sidecars violate no-persistence and format neutrality; replay by count alone can configure the wrong column; resetting every internal parse tweak discards useful user work. Candidate swap preserves the old session on failure. | macOS session architecture. |
| Platform/dependencies | macOS 26, Swift/Foundation/AppKit/SwiftUI plus Zig standard library only; no new package/runtime. | Supporting older macOS weakens the approved glass/format surface and adds branches; external formatting/table packages add deployment, licensing, and maintenance cost without solving an unmet requirement. `Package.swift` already declares 26. | **Project-wide macOS minimum**, approved; `PROJECT.md` updated by root freeze. |

The Foundation choices rely on Apple's native [`Decimal.FormatStyle`](https://developer.apple.com/documentation/Foundation/Decimal/FormatStyle),
[`NSDecimalNumber`](https://developer.apple.com/documentation/Foundation/NSDecimalNumber), and
[`Date.ISO8601FormatStyle`](https://developer.apple.com/documentation/foundation/date/iso8601formatstyle) /
[`DateComponents.ISO8601FormatStyle`](https://developer.apple.com/documentation/foundation/datecomponents/iso8601formatstyle).
The strict project grammar and exact-decimal guard remain authoritative where native parsers are broader or
bounded.

## Acceptance criteria

1. **ABI is additive and legacy behavior is byte-identical.** The `lesssheet.h` diff contains one additive
   column-metadata block and no deletion/modification of any existing constant, enum member/value, struct
   field/layout, declaration, or prototype. A client compiled from the pre-feature header links to the new core
   and passes the complete pre-feature root/backend/macOS gate unchanged. New compile-time layout checks pin
   `ls_column_type=48`, `ls_column_metadata=384`, `ls_column_inference_status=112`, and
   `ls_column_label_span=48` bytes with the offsets above on every supported target; all reserved output is zero.
2. **Batch snapshots are coherent, zero-allocation, and caller-owned.** A mixed-order batch with duplicates
   returns one item per requested ID in caller order under one reported global generation. Repeating query,
   poll, and copy calls under an allocation-failing allocator performs zero allocation. Returned values/bytes
   remain unchanged after window eviction, worker publication, override mutation, and cancel. Invalid ID,
   capacity, size, or ABI version leaves every output byte untouched.
3. **Mutation and text-copy errors are atomic.** Valid set/clear/accept operations produce exactly one generation
   commit; repeated clear and repeated normalized inference requests are idempotent. Invalid descriptors,
   invalid UTF-8, 257-byte sentinels, missing proposals, insufficient buffers, and forced allocation failure
   return their specified result without partial byte payload or state change; required lengths/spans remain the
   documented preflight output. An empty sentinel round-trips as
   `OK/length 0`, distinct from no sentinel.
4. **Cold open does no inference and does not regress.** Instrumentation proves `ls_open` starts no inference,
   creates no per-column type state, and consumes no source bytes beyond the existing open path. Every frozen
   cold-open fixture, including `wide_100k_cols`, remains below 500 ms to first visible rows; existing
   column-windowing timing and output gates remain green.
5. **Inference is bounded, lazy, and preemptible.** On a large/10-GB fixture, requesting `N` visible IDs touches
   only those coalesced IDs, at most 256 data rows and 4 MiB of source for the first sample, and at most 256 KiB
   decoded complete-cell bytes for each later materialized-window event/chunk. It neither advances the scan
   frontier nor waits for EOF. Jump, Find, filter, cancel, or replacement request takes effect by the next chunk
   boundary (target under 100 ms); any run still active at 500 ms exposes “Guessing…” progress/loading.
6. **Publication threshold is exact.** Seven agreeing eligible values in a non-exhaustive document remain
   LOW/PROVISIONAL and do not affect effective type/alignment. The eighth publishes BOUNDED. Exact documents
   with 0–7 eligible values publish EXHAUSTIVE at exhaustion (0 becomes unknown). Empty/null/truncated/oversized
   values do not increment evidence. Results and generations are identical across different window/request
   timing for the same ordered evidence.
7. **The grammar and parameters are pinned.** Conformance cases accept/reject the exact boolean, existing numeric,
   date, and datetime grammar above. Integer+decimal widens to decimal; mixed incompatible kinds become text;
   differing explicit datetime offsets remain zoned; naive+zoned conflicts. Decimal precision/scale and datetime
   semantic/fraction parameters match exact expected metadata without `float`/`double` conversion.
8. **Scroll never silently revises a published type.** After publishing an integer/date/datetime column,
   scrolling to contradictory complete values keeps the previous effective descriptor, alignment, and display
   preset byte-for-byte, increments conflict state/count, and surfaces the representative raw value. Eight
   agreeing contradictory source rows produce a proposal. Accepting changes inferred (not override), stays Auto,
   clears the proposal/conflict epoch, and increments generations exactly once.
9. **Empty, null, conflict, and partial values are distinct.** With no sentinel, `""` is blank empty text, is
   neither null nor evidence nor conflict under every effective type. With an empty sentinel it is null. Sentinel
   `" NA "` matches only those exact four bytes around `NA`; `"NA"`, `" na "`, and trimmed variants do not.
   Non-empty non-parseable complete values conflict and render raw. Display-truncated cells and every cell in a
   partially served oversized row render raw and produce no evidence/conflict. Format-unavailable never increments
   conflict state.
10. **Precedence and reset are observable.** Fixtures containing declared/inferred/override descriptors resolve
    exactly as `override > published inferred > declared > unknown`; provisional inference never wins. Clearing
    override reveals the prior inferred/declared value without re-open. Changing null policy starts a fresh
    evidence/conflict epoch. Unknown/unsupported always render the original value.
11. **The embedded Settings surface stays O(viewport) at 100k columns.** Opening Settings on
    `wide_100k_cols` with an empty query creates no unfiltered logical list and requests only the restored/fallback
    inspector column in addition to the grid column window. Any discovery/result list instantiates at most its
    visible rows plus one viewport of reusable overscan on each side (bounded by
    `3 × visibleRowCount + 8`) and can contain at most ten logical rows. Instrumentation shows no
    `0..<columnCount` control construction, no per-column metadata/FFI loop, no all-label Swift array, Settings
    open/raise and result scroll target at most 100 ms, and each remains below 500 ms. The unchanged
    `wide_100k_cols` cold-open path remains below 500 ms to first visible rows whether or not Settings was open in
    the previous document session.
12. **The 6/10/100k discovery boundary and `#N` route are exact.** A six-column fixture shows exactly six
    unfiltered source-order rows and no search field; a ten-column fixture shows exactly ten and no search field.
    Eleven-column and `wide_100k_cols` fixtures show a search field, zero unfiltered/empty-query result rows, and
    the restored selection (or column 1 fallback) in the inspector. A non-empty ordinary query uses the frozen
    localized case-insensitive substring decision, retains/renders the first at most ten matches in source order,
    and, upon an eleventh, retains the ten IDs plus only an overflow Boolean and exposes “More matches—refine
    your search.” Exact
    `#1`, `#10`, and `#100000` on the 100k fixture resolve directly to those 1-based columns without a label
    scan; `#0`, `#100001`, signs, surrounding whitespace, non-ASCII digits, and numeric
    overflow leave selection unchanged and expose “No such column.” Duplicate labels beyond the ten-result cap
    remain reachable by valid `#N`. An ordinary query scans label batches of at most 1024 off-main, retains at
    most ten matching IDs plus the overflow Boolean between batches rather than all label Strings/controls,
    discards the transient fixed-size batch after detecting the eleventh match or exhaustion, and requests type
    metadata only for live result rows. A search crossing 500 ms reports progress; query replacement, Settings
    close, or document replacement cancels within one batch/under 100 ms and stale results never publish. Empty
    queries and every `#`-prefixed valid/invalid direct-address input perform no label scan.
13. **Eager header Strings are removed without width regression.** `CoreDocumentSession` does not construct or
    retain `[String]` across all columns. First paint copies actual labels only for the grid/Settings window; the
    allowed all-column width setup uses batched length-only spans and compact existing width/offset arrays. A
    100k distinct-header fixture stays below 500 ms, retains no all-header Swift Strings, renders the right label
    and truncation state at arbitrary horizontal/Settings-list positions, and preserves `ARCH-column-windowing`'s
    per-column, horizontally stable, vertical-evidence-only monotone growth and viewport-fitting layout results;
    a direct user type/format change may remeasure only its affected visible column as requirement 15 specifies.
14. **Exact decimal formatting never lies.** Under fixed test locales, auto preserves `2.00`, `+1e5`, a 38-digit
    exact Decimal, and `1e400` byte-for-byte. Explicit grouping/fixed-place formatting uses locale separators and
    half-even tie results without `Double`. Exactly representable values produce pinned output; a 39+-digit value
    that Foundation changes and `1e400` remain original with format-unavailable, no rounding/group insertion,
    and no conflict.
15. **ISO boundaries and offset stability are exact.** Accepted cases cover date, naive datetime, 1- and 9-digit
    fractions, `Z`, and positive/negative offsets; rejected cases cover spaces, basic/week/ordinal/reduced forms,
    lowercase separators, missing seconds, invalid calendar/clock/offset, and >9 fraction digits. Under fixed
    locales, each preset has pinned output; naive wall time and each source offset are preserved with no implicit
    system-zone conversion. Mixing naive/zoned produces conflict rather than conversion.
16. **Alignment and width precedence are fixed.** Headers/text/unknown/unsupported align left, booleans center,
    numeric/date/datetime align right, and conflicting raw cells keep the column alignment. Type/format changes
    touch only that visible column; automatic width can only grow from its own current vertical-window display,
    manual width wins, and a horizontal away/back cycle changes no established width.
17. **Raw-value operations are invariant.** For cells whose display uses grouping, half-even fixed places,
    localized dates, null treatment, conflict raw fallback, or format-unavailable fallback, full-cell copy bytes,
    Find match positions/counts, search results, filter membership, and predicate outcomes are byte-for-byte
    identical to the same document with all column formatting/overrides disabled.
18. **Internal re-open mapping is strict and transactional.** A header-only same-count re-open replays only the
    five user-authored setting classes ordinally. Separator/quote/encoding re-open replays them only with equal
    counts and byte-identical ordered non-truncated header identities. Count mismatch, reordered/renamed/truncated
    header, or any headerless dialect change resets all column settings. In every safe replay, inference,
    conflicts/proposals, generations, and automatic widths restart. Candidate open/replay failure leaves the old
    handle and every setting unchanged; no partial candidate state becomes visible.
19. **Session reset and no persistence are complete.** Explicit document close/open clears inference, override,
    null sentinel, formats, visibility, manual/automatic widths, Settings selection/search, conflicts, and
    proposals. Closing during inference cancels/joins safely and a new handle begins at generation zero. No
    sidecar, preference/database record, extended attribute, recent-file profile, source write, or unexpected
    filesystem artifact is produced.
20. **Composition and accessibility are one coherent Settings surface.** The normal Settings window is resizable
    and is the sole column-configuration surface: compact Parsing is full-width above Columns; discovery/results
    and the inspector are side by side below; both sections remain present without tabs or navigation. There is
    no “Configure Columns…” entry, document-window sheet, chromeless second panel, separate Done action, or eager
    per-column checkbox list. At the declared minimum usable size, Visible, Type with source/reset, and every
    control in the applicable Number or Date format group are available without expanding an advanced disclosure
    or moving to another surface. Keyboard-only and VoiceOver verification can use the adaptive list/search,
    exact address, overflow/refine state, selection, both disclosures, conflicts and format-unavailable, reset,
    final-visible-column guard, progress, and cancellation under normal, Increase Contrast, and Reduce Motion
    settings.
21. **All gates and resource bounds hold.** Backend, macOS, root ABI, existing corpus, column-windowing,
    window-budget, search/filter, and copy gates pass unchanged. New retained core metadata is proportional only
    to requested/configured columns; embedded Settings has bounded live views/strings and at most ten search IDs;
    no new dependency is linked; and main-thread instrumentation records no operation at or above 500 ms.
22. **Settings lifecycle and header deep links are deterministic.** First opening in a logical session clears
    search/results, collapses Null and Width/Auto-fit, and selects the prior valid session selection or column 1
    when a column exists; a zero-column document has no selection.
    Expanding either disclosure and changing columns leaves expansion unchanged until Settings closes. Closing
    and reopening Settings preserves selection but clears search/results and collapses both disclosures. A header
    action raises the same Settings window; if the target is already in current discovery/result rows it
    preserves the query (if any), selects the target, and scrolls that row into view. Above ten columns, when
    current results exclude the target, it clears the excluding label query, resolves the target through direct
    `#N`, and selects/scrolls its sole result. A safe internal Parsing re-open clears search but preserves the
    selected ordinal; an unsafe mapping and an explicit new document both fall back to column 1 when one exists,
    with no search/results.
23. **The amendment changes no contract or project stack.** Relative to the shipped column-config baseline,
    `api/lesssheet.h` and `apps/macos/Sources/Contracts/ColumnPanel.swift` have an empty diff; all existing ABI and
    Swift contract conformance checks pass unchanged. The application links no new runtime/build package and
    introduces no persistent setting, header index, helper process, or network service. Legacy `ColumnPanel` /
    `panel` implementation names may remain, but only the one Settings surface is user-visible. `PROJECT.md`
    requires no amendment.

## Open Questions

None.
