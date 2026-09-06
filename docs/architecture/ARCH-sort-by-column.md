# ARCH — sort-by-column (single-column sorted views over any source)

Status: SIGNED — interviewed and converged with the user (batches 1–2, run `feature-sort-by-column`);
technology decisions and acceptance criteria explicitly approved by the user 2026-09-06.
AMENDMENT 1 (converging sorted prefix, 100 ms first-window bound) — SIGNED by the user 2026-09-06:
interview-approved after the first contract freeze, amended wording (FR2/FR3/FR6/FR11,
AC-s2/s6/s7/s14/s15, new AC-s16, §1/§2/§4 serving rules) explicitly re-signed.
AMENDMENT 2 — SIGNED by the user 2026-09-06: clarification after the backend cell's review — the §4
build-time memory bound (and AC-s9's restatement) is on the core's ANONYMOUS residency and excludes
file-backed, evictable pages of the scratch mappings; measured `ru_maxrss` counts those pages and
may exceed the figure while the protected property (bounded, row-independent anonymous memory)
holds. No behavioral change.
Changes the frozen `api/lesssheet.h` — root-planner freeze, lock-step edit (no compat layer, per the
FROZEN-SURFACE AMENDMENT precedent).

## 1. Problem & scope

Sort the document view by ONE column, ascending or descending, on every source kind (local mmap CSV,
local `.csv.gz`, HTTP), composed over the existing filter, with Find working inside the sorted view.
Sort state is session-only (never persisted), like all per-document state.

The inherent cost is honest and explicit: the FINAL sorted order requires one full pass over the
data (the smallest value can be on the last row) — the same price search-to-EOF and filter already
pay, with the same progress + cancel affordances. Latency beats throughput (Amendment 1): the view
flips to sorted coordinates IMMEDIATELY and serves a CONVERGING SORTED PREFIX — at every moment the
exact sorted top of the region scanned so far — so the first sorted-so-far rows appear within tens
of milliseconds of the click and refine live until the pass completes. Once built, the sorted view
is served from an on-disk permutation and every position in it is O(1)-addressable.

**Non-goals**
- Multi-column / secondary sort keys.
- Locale or Unicode collation (v1 text order is ASCII-case-folded byte order — matches search's
  pinned v1 folding rule).
- Persisting sort state, or any cross-open reuse of sort artifacts.
- Sorting as a copy/export transform beyond what the existing view-coordinate copy already gives
  (copying a rect of a sorted view copies rows in sorted order — that falls out, it is not new
  machinery).
- Changing filter, search, jump, or copy semantics outside the coordinate reinterpretation defined
  here.
- Converging treatment for find and jump (Amendment 1 scope guard): only the browsing view
  converges; find-in-sorted-view and jump-by-source-row resolve at full coverage (see FR5/FR7).

## 2. Inputs / Outputs

**Inputs (new ABI surface — exact C shapes frozen by the root planner)**
- `ls_sort_set(doc, column, direction)` — request a sort. `column` is an absolute column ID
  `< ls_column_count()` (else rejected, nothing changes — mirrors search validation). `direction`
  is a new two-value enum (ascending / descending). Starts the KEY PASS (below) unless the request
  is a no-op (identical column+direction against an already-ACTIVE sort).
- `ls_sort_clear(doc)` — remove the sort (also the "cancel the running pass" verb: clearing during
  a pass stops it and drops the request; the view returns to its pre-sort order). Zero-alloc, never
  fails.
- `ls_sort_poll(doc)` — zero-alloc snapshot: state (idle / building / active / parked / failed),
  progress in [0,1] (monotone within one build, exactly 1.0 at active), the requested column and
  direction, and a failure reason distinguishing at minimum disk (temp-storage) failure from memory
  failure. Exact struct/enum shapes are the planner's.
- Threading lanes follow the existing split: `ls_sort_set` / `ls_sort_clear` / `ls_sort_poll` join
  the poll/control lane (internally synchronized, any thread, never racing open/close).

**Outputs (behavioral, through the existing surface)**
- While a sort is PRESENTED (state BUILDING or ACTIVE), every row-addressing accessor —
  `ls_window_set`, `ls_cell`, `ls_cell_truncated`, `ls_row_oversized`, `ls_cell_copy`,
  `ls_source_row`, `ls_window_match_flags`, the copy job rect, `ls_jump_*`, `ls_search_*` — serves
  SORTED coordinates: view row i is the i-th row of the (filtered, if a filter is active) row set
  under the sort order. The header record is unaffected, exactly as under a filter.
- While BUILDING (Amendment 1), the servable region is the CONVERGING PREFIX: the first
  min(K, rows scanned so far) view rows, where the served rows are at every moment the EXACT sorted
  top of the scanned region for the requested direction. Served rows may be displaced/reordered as
  the scan advances (the progress affordance is visible throughout — the row-count-converges
  precedent, never silent wrong data). View rows beyond the prefix are not yet servable and return
  the existing not-yet-servable values (empty cell / LS_NO_ROW / LS_COPY_PENDING — the
  beyond-frontier convention). K is the prefix depth: it READS `LS_WINDOW_MAX_ROWS` (4096) through
  one resolver — no second constant to drift.
- At ACTIVE the whole view is servable through the permutation; the order never changes again for
  that build.
- `ls_source_row(doc, i)` returns the original data-row number (the gutter value) — a direct O(1)
  lookup for servable rows (prefix rows while BUILDING, any window row when ACTIVE).
- `ls_row_count_get` is unchanged (sorting does not change the row set or m). After the key pass
  completes, the count is exact (the pass advanced the shared frontier to EOF).
- Descending is the ascending permutation read backwards — flipping direction on an ACTIVE sort is
  instant (no new pass). Consequence, stated plainly: rows that compare equal appear in source order
  ascending and in REVERSE source order descending. A flip while BUILDING keeps the pass (run
  artifacts are direction-agnostic) and re-converges the prefix for the new direction from the
  already-extracted keys — never a source re-scan.

**Error cases**
- Invalid column / direction: rejected, nothing changes.
- Temp-storage failure (disk full, create/write error) or out-of-memory during the pass: the sort
  ends FAILED at a consistent point, the view RETURNS TO ITS PRE-SORT ORDER, the poll says why.
  Never a crash, never a stale partial view presented as final.
- Cancel (user, via `ls_sort_clear`) during the pass: sort off, view returns to its pre-sort order.

## 3. Functional requirements

**FR1 — Ordering semantics (the signed comparator).** The sort key is derived from the column's
EFFECTIVE type at `ls_sort_set` time (override > inferred > unknown; this gives the type override a
behavioral job). Per kind:
- INTEGER / DECIMAL: exact numeric order. The order is DEFINED by exact digit-string comparison
  (sign, magnitude), never by floating point — values beyond 2^53 or with equal prefixes order
  correctly.
- DATE / DATETIME: chronological. Zoned datetimes order by instant; a value whose zonedness differs
  from the column's `datetime_semantics` is non-conforming.
- BOOLEAN: false < true.
- TEXT / UNKNOWN: ASCII-case-insensitive comparison (fold A–Z, exactly search's pinned v1 rule;
  non-ASCII bytes compare raw), byte-exact comparison as the first tiebreak.
- Grouping: conforming values first (typed order), then non-conforming values (text order), then
  nulls per the column's null sentinel. Final tiebreak everywhere: source order (stable).
- Matching is over the cell's FULL transcoded UTF-8 text (like search), never the display-capped
  bytes.
- EXACTNESS PIN: the comparator's total order is the definition; fixed-width keys (below) are only
  an accelerator. Equal accelerator keys that may be lossy (text beyond the key prefix, numerics
  beyond the encoding's exactness) are resolved by re-lexing the full values. A hash is NEVER used
  to conclude equality — a collision would silently misorder rows.

**FR2 — The key pass and the build.** `ls_sort_set` starts one sequential scan over the data rows in
the document's single scan slot (per-row: evaluate the active filter predicate, extract the key for
matching rows). It advances the SHARED frontier (paid once; the row count becomes exact) and, as a
side effect, drives the active filter's counters to completion. (key, source row) pairs accumulate
in ONE fixed-size memory chunk (one named knob); a full chunk is sorted and spilled as a run to
ephemeral temp storage; a k-way merge then writes the final permutation — and the source→sorted
inverse mapping — to temp storage. A document whose pairs fit one chunk touches no disk for runs.
Amendment 1: alongside the chunk, the pass maintains a bounded best-so-far structure of the top K
rows for the requested direction (O(K) memory) that serves the converging prefix from the first
scanned block onward. Progress is pollable and monotone; the pass is cancellable.

**FR3 — Converging presentation (Amendment 1; replaces flip-at-DONE).** `ls_sort_set` flips the
view to sorted coordinates IMMEDIATELY. While BUILDING the view serves the converging prefix
(§2 Outputs): exact sorted top of the scanned region at every instant, live refinement, rows beyond
the prefix not yet servable, progress affordance visible throughout. At ACTIVE the full sorted view
is served and stable. A new `ls_sort_set` (different column, or any re-request that needs a pass)
flips immediately to the NEW request's converging prefix. Partial results are never presented as
final: the poll distinguishes BUILDING from ACTIVE at all times.

**FR4 — Composition with filter.** The sorted row set is exactly the filtered row set: the pass
evaluates the filter predicate and the permutation contains only matching rows. Gutter, jump, and
find compose accordingly (the converging prefix contains only filter-matching rows).

**FR5 — Jump under a sort.** `ls_jump_start`'s target stays an ORIGINAL data-row number (the filter
precedent; the gutter shows source numbers, so the number typed is the number seen). The landing is
that row's sorted position via the inverse mapping — O(1) once the sort is ACTIVE; a jump issued
while BUILDING resolves when the build reaches ACTIVE (scope guard: no converging treatment for
jumps), with the usual pollable progress; filtered/EOF clamping as today.

