# REVIEW-1 — csv-hardening (macOS / Swift), round 1

**Verdict: PASS** (zero blocking findings; one non-blocking, contract-bounded observation).

## Gate (measured, run by reviewer)
`bash apps/macos/.aidev/gate.sh apps/macos` → **GATE: PASS**, 53 tests, 1 suite, 0 failures.
- The gate's `CONFORMANCE_CMD` rebuilds the backend (`cd ../../backend && zig build`) and deletes
  the SwiftPM link products (`.build/*/debug/{LessSheet,*.xctest}` …) before `swift build`, so the
  stale-archive trap ([[swiftpm-stale-archive-hazard]]) is defended: the bridge tests
  (`bridgeReportsAndSurfacesTheDetectedEncoding`, `bridgeForcedEncodingBypassesDetection`,
  `bridgeSurfacesPerCellTruncationFlag`, `bridgeSearchesTheFullCellPastTheDisplayCap`) linked and
  ran against the CURRENT core .a. All passed.
- Frozen paths (`Sources/Contracts`, `Tests`, `Package.swift`) are untouched by the diff — verified
  against `git diff HEAD --stat`. No public-surface drift.

## Acceptance-criteria verification (not merely "tests pass")

**Req 11 (criterion 18) — MET.** The "Text encoding" control is a native `Picker("Text encoding", …)`
inside `Section("Parsing")` of `SettingsView` (SettingsWindow.swift:44-48), offering
`EncodingPicker.options` (Automatic + the five). Automatic surfaces the detected value via
`encodingOptionLabel(.automatic, detected:)` → "Automatic — detected: X" (GuessPills.swift:322-330).
It is NOT a control-row pill: `PillKind` remains `{header, separator, quote}` only
(ViewerModel.swift:847-851); no encoding case was added.

**Req 12 (criterion 19) — MET.** Selection routes through `model.applyDialectChange(.encoding(...))`
(SettingsWindow.swift:99-101), the identical funnel as separator/quote/header: it calls
`composer.compose` then `Task { await self.open(path:forcing:carrying:) }` (ViewerModel.swift:210-226),
a full re-open (new session → search state dies per the DocumentSession contract; forced dialect
params carry forward). The composer carry-forward is now correct for ALL cases: `carriedEncoding`
(ViewerLogic.swift) is `EncodingOverride(current.encoding)` when `encodingForced` else `.automatic`,
threaded into every branch (separator/quote/header now pass `encoding:`), and the `.encoding(chosen)`
branch sets the chosen override without touching bytes and never fails — matching the frozen
`DialectComposing` doc-comment. The previously-RED `composerRoutesEncodingLikeADialectChange`
(including the `.automatic` re-detect case) now passes.

**Req 13 (criterion 20) — MET.** Truncation is driven purely by the core's per-cell flag
(`ls_cell_truncated`), forwarded through `RowWindow.truncated` → `DocumentModel.truncated(forRow:)` /
`visibleBodyTruncated(forRow:)` (ViewerModel.swift). It renders in the LIVE NSTableView grid:
`SheetRowView.drawTruncationMarker` is invoked in the AppKit draw path (NativeGrid.swift:610-612,
632-648), not only in the SwiftUI mirror (`SheetRow.truncationMarker`, GridView.swift). No cell
sizes are re-measured in Swift — the dot is drawn iff the flag is set. `bridgeSurfacesPerCellTruncationFlag`
and `bridgeSearchesTheFullCellPastTheDisplayCap` confirm the flag + full-cell search end-to-end.

## ABI wiring (CoreDocumentSession.swift — implementer says freeze-seeded; verified correct)
- `EncodingOverride → ls_open_options.encoding` via `abiEncodingOption` (lines 278-287) maps
  automatic→`LS_ENCODING_AUTO`(-1), utf8→0, utf16LE→1, utf16BE→2, latin1→3, windows1252→4 — matches
  api/lesssheet.h:367-372 exactly.
- `ls_dialect.encoding`/`encoding_forced` read into `DialectReport` (lines 71-81) via
  `abiEncoding(raw)` = `TextEncoding(rawValue:) ?? .utf8`; Swift rawValues 0-4 mirror the concrete
  enum (pinned by `csvHardeningABIConstantsArePinned`, passing).
- `truncated` matrix built from `ls_cell_truncated(doc, row, col)` per window cell (lines 107-114),
  parallel-shaped to `rows`. Signature matches the header (uint64 row, uint32 col).

## Non-functional (measured)
- The added work is one `ls_cell_truncated` call per window cell — a zero-alloc/total/never-fail
  accessor (api/lesssheet.h:804). This is O(window), never O(file); the flag is forwarded, never
  recomputed. Cold-start / O(viewport) is not harmed.
- Main-thread stall probe `landingsStallTheMainThreadLessThan100ms` PASSED and `layoutFramesArePinnedAtRest`
  PASSED — the live-grid draw path (now including the marker) stays within the pinned budget. No
  separate benchmark warranted for a per-cell bool forward; backend cold-start/O(head) constraints
  are owned and measured by the backend gate (green).

## Int-index Picker binding (EncodingOverride not Hashable) — correct, cannot desync
`encodingIndexBinding` (SettingsWindow.swift:88-96): the getter re-derives the index every read from
the LIVE report via `EncodingPicker.options.firstIndex(of: EncodingPicker.selection(for: model.dialect))`
(so any re-open from elsewhere keeps the picker in sync), with a safe `?? 0` fallback; the setter
bounds-checks the index and composes+re-opens through `applyDialectChange`. Since `options ==
EncodingOverride.allCases` and `selection` returns a member of that set, the round-trip is total.

## Observation (non-blocking, contract-bounded — no action required this round)
1. [contract] Header-cell truncation is not surfaced in the UI. The frozen `DocumentSession`
   exposes `headerCells: [String]?` with no truncation companion, and `RowWindow.truncated` covers
   data rows only — so a pathological giant record-1 that becomes the header (core req. 9, ABI
   `ls_header_cell_truncated`) would show no indicator on its header cell. This is NOT solvable in
   app code (the contract does not expose the flag), it is outside the frozen tests, and ARCH app
   criteria 18-20 do not require it. Recorded for awareness only; I am NOT raising a CHANGE-REQUEST —
   the win is an extreme edge case and does not justify a contract change absent a product decision.

No implementation-gap findings. Ship it.
