# REVIEW — macOS maximal-strict swiftlint adoption

**Verdict: PASS (reviewer round 2).** Branch `quality/swift-strict-lint`. Native aidev cell
(planner + implementer + reviewer = opus). Orchestrator-verified: `swiftlint lint --strict Sources` = 0
(95 files), `swift build -Xswiftc -warnings-as-errors` clean, gate `--require-frozen apps/macos` PASS
(159 tests), 0 frozen drift, exactly 2 justified `swiftlint:disable` tree-wide.

the author's mandate: pick a config that enforces HIGH quality, do NOT minimize work or game the linter →
**maximal strict** (all default rules, `--strict`, nothing relaxed — not even identifier_name).

## What shipped
- **`.swiftlint.yml`** (frozen via DEPENDENCY_PATHS so the bar can't be quietly relaxed): maximal strict,
  no `disabled_rules`, no opt-in expansion — exactly the default+strict baseline.
- **Frozen `Sources/Contracts` (planner, `b31ab73`):** 29 → 0 violations. 8 public renames — `.io`→
  `.ioFailure` (Document/NetworkOpenError), `.ok`→`.served` (CopyBuilder), `HeaderOverride.on/off`→
  `.forcedOn/.forcedOff`, `SelectionDirection.up`→`.upward`, `SearchRequest.predicate` assoc-label
  `op:`→`comparison:`, `FindDraft.op`→`.comparison`. `DocumentSession.swift` split (407→347) → new frozen
  `DocumentSessionOpening.swift`. `NumericGrammar.isNumeric` complexity refactor (15→<10), behavior-exact
  (33 frozen fixtures hand-traced). Tests updated for the renames.
- **Non-frozen `LessSheetApp` + `LessSheetKit` (implementer, `7d54114`→`1287707`):** 304 → 0 violations +
  the rename call-site ripple. 27 files modified + 35 new sibling files. God-classes split by concern into
  extensions (`ViewerModel` 3250→345 /15, `NativeGrid` 2053→298 /8, `CoreDocumentSession` 1035→309 /5,
  etc.); big functions decomposed into private helpers (pure code-motion); param-count/large-tuple bundled
  into structs; ~177 short-local renames (no whitelisting).

## Rounds
- **R1 — NOT PASS, 1 `[impl]` blocker + confirmation the refactor is sound.** Reviewer confirmed the splits
  are cohesive/concern-grouped (NOT metric-gaming), all 3 implementer self-flags honest, 8/8 spot-checked
  decompositions pure code-motion. **Blocker:** the `optional_data_string_conversion` fix
  (`String(decoding: bytes, as: UTF8.self)` → `String(bytes:encoding:) ?? ""`, 9 sites) was a correctness
  regression — the two diverge on invalid UTF-8 (old substitutes U+FFFD; new returns nil → **empty string**,
  dropping the cell). Its justifying comment ("core pre-transcodes to valid UTF-8") was factually false vs
  the ABI contract (`api/lesssheet.h:342-352`, "Option A": core passes raw un-validated bytes, the consumer
  must U+FFFD-substitute at the display boundary). Blast radius: blank cells/headers on bad bytes + **silent
  data loss on Cmd-C**. The 159 tests missed it (all-valid-UTF-8 fixtures). This is the aidev loop working —
  a green build was still shipping a real data-loss bug the gate couldn't see.
- **R2 — PASS.** Fixed via one SSOT helper `String(lossyUTF8:)` (`Sources/LessSheetKit/LossyUTF8.swift`)
  wrapping the U+FFFD-preserving `String(decoding:as:)` behind a single justified
  `swiftlint:disable:next optional_data_string_conversion` citing the Option-A obligation; all 7
  invalid-UTF-8-reachable display/label/copy sites routed through it (none left on `?? ""`); false comment
  corrected. The 2 numeric sites stay `?? ""` (grammar-validated ASCII, nil unreachable, lint-preferred).
  Dead `columnLabelMetrics(_:)` + the `ColumnLabelMetric` struct a lint fix had minted for it (0 consumers,
  dead at base) deleted — public surface reduced, not grown. Reviewer re-verified the delta: both closed.

## Enablement + provenance
`QUALITY_CMD="swiftlint lint --strict Sources"` uncommented in `apps/macos/.aidev/profile.sh` — the strict
lint is now gate-enforced (host-side) alongside the existing `-Xswiftc -warnings-as-errors` conformance.
Completes the workspace quality-gate adoption: **zig fmt (backend), clang-format/GNU (gtk), swiftlint
--strict (macos), warnings-as-errors on all three** ([[quality-gates]]).

## Human verify (not gateable)
Behavior is tests-guarded, but a quick real-app pass is worthwhile given the scale of the split (open a
file, find/jump/filter/copy, column config) — the refactor is pure code-motion but it touched ~60 files.