**FR6 — Input changes re-run the build.** Changing the filter (set/clear) or the sort column's type
override/null sentinel invalidates the permutation: the sort request PERSISTS and the pass re-runs
automatically (progress + cancel; on HTTP this is another full fetch — accepted explicitly in the
interview). The rebuild presents like any build (FR3): the view serves the rebuild's converging
prefix immediately. A dialect/encoding change is a re-open and clears the sort (fresh handle polls
sort-idle).

**FR7 — Find inside a sorted view.** `ls_search_*` operates in SORTED coordinates: nav anchors and
`found_row` are sorted positions; "next" means next in sorted order. Mechanism (counters, not
lists): the match-scan still sweeps SOURCE order (sequential, fast) but tallies its per-block match
counters over SORTED-position blocks via the inverse mapping. Because a match in any sorted block
can come from anywhere in the file, a nav under a sort resolves when the match-scan has covered all
rows (one full pass with progress — same cost class as setting the sort; scope guard: a partial
"first match in sorted order" would be a definite-looking wrong answer, so find does NOT converge);
counts/total converge and are exact exactly as today. Landing inside a sorted block re-evaluates at
most one block of scattered rows. `ls_window_match_flags` is per-served-row and works unchanged.

**FR8 — Search/jump reset on coordinate change.** Any sort state change the user can make —
set, clear, direction flip — resets an active search to idle and returns the jump slot to idle
(the filter precedent: the coordinate space changed).

