# REVIEW — settings-panel-redesign (embed column config in Settings)

**Final verdict: PASS** (native Opus reviewer + `gate.sh --require-frozen apps/macos` PASS, 153 tests / 16
suites). macOS-only. `api/lesssheet.h` and `Sources/Contracts/**` byte-identical (AC23). Bound tree at review
(source): the 6 redesign Sources over frozen commit `0a64a28`; built + committed `f030923`. **First fully
native build** — see the roles migration below.

## What shipped
The approved ARCH-column-config amendment. Settings is the **sole** column-configuration surface: compact
Parsing full-width on top; column list/search + selected-column inspector side-by-side below; the separate
"Configure Columns…" sheet/chromeless panel is removed (the singular per-column "Configure Column…" header
action deep-links into Settings with that column selected). Inline inspector: Visible, Type
(Auto/guessed/override + reset), type-relevant Format. Collapsible advanced (collapsed each open): Null
sentinel, Width/Auto-fit. Discovery is adaptive: **≤10 columns → full source-order list, no search field;
>10 (incl. 100k) → no unfiltered list**, a search field + inspector, results capped at 10 + "More
matches—refine your search"; existing substring match + exact **`#N`** selector (invalid `#N` → "No such
column"). Per-session, display-only (raw copy/Find/filter invariant), O(viewport).

Implementation: `ColumnDiscoveryLogic.swift` (adaptive routing + `#N` recognizer + sticky 10-cap/overflow +
`SettingsLifecycle` reducer) satisfying the frozen `ColumnDiscovery`/`SettingsLifecycle` contracts; UI in
`SettingsWindow`/`ColumnPanelView`/`AppUI`/`ViewerModel`/`NativeGrid`. Headless probe hooks live in tracked
`AppUI.swift` and observe live rendered/model state.

## Roles migration (mid-feature)
External runner access was lost. All roles moved to the native Claude runner (committed `76ae929`):
architect=fable/high, planner=opus/max, implementer=opus/medium, reviewer=opus/high. Native roles edit the
working tree directly (no isolated-promotion); the `guard-contracts.sh` PreToolUse hook + frozen-path
gate enforce the contract. This build's implementer and reviewer were native Opus.

## Round history
- **R1 (claude impl)** — full redesign implemented; gate green (153). Reviewer → 3 `[impl]`:
  (1) `SettingsRedesignProbe.swift` untracked (would be absent from the commit); (2) null-sentinel `@State`
  survived a session reset when column 0 stayed selected; (3) the headless probes reported acceptance facts as
  literals (composition true/false, empty-rows 0, header probe bypassing `NativeGridController`) — gate could
  pass on a regressed UI.
- **R2 (claude impl)** — moved probe logic into tracked `AppUI.swift` (standalone file removed); re-keyed
  inspector identity + null-sentinel reload by `openGeneration`; probes now scan rendered markers/geometry/
  accessibility + drive the real header coordinate action. Orchestrator removed a stale untracked probe copy
  that isolated-promotion left behind (deletions don't propagate). Gate green (153).
- **Re-review (native Opus, post-migration)** — independently verified all three fixes (esp. #3: probes
  observe live state, not literals) and AC23 byte-empty diff. **PASS, no findings.**

## NFR / measurement evidence
- Frozen gate: `swift test` 153/16 PASS; AC23 SHA-pin guard green.
- AC11/AC5 release probe (`wide_100k_cols`, `LESSSHEET_SETTINGS_DISCOVERY`): `total_columns=100000
  search_field=true unfiltered_rows=0 settings_request_ids=1 open_ms=224` — search-only above 10, O(viewport)
  (one inference id, not 100k), Settings-open 224 ms < 500 ms hard bound (incl. launch overhead).

## Human gates outstanding (pre-routed by the planner/reviewer; cannot be gated headlessly)
- **AC20** — the side-by-side visual layout and the 720×620 minimum-usable window showing Visible/Type/format
  without expanding a disclosure.
- **AC16/AC20** — keyboard-only + VoiceOver traversal (incl. final-visible-column guard) under Increase
  Contrast and Reduce Motion.
- **AC11/AC5** — the 100 ms interactive target for open/select/scroll (real WindowServer measurement).
