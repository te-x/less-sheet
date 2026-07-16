# Contract Change Request — thin-frontend-shared-core Phase 1 / remove the frozen refs that keep `CellMatcher` alive

Signed:  [x] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

## Grounds (tick at least one)
- [x] A. Infeasible within the current contract
- [x] B. Substantial, quantified improvement

## Context
Phase 1 AC6 says: "The Swift `CellMatcher`, its exact-decimal matcher, the `CellMatching`
protocol + matching `NumericGrammar`, and the frozen cross-check fixture are gone; the frontend
derives highlights solely from the flags buffer." Round 1 (this build) has already:
- made the CORE compute the per-cell verdicts (`ls_window_match_flags` → `window.matchFlags`,
  reusing `matcher.cellMatches`, from which `matchRecord`/`ls_search_*` are now composed), with
  `mf1`–`mf8` GREEN;
- bridged them (`CoreDocumentSession.windowMatchFlags`) with the golden `MatchFlagsBridgeTests`
  GREEN; and
- re-pointed the grid: `ViewerModel.highlights(...)` now reads the core mask (fetched once per
  materialize/search-change, indexed per cell) and the last impl reference to `CellMatcher` (the
  `cellMatcher` property) has been removed.

So `CellMatcher` (+ its private `Decimal10`) and the `CellMatching` protocol are now DEAD in the
product — kept alive ONLY by three FROZEN references the implementer may not edit. Deleting them
(AC6) is the one remaining Phase-1 step and it is a FROZEN-path edit → this request.

## If A — infeasibility
AC6 cannot be completed under the current frozen contract: removing `CellMatcher` requires
removing three references in FROZEN paths (`Sources/Contracts`, `Tests/`), which the PreToolUse
guard + the frozen-conformance gate block for the implementer.

- Attempts (≥2), each with the specific reason it failed under the current signature:
  1. Delete `struct CellMatcher` (+ private `Decimal10`) from `Sources/LessSheetKit/FindLogic.swift`
     (an IMPLEMENTATION path). → `swift build`/`swift test` fail to compile: `FindSeekTests.swift:71`
     (`let _: any CellMatching = CellMatcher()`), `FindSeekTests.swift:450` (`let matcher =
     CellMatcher()` in `frontendMatcherVerdictsAreIdenticalToTheCore`), and the `CellMatching`
     protocol at `Contracts/FindControl.swift:203` all still reference the removed symbols. Editing
     any of those three to unblock is a FROZEN-path write → blocked by the guard/gate.
  2. Shrink `CellMatcher` to a stub instead of deleting it. → still infeasible: the frozen
     cross-check test `frontendMatcherVerdictsAreIdenticalToTheCore` (`FindSeekTests.swift:445`)
     drives `matcher.matches(...)` across the whole fixture matrix and asserts byte-identity to the
     core, so the full duplicated grammar must stay as long as that test stands — the duplicate
     cannot be reduced, let alone removed.
- Failing gate / compiler / type-checker output (representative): `error: cannot find 'CellMatcher'
  in scope` at `FindSeekTests.swift:71` / `:450`; `error: cannot find type 'CellMatching' in scope`
  at `FindSeekTests.swift:71`; and the guard-contracts PreToolUse hook / `gate.sh` frozen-diff check
  refusing any edit to `Sources/Contracts/FindControl.swift` or `Tests/LessSheetKitTests/FindSeekTests.swift`.

## If B — improvement
- Dimension: code-size/complexity (dedup — the feature's whole point)
- Baseline (current contract): `CellMatcher` + its private `Decimal10` exact-decimal matcher in
  `FindLogic.swift` — a byte-identical DUPLICATE of `backend/src/matcher.zig`'s smart-case substring
  + exact-decimal grammar — plus the `CellMatching` protocol and the cross-check fixture. ≈ 200 LOC
  of duplicated matching logic in the Swift frontend (FindLogic.swift ~192–end of `CellMatcher`),
  which every future frontend would re-port.
- Proposed: delete all of it; highlights come from the core (`ls_window_match_flags`). The one
  grammar now lives once, in the core.
- Magnitude: −~200 LOC of frontend matching logic + one protocol + one fixture; removes the last
  cross-frontend duplicate this slice exists to remove.
- Evidence (how measured): the core path is proven verdict-equivalent from BOTH sides WITHOUT
  referencing `CellMatcher`: backend `mf1`–`mf8` (`backend/tests/all_tests.zig`, GREEN) pin the
  per-cell 1/0 verdicts against the core over the fixture matrix (TEXT smart-case, PREDICATE eq/ne,
  exact-decimal ordering incl. `2.0==2`, `1e2==100`, 40-digit ints, `1e400>1e399`, filtered view);
  the macOS golden `MatchFlagsBridgeTests` (GREEN) assert `windowMatchFlags` equals literals
  CAPTURED FROM THE CURRENT `CellMatcher` over the same `find.csv` cells (incl. the filtered case).
  The grid consumes the core path (`ViewerModel.highlights → windowMatchFlags`); the `cellMatcher`
  property is gone. So `CellMatcher`/`CellMatching` are dead but for the three frozen refs.
- Reviewer's independent check: <reviewer re-runs `bash .aidev/gate.sh` and confirms mf1–mf8 +
  MatchFlagsBridgeTests GREEN, and that no product code references CellMatcher/CellMatching>

## Minimal change (as a diff) — the three FROZEN removals the planner executes
1. `Sources/Contracts/FindControl.swift` — remove the `CellMatching` protocol and its doc comment
   (the `public protocol CellMatching: Sendable { func matches(...) -> Bool }` block at ~line 203).
   KEEP `enum NumericGrammar` (line 150): it is OUT OF SCOPE here — `FindControl.submit` uses it for
   ordering-value validation (`FindLogic.swift:49`) and `FindSeekTests` numeric tests exercise it
   (`:118`, `:125`). Only `CellMatcher`'s PRIVATE `Decimal10` goes (with `CellMatcher`, Round 2).
2. `Tests/LessSheetKitTests/FindSeekTests.swift:71` — delete the line
   `let _: any CellMatching = CellMatcher()` from `findContractConformancePins` (keep the
   `FindControlling` pin on line 70).
3. `Tests/LessSheetKitTests/FindSeekTests.swift:445` — delete the whole
   `@Test func frontendMatcherVerdictsAreIdenticalToTheCore()` (its doc at ~440 through the closing
   brace at ~485). Its equivalence guarantee is re-pinned by the GREEN `mf1`–`mf8` + the golden
   `MatchFlagsBridgeTests` (which no longer name `CellMatcher`).

## Cost / blast radius
- After the planner lands (1)–(3), Round 2 (implementer, IMPLEMENTATION path) deletes
  `struct CellMatcher` + its private `Decimal10` from `Sources/LessSheetKit/FindLogic.swift`,
  completing AC6. No other product code references them (verified: the only remaining hits are
  doc-comment mentions in `FrameDump.swift:256`, `FindControls.swift:11`, `DocumentSession.swift`).
- KEEP `NumericGrammar` and the `matchedRows` test helper (`FindSeekTests.swift:50`): `matchedRows`
  is still used by other tests (`:415`–`:437`), so it does NOT become dead when the cross-check test
  is removed.
- Changes EXTERNAL I/O?   [x] no    [ ] yes → this goes to the ARCHITECT, not the planner.
