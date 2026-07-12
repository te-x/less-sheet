# less-sheet backlog review

**Decision date:** 2026-07-12  
**Scope:** triage and implementation order after `.csv.gz` shipped  
**Status:** proposed for the author's sign-off

## Executive decision

The next product sequence is:

1. Close the known synchronous-responsiveness exposure (#7), and prove or close the related filtered
   navigation exposure (#6).
2. Deliver one **column usability slice**: a format-neutral column type model, bounded CSV inference with
   explicit correction, and one compact control panel that unifies type, visibility, and formatting.
3. Before changing the Source seam again, land `.csv.gz` corpus fixtures and the >8 MiB performance lane
   (#11), and re-measure the wide-row lexer margin (#9).
4. Deliver network/URL loading for CSV and `.csv.gz` only.
5. Defer Parquet implementation, its dependency decision, and remote-Parquet support to a later dedicated
   feature interview.
6. Handle the remaining work by the tie-break rules in this review rather than pretending every residual
   item has identical risk.

This preserves the author's product order—types/formatting, then network, then Parquet later—while placing one
hard safety repair before it. #7 is not discretionary polish: the current design permits a synchronous
window materialization to re-lex up to roughly 4 GiB without a progress opportunity. That directly
contradicts “non-blocking like `less`” and the project-wide rule that work exceeding about 500 ms must show
loading/progress.

Pending live passes are a continuous validation lane, not a serialized feature. Run Find, dark mode,
glass, and select-copy passes now and at each milestone boundary. A discovered correctness failure or
silent freeze immediately outranks the sequence above.

## Decision rules

The following rules break priority ties:

1. A credible silent UI freeze outranks every feature and cosmetic defect.
2. A correctness defect that hides, changes, or misrepresents source data outranks polish.
3. Verification protecting a seam must land before the next feature changes that seam.
4. User-visible usability outranks internal cleanup once safety and correctness are protected.
5. Platform expansion and internal tooling follow the current macOS product path unless they unblock it.

“Outlier” files may relax total work and memory targets, but never UI responsiveness. Cold open remains
under 500 ms and O(head)/O(viewport); any other operation that can cross about 500 ms remains off-main and
shows loading or progress by that threshold.

## Per-item verdict

`Keep` retains the item as stated. `Modify` changes its scope or completion condition. `Drop` removes it
from this backlog because it is obsolete or subsumed.

| Item | Verdict | Priority / owner | Rationale |
|---|---|---|---|
| **New: column type model** | **Keep** | P1; full feature interview | Shared core metadata and inference are the foundation for consistent formatting and later self-describing formats; explicit overrides win over inferred suggestions. |
| **New: compact type + visibility + formatting panel** | **Keep** | P1; same full feature interview | This is the user-facing usability outcome. Reuse the existing visibility model but replace the long, isolated column-checkbox section with one cohesive, scalable surface. |
| **New: column formatting** | **Modify** | P1; merge into the panel slice | Display-only, per-session formatting belongs on top of the effective column type; it must not create a second raw-value or parsing model. |
| **#5 row-count estimator accuracy** | **Keep** | Residual correctness/polish | A roughly 5000×-high estimate is misleading, but it is visibly marked estimated and no longer creates the giant-row hang; fix after higher-risk synchronous paths. |
| **#6 navigation lane under filter for giant rows** | **Modify** | P0 measurement; repair if red | First produce a timing/work-bound proof. If the lane can cross 500 ms synchronously, it joins #7 as an immediate safety fix; if already bounded, close it with the regression proof rather than speculative code. |
| **#7 per-window aggregate scan backstop** | **Keep** | **P0 first implementation item** | The per-row cap still permits a window-wide synchronous re-lex approaching 4 GiB. Add an aggregate budget and a non-blocking partial/pending outcome; never make the UI wait for the remainder. |
| **#9 backend wide-row lexer margin** | **Modify** | P2 measurement gate | Re-measure after type inference lands because it adds head/window work. Fix only if the cold-open or synchronous-window margin is no longer robust; retain a measured margin guard either way. |
| **#10 dump-path test coverage** | **Keep** | Residual verification | The dump path is a valuable deterministic UI oracle, but it does not protect the next Source change as directly as `.csv.gz` fixtures and #11. Extend it when the control panel adds new render states. |
| **#11 csv-corpus AC6 >8 MiB perf lane** | **Keep** | **P2, before network** | The universal cold-open and huge-row budgets are currently under-proven on heavy generated cases. This must protect the shared Reader/Source seam before URL loading changes it again. |
| Dead reveal/fade machinery in the macOS app | **Keep** | Small cleanup | The overlay is now intentionally always visible, while `fadeTask`, reveal state, and scheduling remain. Remove the dead state after the usability slice or while touching the same model, with no visual redesign. |
| Unreviewed filtered-views polish | **Modify** | Live pass, then targeted fixes | Do not accept or rewrite it wholesale. Perform the pending live pass; file only observed correctness, accessibility, or finish defects. Any freeze follows rule 1. |
| `ls_header_cell_truncated` not surfaced in UI | **Keep** | Small user-visible correctness slice | The core already reports that header text was cut. Hiding that fact conflicts with “never lose a byte”; surface the same subtle truncation treatment used for body cells. |
| `ls_cell_copy`: `nav_scratch` allocation vs zero-allocation wording | **Modify** | Small documentation/implementation audit | Reconcile the guarantee with the filtered path. Do not redesign copy unless measurement shows a responsiveness or memory defect. |
| `ls_cell_copy`: reads `filter_state` outside `d.lock()` | **Keep** | Small concurrency audit/fix | Resolve the data-race/locking concern and freeze a regression proof; correctness under concurrent filter/copy activity is not optional, but the change should preserve the existing copy API and behavior. |
| Add `.csv.gz` fixtures to `tools/csvgen` | **Keep** | **P2, before network** | Now unblocked and directly protects CSV-over-gzip composition before adding a remote byte source. Generated fixtures remain hermetic; no committed generated corpus. |
| Network / URL loading | **Modify** | P3; full feature interview | Scope v1 to CSV and `.csv.gz` over network. It must have an asynchronous availability/loading model and may not put remote I/O beneath synchronous UI window calls. |
| Parquet | **Modify** | Deferred; full feature interview later | No implementation, dependency, fixture, or remote-Parquet work now. Preserve a format-neutral, parameterizable type metadata shape so the later interview does not begin from a knowingly CSV-only ABI. |
| Wide-document window byte budget | **Keep** | Residual safety hardening | Row and column counts alone do not bound a viewport full of large cells. Revisit after formatting because rendered and decoded byte costs will then be measurable; responsiveness remains mandatory. |
| Linux frontend | **Keep** | Later roadmap; full toolkit interview | It remains valuable but does not advance the current macOS dogfood path. GTK4 vs Qt and packaging/runtime cost remain undecided. |
| aidev role→skill palettes | **Keep** | Separate tooling lane | Useful internal leverage, but it is neither a user-facing less-sheet capability nor a blocker for the product sequence. Do not interleave it with core/UI feature work. |
| macOS 26 target bump | **Modify** | Deferred project-wide decision | A target bump may simplify the chromeless Liquid-Glass direction but changes the supported-user set. Require an explicit compatibility/distribution decision, not an incidental build-setting edit. |
| Pending Find live pass | **Keep** | Continuous validation, start now | Exercise result navigation, cancellation, and >500 ms progress behavior; promote observed failures by severity. |
| Pending dark-mode live pass | **Keep** | Continuous validation, start now | Required visual/accessibility validation for glass, warnings, selection, and future format states; not a reason to delay safe backend work. |
| Pending glass live pass | **Keep** | Continuous validation, start now | Confirms the signature chrome on a live compositor, which frame dumps cannot fully represent. Feed findings into the compact-panel interview. |
| Pending select-copy live pass | **Keep** | Continuous validation, start now | Confirms selection geometry, raw-value copy, progress/cancel, and clipboard behavior before the panel adds more display/raw divergence. |

No shipped `.csv.gz` implementation item remains: remove any duplicate “implement gzip” card if one still
exists. Only its newly unblocked corpus coverage remains in scope.

## Recommended implementation order

### P0 — responsiveness safety gate

1. **#7 aggregate window budget.** Choose and freeze a cumulative source-byte/work ceiling for one
   synchronous window materialization. Reaching it returns the bounded prefix immediately and marks the
   rest pending/loading; background/frontier machinery completes availability. The UI must remain usable,
   and repeated calls must make monotone progress rather than livelock on the same prefix.
2. **#6 filtered navigation proof.** Exercise giant matching and non-matching rows through the actual nav
   lane. A synchronous path capable of crossing 500 ms must be bounded or moved behind the existing
   progress machinery before feature work continues.
3. Run the four pending live passes alongside these small safety slices. They do not block planning, but a
   discovered freeze or data-corruption defect blocks release.

### P1 — column usability: type model, compact panel, formatting

Treat this as one product feature with a dedicated architect interview and two implementation stages:

1. **Core type foundation:** format-neutral metadata; bounded, lazy CSV inference; explicit per-session
   override; null/conflict state; a column-window-safe query/update surface.
2. **Frontend usability surface:** one compact panel containing type, visibility, and type-appropriate
   formatting; formatted grid rendering and automatic alignment; subtle conflict warnings; session reset.

The implementation dependency is `type foundation → panel/formatting`, but the feature should be designed
and accepted as a whole. Building a type ABI without the real panel workflows risks exposing metadata the
UI cannot use; building formatting first duplicates parsing and inference in Swift.

V1 includes text, boolean, integer, decimal, date, datetime, and null handling. Formatting includes decimal
precision/grouping, date pattern, and automatic alignment. Scientific notation is the only nice-to-have
worth considering in this slice, and only if the chosen native/standard formatter preserves exact decimal
values without a binary-floating conversion. Defer percent (scaling semantics), currency (currency and
locale policy), duration, and binary.

### P2 — protect the shared seam before network

1. Add `.csv.gz` cases to the generated corpus and remove the now-stale skip/deferral assumptions.
2. Complete #11's reproducible >8 MiB lane, covering plain CSV and `.csv.gz` where applicable.
3. Re-run #9's wide-row lexer measurements with type inference enabled. Fix a margin regression before
   network; otherwise retain the measurement as a guard and close the speculative implementation work.

These are not “test work after the feature.” They establish that the current local mmap/gzip Source and
CSV Reader remain a sound baseline before remote availability, retry, and failure states are introduced.

### P3 — network / URL loading for CSV and `.csv.gz`

Run a dedicated feature interview before design. The current gzip Source streams inflated output but owns
a complete local compressed mapping; URL input adds unavailable bytes, latency, partial failure, retry,
cancellation, and unknown completion. Therefore network is a new Source capability, not a filename tweak or
a transparent substitution under synchronous `windowSet` calls.

The feature must, at minimum:

- keep cold launch and local-file open unchanged;
- show loading/progress by about 500 ms, including initial open;
- keep all network I/O off the main/UI lane;
- make unavailable rows/cells explicitly pending rather than blank or frozen;
- bound memory and any on-disk spool/cache independently of remote object size;
- define cancellation, retry, redirects, timeouts, HTTP errors, content changes, and truncated transfers;
- compose CSV parsing and gzip inflation without a full remote download before first rows;
- remain read-only and avoid implicit durable user state.

Authentication, HTTP range use, cache lifetime, and the production networking implementation are technology
decisions for that interview. Remote Parquet is explicitly outside v1.

### Later — Parquet, then residual work

Parquet remains the next format after network unless the author changes the roadmap, but no Parquet build work
is authorized now. It requires its own format/library/build-vs-buy interview.

For residual items, use this order when capacity is otherwise equal:

1. confirmed correctness/concurrency defects (`ls_cell_copy`, header truncation);
2. observed live-pass defects and #5 estimator accuracy;
3. coverage and dead-code cleanup (#10, reveal/fade);
4. wide-document byte-budget hardening;
5. project/platform decisions (macOS 26, Linux);
6. separate internal tooling (role→skill palettes).

## Type seam cautions

### Metadata is format-neutral and parameterizable

The existing Reader seam supplies rows as UTF-8 cell buffers and currently exposes no schema/type metadata.
The new model belongs in the shared core and must not be named or shaped as “CSV inference.” Each column
needs the conceptual equivalents of:

- an optional **declared** type (reserved now; future self-describing Readers supply it);
- an optional **inferred** type with inference status/confidence and a metadata generation;
- an optional **explicit override** owned by the current logical document session;
- an **effective type**, with explicit override winning;
- type parameters where relevant (for example decimal precision/scale and datetime semantics);
- nullability/null-policy and conflict state orthogonal to the base type;
- an unknown/unsupported fallback that still renders the original value.

This is not permission to implement Parquet. It is a documentation-only compatibility constraint. The
[Apache Parquet logical-type specification](https://parquet.apache.org/docs/file-format/types/logicaltypes/)
shows why a flat CSV-only enum would be a trap: integer sign/width, decimal precision/scale, and timestamp
unit/UTC semantics are parameters, while unknown and nested types must degrade safely. The metadata shape
should allow such parameters or an extension payload without exposing any Parquet-specific constant now.

### Inference stays bounded, lazy, and stable

- Initial CSV inference may inspect only bytes/cells already available within the bounded open head and
  current column window. It may not scan the file, await the index, or decode every column before first
  paint.
- A 100k-column document must not trigger 100k eager UI controls, per-column FFI round trips, or inference
  across all body rows. Metadata retrieval and inference work follow the visible column window plus small
  overscan; off-screen columns may remain unknown until requested.
- Progressive evidence may be gathered only from already-decoded windows or explicitly budgeted sampling.
  Do not turn the lightweight row-boundary indexer into a full-cell type scan.
- Once an inferred type is published as the effective display type, ordinary scrolling must not silently
  change its alignment or formatting. Later contradictory evidence raises a conflict/proposed-revision
  state; the user accepts a correction or explicitly returns the column to Auto. Metadata generations let
  the frontend invalidate only affected visible columns.
- Work that can exceed 500 ms is asynchronous and uses the shared delayed-progress/loading affordance.

### Display and operations remain separate

Formatting is a view transform. A cell that fails its effective type is rendered as its complete available
original text with a subtle warning—never blanked, coerced, or replaced with a plausible value.

Copy, Find, filtering, and existing exact numeric predicates continue to consume the unformatted canonical
cell value (decoded/transcoded and with CSV quoting removed, but before display formatting). A type override
does not reinterpret their queries, change match counts, or make copying emit commas, rounded decimals, or
formatted dates. This preserves the existing full-cell search/copy guarantees and makes display/raw
divergence explicit rather than accidental.

All inferred types, overrides, visibility, widths, and formatting are per logical document session only.
No sidecar, preferences database, extended attribute, recent-file profile, or source-file modification is
introduced. An explicit close followed by open starts fresh.

## Compact column control panel

The new panel is a candidate for its own feature interview because it combines a new core ABI/model with a
signature macOS interaction. This review fixes the intent, not the final wireframe.

### Required composition

Reuse the existing Settings entry point and `ColumnVisibility` behavior, including the “at least one column
visible” rule. Replace the current `SettingsView` Columns section—a `ForEach` checkbox for every column—with
one compact column-management surface. Parsing controls may remain a separate section; type, visibility,
and formatting must not become three windows, three toolbar buttons, or unrelated popovers.

Recommended structure:

- a single chromeless glass panel/sheet reached from the existing Settings control;
- a searchable, virtualized column list showing visibility, column name, effective type, and a concise
  format/conflict summary in each row;
- one selected-column inspector within the same panel, with an **Auto · guessed type** control, explicit
  type choices, a reset-to-Auto action, null policy, and only the formatting controls relevant to that type;
- compact session-wide actions such as show all and reset column settings, with destructive scope stated;
- keyboard traversal, screen-reader labels, sufficient contrast in light/dark mode, and Reduce Motion
  behavior matching the existing glass UI;
- a warning treatment that is visible but does not dominate the data, plus an accessible explanation of
  the first/representative type conflict.

The list and panel open must do O(panel viewport + visible column metadata), not O(total columns). Opening it
on `wide_100k_cols` stays responsive; search or enumeration that exceeds 500 ms shows loading and remains
cancellable. A type or format change re-renders and remeasures only the affected visible column/window,
preserving manual-width precedence, horizontal anchoring, and column-windowing bounds.

A column-header context action may deep-link to that column in the same panel, but it is a shortcut to the
one model and surface—not a second formatting system.

## Parquet boundary: research now, implementation later

The earlier proposal for a “thin Parquet spike” is replaced by a **documentation-only vocabulary review**.
That honors “leave all Parquet work for later”:

- allowed now: read the public format/type specification and candidate public headers to ensure the shared
  metadata can carry parameters and unknown future kinds;
- not allowed now: reader code, prototype binaries, fixtures, dependency/vendor changes, C ABI symbols named
  for Parquet, benchmarks, or a carquet-vs-hand-built decision.

The specification also places file metadata at the tail and directs readers to use it to locate column
chunks, confirming that Parquet access patterns need their own design rather than borrowing CSV streaming
assumptions ([Parquet file layout](https://parquet.apache.org/docs/file-format/)). `carquet` remains merely
a later candidate: its project currently advertises a small C library and broad logical-type support, but
also brings codec dependencies and is not selected here
([carquet repository](https://github.com/Vitruves/carquet)).

This choice is reversible and adds no production/runtime dependency. It reduces obvious ABI rework risk
without spending implementation effort on a deferred format.

## Gap analysis and required design depth

### Full architect interviews required

| Feature | Why a full interview is required |
|---|---|
| Column types + compact panel + formatting | Defines type/null grammar, inference stability, ABI metadata, session transitions, conflict behavior, exact format semantics, scalable UI, and measurable acceptance criteria. |
| Network/URL CSV + `.csv.gz` | Chooses async Source/cache/spool behavior, networking technology, security/auth scope, errors/retry/cancel, progress, and resource limits. |
| Parquet (later) | Chooses build-vs-buy, supported schema/type/codec subset, footer/open strategy, Reader integration, bundle/licensing cost, and local/network behavior. |
| Linux frontend | Chooses GTK4 vs Qt (or another surface), deployment/runtime dependencies, native-grid strategy, packaging, and parity criteria. |

The wide-document byte budget deserves a focused architecture amendment before implementation because its
aggregate byte ceiling and partial-window semantics are user-visible. The macOS 26 bump needs explicit
product sign-off and a project-wide `PROJECT.md` update if approved, even though the mechanical edit is
small.

### Focused architect decision, then small planner/implementer slice

- #7: pin aggregate budget and partial/pending semantics, then implement against existing window/frontier
  machinery.
- #6: pin a reproducible workload and maximum synchronous work; preserve existing navigation semantics.
- #5: pin estimator error/monotonicity behavior without changing exact-count convergence.
- #9: pin the required timing margin and representative wide-row probes.

### Small planner/implementer or review slices

- #10 dump coverage and #11 perf-lane wiring;
- `.csv.gz` generator fixtures;
- dead reveal/fade removal;
- header-truncation presentation using the existing core flag;
- the two `ls_cell_copy` audit findings, provided no ABI/behavior change emerges;
- filtered-views and the four pending live passes;
- role→skill palettes in its separate tooling context.

### Newly exposed gaps to carry into feature interviews

1. **Null is not yet defined for CSV.** CSV has empty fields but no native null token; the type feature must
   distinguish empty text from null and decide whether per-column sentinel tokens are allowed.
2. **Date/datetime inference grammar is not pinned.** Locale-ambiguous dates would make inference
   nondeterministic; ISO-8601-only automatic inference is the recommended default, with explicit patterns
   for a user override.
3. **Logical session vs internal parse re-open needs a name and rule.** An explicit close/open resets all
   state. A separator/header/encoding change currently replaces the core handle while preserving some UI
   state; the type feature must decide whether that is still the same logical session and how columns map
   across a shape change.
4. **Open/loading is incomplete.** The existing delayed-progress audit records pathological local open as a
   fast-follow with no signal. Network makes a loading state mandatory, so the network slice must close this
   gap rather than expose a blank launch phase beyond 500 ms.
5. **The existing Settings column list is not wide-document safe.** Instantiating one toggle per column is
   incompatible with the 100k-column responsiveness target; virtualization/search are requirements, not
   polish.

## Open questions for the author

None block this priority assessment. The following defaults should be confirmed in the dedicated column
feature interview:

1. Treat an empty CSV field as empty text by default, not null; allow explicit per-column null sentinel(s)
   for the session.
2. Restrict automatic date/datetime inference to unambiguous ISO-8601 forms; manual type/format correction
   handles other source conventions.
3. Keep Parsing as a separate section reached through the same Settings entry point, while the one compact
   column panel owns type, visibility, and formatting.
4. Preserve column settings across an internal dialect/encoding re-open only when it remains the same user
   session and columns can be mapped safely; explicit close/open always resets everything.