**FR9 — Scan-slot behavior.** The key pass shares the single scan slot. Taking it cancels a
scanning jump (frontier gains kept) and resets search (FR8 already forces this). A jump/find that
must scan takes the slot from a building sort; under LS_INDEX_AUTO the build then resumes and
converges to ACTIVE without further caller input (the filter-scan precedent); under
LS_INDEX_MANUAL it parks (state PARKED, prefix frozen at its last converged content) until
re-driven by a new `ls_sort_set`. On a NETWORK document the pass is itself the user's explicit
demand: it drives the fetch/scan to EOF with progress and cancel — this amends the
never-full-download-streaming invariant's demand list (sort joins deep-jump / find-last / wrap as
an explicit full-pass demand; still never an UNPROMPTED background network scan). Yes: sorting an
HTTP document downloads the file — on click, visibly, cancellably.

**FR10 — Sources.** All three source kinds are in scope. mmap: full support. gzip: supported as-is;
sorted scrolling is scattered random access bounded by the existing checkpoint replay (≤ 32 MiB
inflate per cold landing) — ship and MEASURE (interview decision); the block cache bounds warm
cost. HTTP range-mode: scattered reads hit the spool for already-fetched ranges (the pass fetched
everything, so post-build scrolling is local-disk speed). The converging prefix works identically
on all three (it converges as bytes are scanned/fetched); network documents carry no wall-clock
guarantee, as everywhere.

