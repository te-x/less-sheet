# REVIEW-2 — walking-skeleton (round 2)

Scope: implementer's fixes for REVIEW-1 findings 1–3, confined to
`apps/macos/Sources/LessSheetApp/` (AppUI.swift reworked, FrameDump.swift added).
Reviewer re-ran the root gate independently: **GATE: PASS** (backend + apps/macos, 11 Swift
tests against the real linked core). No frozen-path drift (`git status`: implementer-owned
files only; `api/`, `Contracts/`, `Tests/`, `Package.swift`, `backend/contracts|tests` untouched).

All verification this round was headless and TCC-free per the user's constraint: stderr marker
via `open --stderr`, visuals via the app's own `LESSSHEET_DUMP_FRAME` ImageRenderer hook,
window existence via CGWindowList enumeration (no capture APIs, no osascript, no Accessibility).

## Re-verification of REVIEW-1 finding 1 (criterion 19) — FIXED, measured
- Direct exec `LessSheet.app/Contents/MacOS/LessSheet /tmp/lsprobe/tiny.csv`:
  marker `first_rows_visible_ms=163` (exactly one), frame dump inspected — sticky header
  `a | b` + data row `1 | 2` rendered. PASS.
- `open -n -a … --stderr … --args tiny.csv`: window present on screen (CGWindowList),
  exactly one marker, 148 ms. PASS.
- Missing path (`nope.csv`, direct exec): NO marker (correct — errors emit nothing), frame
  dump inspected — in-window error panel with warning icon, "File not found", and the full
  offending path. PASS.
- Root cause fix is sound: `application(_:openFiles:)` handles the bare-argv launch document
  (the unhandled launch-file event was what suppressed the WindowGroup window), with
  `reply(toOpenOrPrint:)` completing the event.

## Regression checks — all clean
- Doc-launch (`open -a` odoc path), 3 cold launches on the 1,000,002,260-byte fixture:
  markers 208 / 208 / 191 ms → median 208 ms (< 500 ms). Exactly ONE marker per launch —
  no double-open from the openFiles/argv-fallback pair (`routedLaunchOpen` guard holds;
  openFiles arrives before `applicationDidFinishLaunching`).
- Replace-document in a running instance: second `open -a big.csv` to the same instance →
  exactly one additional marker (2 total, one per open that reaches the table), document
  replaced in the existing window. Matches the contract's "one marker per document open"
  and the no-multi-window rule.
- Empty file: no marker, no dump, silent stderr — correct per contract.
- Marker fidelity (finding 3): now emitted from the data table's `.task(id: openGeneration)`
  — fires on view attach per open; the generation guard prevents re-fire on header-toggle
  re-derivation (toggle does not bump the generation) and on unrelated re-renders. Correct.
- Argv parsing (finding 2): `LaunchArguments.documentPath` skips argv[0] and `-flag value`
  pairs; the env-var-based dump hook cannot be mistaken for a path. Correct for the pinned
  entry paths.
- RSS after 1 GB open: ~96 MB (< 100 MB) — still passing, but headroom narrowed vs round 1's
  ~91 MB (delegate/activation overhead). Slice 2 must treat this budget as tight.
- Bundle: 344 KB (single-digit MB budget).

## Code review of the new code — observations, none blocking
1. Observation — `DumpTableView` is an eager structural mirror of `DataTableView` (ImageRenderer
   cannot render ScrollView/LazyVStack off-screen). Drift risk is contained: both consume the
   same `DisplayTable` and the SAME `CellRow` view, so cell content/order cannot diverge; only
   layout chrome is duplicated. Keep `CellRow` shared if either view changes.
2. Observation — the dump hook covers only the table and error states, not the launch/empty
   `MessageView` states (the empty-file check above relied on marker silence instead). Fine for
   a debug hook; extend if slice 2 automates visual checks.
3. Observation — a bare boolean flag immediately followed by the document path
   (`LessSheet -x file.csv`) swallows the path as the flag's value. Unreachable via the three
   pinned entry paths; acceptable.
4. Observation — `application(_:open urls:)` routes multiple URLs as concurrent Tasks;
   last-completed open wins. Single-file selection and near-instant opens make this benign in
   this slice; consider serializing when slice 2 adds slower opens.
5. `DocumentModel.shared` singleton + `@State` reference: consistent with the single-window,
   replace-document spec; revisit if multi-window ever lands.

## Verifiable only by human eyes (not attempted, per the TCC constraint)
- Live on-screen pixels of the real window: sticky-header pinning while scrolling the
  LazyVStack (the dump renders the eager mirror, not the on-screen ScrollView).
- File › Open… NSOpenPanel interaction and the checkable "First Row Is Header" menu item as
  rendered in the menu bar (the underlying view-model logic is covered by frozen tests).
- Finder double-click via the CSV UTI association (verified indirectly: `open -a` odoc events
  work; actual Finder UI not driven).
- Window activation/frontmost behavior.

## Verdict
**PASS**