**FR11 — Frontend behavior (macOS is the template; GTK ports it).**
- Header click on a column cycles ascending → descending → off, with a platform-conventional sort
  indicator in that header cell.
- Keyboard: ⇧⌘S (macOS) / Ctrl+Shift+S (GTK) applies the same three-state cycle to the KEYBOARD
  CURSOR's column (selection anchor column when a selection exists); on a different column it
  starts fresh ascending. macOS adds a "Sort by Column" item in a new View menu; GTK registers the
  accelerator in the single lsg_a11y table (new Sorting group, shown in the shortcuts window, with
  AT-SPI labels per the a11y baseline).
- Amendment 1: on sort, the grid shows the converging prefix immediately and repaints as it
  refines (the repaint-family rule applies); the standard scan progress affordance with cancel is
  visible for the whole build (the >500 ms rule is thereby exceeded, not merely met). Scrolling
  past the prefix mid-build shows the existing not-yet-servable presentation until ACTIVE. On
  FAILED the frontends show a clean error and the restored pre-sort view.
- The gutter keeps showing original source row numbers. Session-only; no persistence.

**FR12 — Laziness and edge cases.** The sort machinery costs nothing (no storage, no thread, no
temp file) until the first `ls_sort_set`. An empty or fully-servable-at-open document sorts
immediately (pass completes within the call's normal async flow). Re-requesting the identical
(column, direction) on an ACTIVE sort is a no-op; on a parked/failed sort it re-runs.

## 4. Non-functional constraints

- **Cold start untouched.** Open/first-paint paths gain zero work; the existing launch benches must
  not regress (measured before/after on the same session).
- **First-sorted-rows latency (Amendment 1, measured).** On the local 10-col/10 GB mmap reference,
  a viewport-sized window at the top of the sorted view is servable — exact for the scanned region —
  within **100 ms** of `ls_sort_set`. (Sound because the bound is on serving the exact top of
  whatever has been scanned by then, not on coverage: open already guarantees ≥
  LS_OPEN_READY_MIN_ROWS rows behind the frontier, so there is always real content within the
  bound.) Network documents are exempt from wall-clock guarantees, as everywhere.
- **Memory (RAM).** Never O(rows) of anonymous process memory. Build-time ANONYMOUS-residency delta
  ≤ 2× the chunk knob at the reference workload (one named const, default 32 MiB, planner-tunable;
  merge read-buffers are derived from it — one knob, one resolver) plus the O(K) prefix structure
  (K reads LS_WINDOW_MAX_ROWS through one resolver — no second constant), and row-independent.
  Amendment 2: this bound EXCLUDES file-backed, evictable pages of the scratch mappings (runs /
  permutation / inverse mapping) — those are disk-resident by design and reclaimable by the OS
  under pressure (the net-spool "disk-resident, not RAM-resident" precedent), so a raw `ru_maxrss`
  reading may exceed the figure while the protected property holds. Steady sorted-view RSS is
  O(window + checkpoints + sorted-block counters), as today.
- **Disk (ephemeral).** Runs + permutation + inverse mapping live in temp storage under the same
  discipline as the gzip checkpoint spill and the net spool: platform temp dir via ONE shared
  resolver, mode 0600, unlinked immediately, gone at ls_close/process exit, never reused across
  opens. Peak ≤ 48 bytes per data row (transient runs) with ≤ 16 bytes per data row retained while
  the sort is active — at the 200M-row reference: ≤ ~9.6 GB peak, ~3.2 GB retained. Disk exhaustion
  is a clean FAILED, view restored.
- **Speed (measured, not claimed).** The key pass on the 10-col/10 GB local reference completes
  within 3× the existing full-file search-scan wall time on the same machine and build session
  (same-session before/after delta reported to the reviewer). Direction flip on a built sort is
  O(1) — no scan state change. Sorted-window serving on mmap stays within the interactive window
  budget; gzip sorted-scroll cost is measured and reported (cold and warm) as an explicit
  deliverable, not asserted.
- **Works or fails gracefully.** ReleaseSafe throughout; malformed input through the sort path
  (key extraction, re-lex compares) must never crash — the fuzzer (`tools/fuzz`) gains a sort
  entry point over the existing corpus. A ReleaseSafe panic counts as a crash.
- **Progress everywhere.** Build progress is monotone, 1.0 exactly at ACTIVE, frozen on park;
  the converging prefix is always accompanied by the visible progress affordance while BUILDING.
- **Security.** No new attack surface beyond parsing already-fuzzed content; temp files are 0600 +
  unlinked (no data left on disk); the network posture is unchanged.

## 5. Component decomposition & data flow

**api/ (root planner).** New SORTED VIEWS block in `lesssheet.h`: `ls_sort_set` / `ls_sort_clear` /
`ls_sort_poll`, the direction enum, the sort-state/status snapshot, and prose pinning FR1–FR10
(coordinate reinterpretation, the converging-prefix serving rule, slot rules, reset rules,
network-demand amendment to the never-full-download block). Lock-step frozen-surface edit; no
compat layer.

**backend/ (the bulk).** New sort module family in `src/` (implementer-named), composing with:
- the Reader/Source seam (key extraction re-lexes via the existing reader — mmap, gzip, http_range
  Sources all work unseen, as with search);
- the scan-slot machinery (`index.zig` frontier; the pass is a new job kind beside jump/match/
  filter scans);
- the view layer: a sort mode beside the filter mode; while BUILDING, window materialization and
  `ls_source_row` route through the converging top-K structure; once ACTIVE, through the
  permutation / inverse mapping (jump landing, search coordinates likewise);
- temp-storage: ONE shared platform-temp resolver (the gzip checkpoint and net spool call sites
  route through it too — single source of truth for "where ephemeral files live");
- search: sorted-block counters (granularity reuses the existing index-block knob) and
  nav-resolves-at-full-coverage semantics.

**apps/macos/.** Header sort indicator + click cycle in the grid header, View menu + ⇧⌘S wired to
the cursor column, converging-prefix live repaint + sort progress via the existing scan-progress
affordance, `CoreDocumentSession` grows the sort poll/state plumbing. Repaint rule applies
(synchronous poke on one-shot mutations).

**apps/gtk/.** Ports the settled macOS behavior: header indicator + cycle, Ctrl+Shift+S in the
lsg_a11y accelerator table (new Sorting group + shortcuts-window entry + AT-SPI labels),
converging-prefix repaint, progress and error affordances per the existing patterns.

**tools/fuzz.** New sort entry point (open corpus file → `ls_sort_set` → poll to terminal → window
reads in sorted coordinates, including reads while BUILDING).

**Data flow (build):** ls_sort_set → view flips to sorted coordinates; [scan slot] sequential pass
over source rows → filter predicate → key encode → chunk (+ top-K prefix structure serving the
converging window) → (spill run)\* → k-way merge → permutation + inverse mapping on temp disk →
state ACTIVE → accessors route row addressing through the permutation; ls_source_row =
permutation[i]; jump = inverse[source]; find = source-order match-scan tallying sorted-block
counters.

## 6. External interfaces

Only `api/lesssheet.h` (above). No new IPC, network, file-format, or persistence surface. Temp
files are private, unlinked, and invisible to other processes by content and lifetime.

## 7. Technology decisions

All approved by the user at sign-off (2026-09-06); Amendment 1 (signed 2026-09-06) adds no new
technology.

1. **In-house external merge sort in the Zig core (std-only)** — chosen. Alternatives considered:
   an embedded query/sort engine (SQLite, DuckDB-class) — excluded by the single-digit-MB size
   budget, the no-runtime-dependency stack rule, and gross mismatch with the windowed/streaming
   model; OS `sort(1)`-style external tools — not embeddable/portable, no typed comparator, no
   progress/cancel integration. External merge sort over (key, row) pairs is ~a few hundred lines
   against machinery (scan slot, Source seam, spill discipline) that already exists.
   Feature-local; no PROJECT.md change (it follows the existing "Zig std only" stack decision).
2. **On-disk permutation + inverse mapping, RAM never O(rows)** — chosen over an in-RAM permutation
   (violates the memory discipline at 200M rows) and over "counters-only" (a sorted view cannot be
   served from counters; the permutation is the minimal sufficient artifact). The Amendment 1
   converging prefix adds one bounded O(K) in-RAM structure. Feature-local.
3. **Exact typed comparator; fixed-width keys as accelerator only; no hash-equality** — chosen over
   the sketched prefix+hash scheme, whose collisions would silently misorder (violates the
   never-silent-wrong-data bar). Adversarial common-prefix data degrades to more re-lex compares —
   slower, never wrong. Feature-local.
4. **Temp storage via ONE shared platform-temp resolver** — chosen over a new frontend-supplied
   cache-dir parameter. The planner made this concrete: the previously duplicated gzip-checkpoint
   and net-spool temp paths route through the same resolver as sort (`tempdir.zig`), gate-enforced.
   Feature-local.
5. **No new production/runtime dependency of any kind.**

## 8. Acceptance criteria

Approved by the user at sign-off (2026-09-06); AC-s2/s6/s7/s14/s15 as amended and AC-s16 as added
by Amendment 1, explicitly re-signed 2026-09-06; AC-s9's memory clause clarified by Amendment 2
(anonymous residency; scratch-mapping pages excluded), signed 2026-09-06. The surfaced consequences
stand: HTTP sort is a full download on click; descending shows equal values in reverse source
order; up to 48 B/row scratch disk during the pass; while a build runs the top rows refine live
under a visible progress affordance.

Backend (contract tests unless marked otherwise):

- **AC-s1 (typed order, exact).** For fixtures per kind — integer (incl. values > 2^53 and > 64-bit
  differing in low digits), decimal (equal-prefix scale/exponent cases), date, datetime (zoned +
  naive; wrong-zonedness values), boolean, text (case-fold pairs, non-ASCII bytes, long common
  prefixes past the accelerator-key width) — ascending order equals the reference order computed by
  an independent oracle, byte-for-byte over `ls_cell`/`ls_source_row`. Non-conforming values follow
  conforming; nulls (sentinel) last; ties in source order.
- **AC-s2 (descending + direction flips).** Descending serves the ascending permutation reversed
  (ties in reverse source order); flipping direction on an ACTIVE sort completes without
  re-entering the building state (poll never leaves ACTIVE; no scan-slot activity); flipping while
  BUILDING keeps the pass running (progress monotone, no source re-scan) and the prefix re-converges
  to the new direction's exact top of the scanned region.
- **AC-s3 (coordinates).** Under sort (and under sort+filter): `ls_source_row` returns the original
  row; the gutter mapping round-trips; `ls_jump_start(source_row)` lands on that row's sorted
  position (next matching source row when filtered; EOF clamp preserved); `ls_cell_copy` and the
  copy-job rect read rows in sorted view order.
- **AC-s4 (filter composition).** Sorted row set == filtered row set: m unchanged, every filtered
  row appears exactly once, order per AC-s1. The key pass drives an incomplete filter to DONE
  (total exact). The converging prefix contains only filter-matching rows.
- **AC-s5 (find in sorted view).** With a sort active: search total equals the unsorted total for
  the same request; nav FORWARD/BACKWARD from sorted anchors returns matches in sorted-position
  order with exact 1-based positions; results reset to idle on sort set/clear/flip; window match
  flags reflect served (sorted) rows.
- **AC-s6 (converging presentation / input changes).** `ls_sort_set` serves sorted coordinates
  immediately (state BUILDING, view = converging prefix; rows beyond the prefix not servable until
  ACTIVE). Filter change and sort-column override change each trigger an automatic rebuild (poll
  re-enters building; the view serves the rebuild's converging prefix; converges to ACTIVE with the
  new order correct); dialect re-open polls sort-idle.
- **AC-s7 (failure + cancel, graceful).** Injected temp-storage failure and injected allocation
  failure during the pass each yield FAILED with the documented reason, the view RESTORED to its
  pre-sort order and fully servable, and no leaked temp file or thread. `ls_sort_clear` mid-pass
  stops the pass, polls idle, view restored to pre-sort order.
- **AC-s8 (laziness + open cost).** No sort call ⇒ no sort thread, allocation, or temp file
  (idle-state allocation discipline holds); the open/first-window path is unchanged (existing open
  determinism and launch-bench guards stay green, before/after measured).
- **AC-s9 (memory + disk bounds, measured).** Sorting a generated ≥ 10M-row fixture: build-time
  ANONYMOUS-residency delta ≤ 2× the chunk knob (+ the O(K) prefix structure) and row-independent —
  per Amendment 2 this bound excludes file-backed, evictable pages of the scratch mappings, which a
  raw `ru_maxrss` reading counts; temp-storage footprint within the §4 per-row bounds; all temp
  files unlinked-on-create; nothing remains after ls_close.
- **AC-s10 (speed, measured).** On the 10-col/10 GB local reference, key-pass wall time ≤ 3× the
  same-session full-file search scan; reported as a before/after table to the reviewer. Gzip sorted
  scrolling: cold and warm sorted-window latencies on the reference `.csv.gz` measured and reported
  (ship-and-measure decision; no pass/fail gate, but the numbers must exist in the review record).
- **AC-s11 (sources).** The full contract suite for sort (AC-s1..s7, s16) passes on mmap; a
  representative subset passes on `.csv.gz`; on an http_range fixture, `ls_sort_set` completes with
  monotone progress and correct order (the prefix converging as bytes are fetched), cancel works
  mid-fetch, and WITHOUT a sort demand no sort work or extra fetching occurs (lazy invariant
  preserved).
- **AC-s12 (slot rules).** A scanning jump is cancelled by ls_sort_set (frontier kept); a jump/find
  taking the slot parks the build (state PARKED, prefix frozen), which converges to ACTIVE under
  LS_INDEX_AUTO and stays parked under LS_INDEX_MANUAL until re-driven — all observable via the
  polls.
- **AC-s13 (fuzz).** The fuzzer's new sort entry runs the existing corpus with zero crashes/panics
  in ReleaseSafe, including window reads taken while BUILDING.
- **AC-s16 (converging prefix, exact + fast — Amendment 1).**
  (a) Correctness, deterministic (LS_INDEX_MANUAL): at any point where the pass has scanned n data
  rows, a window at the top of the sorted view serves exactly min(K, matching rows among those n)
  rows, and they equal an independent oracle's sorted top of those n rows — both directions, with
  and without a filter; view rows beyond the prefix return the not-yet-servable values.
  (b) Latency, measured: on the local 10-col/10 GB mmap reference, a viewport-sized top window in
  sorted coordinates is servable (exact for the then-scanned region) within 100 ms of
  `ls_sort_set`, reported to the reviewer alongside AC-s10's table. Network documents exempt from
  wall-clock bounds.

Frontends (component tests + headless verification per platform norms; visual checks handed to the
user):

- **AC-s14 (macOS).** Header click cycles asc→desc→off with a visible indicator; ⇧⌘S applies the
  cycle to the cursor's column; the View menu item exists; on sort the grid presents the converging
  prefix immediately and repaints as it refines, with the progress + cancel affordance visible for
  the whole build; scrolling past the prefix mid-build shows the not-yet-servable presentation;
  FAILED shows a clean error with the pre-sort view restored; gutter shows source rows; state is
  gone after close/reopen (session-only); swiftlint/warnings gates stay green.
- **AC-s15 (GTK).** Same behaviors ported — converging prefix + live repaint + progress included;
  Ctrl+Shift+S registered through the single lsg_a11y table with a Sorting group in the shortcuts
  window and AT-SPI labels; clang-format/warnings gates stay green.

## 9. Open Questions

None — all interview points were resolved in batches 1–2, the sign-off, and the Amendment 1
interview and re-sign-off (converging prefix confirmed; K = 4096 via LS_WINDOW_MAX_ROWS; 100 ms
first-window bound chosen by the user over 500/250/200 ms; find/jump scope guard confirmed).
Amendment 2 (the §4/AC-s9 anonymous-residency clarification) is SIGNED (2026-09-06).
