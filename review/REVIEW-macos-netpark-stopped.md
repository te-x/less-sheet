# REVIEW — macOS: network find "Stopped" mislabel parity fix

**Verdict: PASS (2 implementer rounds).** Bound to tree-hash `72433e07…`, trusted gate 159/159.
macOS parity for the same net-park mislabel the GTK frontend fixed (net-park find showed "Stopped"
instead of the match count). One non-blocking `[design]` follow-up recorded below.

## Context
On an `http_range` doc the core drives the find nav to the first match then RE-PARKS at
`LS_SEARCH_CANCELLED` in the SAME poll (`nfd_ac6`), so a successful network find poll carries a
`.found` landing AND `.cancelled` together. `FindLogic.resolved` (`FindLogic.swift:117-119`) mapped
`.cancelled → .stopped` unconditionally → mislabel.

## Frozen contract (RED-first)
- `networkFindParkedAtCancelledShowsCountNotStopped` (`FindSeekTests.swift`) — a `.cancelled` + `.found`
  landing poll must NOT read `.stopped` (count shown). Freeze `66a9a13`. Neutralized only the one
  existing assertion that had enshrined the buggy input; the genuine user-stop assertion is untouched.

## Round 1 — the `!landedThisPoll` guard
**Impl:** `FindLogic.resolved` sets `landedThisPoll = true` inside the `.found` landing branch and guards
the phase map: `else if case .cancelled = phase, !landedThisPoll { notice = .stopped }`. Net-park
(cancelled + found) → count; a landing-less cancel → `.stopped`. RED test GREEN.

**Reviewer:** 1 × `[impl]` — the guard also **regressed the durable user-invoked Cancel on LOCAL docs**.
`ViewerModel.cancelFind()` sets `.stopped` but does NOT `stopPolling()`; per the ABI (`lesssheet.h`
191-193, 764-767) a `NAV_FOUND` persists past `ls_search_cancel`, so the still-running ~100 ms poll
delivers a follow-up `cancelled + found`, which the new guard folds to the count — clobbering the
"Stopped" `cancelFind` just set. Pre-fix the unconditional branch re-asserted it (durable). The unit
tests exercise `stopped()` in isolation, so the gate was green despite the regression. `resolved()`
alone can't distinguish a user-stop follow-up from a net-park (both `cancelled + found`) → the fix
needs a signal from above.

## Round 2 — the `userStopped` latch
**Impl (`DocumentModel`, `ViewerModel.swift`):** `@ObservationIgnored var userStopped`; SET in
`cancelFind` (alongside `stopped()`); READ in `foldSearch` (after `resolved`, rebuild `FindDisplay`
forcing `notice = .stopped` while `userStopped && request != nil && notice != .stopped`, keeping all
other fields; placed BEFORE the wrap check + landing-scroll compare so no spurious wrap/scroll);
CLEARED on every fresh-state path (`submitFind`, `stepFind`, `closeFind`, doc reset, `applyFindAsFilter`,
`clearFilter`). Net-park (`userStopped` false) → the R1 count path stands; user-cancel → durable
`.stopped`. R1 `FindLogic` fix kept.

**Reviewer: PASS.** Regression closed + net-park intact; latch lifecycle comprehensive (set only in
`cancelFind`, cleared at every path that should show fresh state — no reachable stale-"Stopped");
passive refolds after a stop correctly re-assert "Stopped" (scan genuinely stopped); placement avoids
spurious wrap/scroll; `@ObservationIgnored` + main-actor access = pure control state, no race.

## Non-blocking follow-up (`[design]`) — TRACKED
No clean UNIT seam pins "user-cancel-with-landing keeps `.stopped` across the follow-up fold":
`DocumentModel` is in the `.executableTarget` `LessSheetApp` (Package.swift, frozen) which the test
target can't `@testable import`; `foldSearch`/`applyPoll`/`userStopped` are private; the `FindControl`
synthetic-snapshot seam is a layer below the model and by design maps `cancelled+found → count`.
Accepted per the codebase's established black-box env-var probe precedent (`RepaintAuditProbe`,
`StreamCopyOutcomeProbe`, `MatchFlagsFetchProbe`, `FindProbe`). Recommended follow-up: a
`LESSSHEET_FIND_USER_STOP` probe extending `FindProbe` (submit → cancel-with-landing → assert `.stopped`
holds across ≥1 follow-up poll; + a net-park companion asserting the count holds). Not a gate on this fix
(moving `DocumentModel` to a library target is a larger frozen-`Package.swift` change).

## Gate / discipline
159/159, GATE: PASS. Scope: `Sources/LessSheetKit/FindLogic.swift` + `Sources/LessSheetApp/ViewerModel.swift`.
No frozen `Contracts/`/`Tests/`/`api/` drift. Interactive network read is the author's desktop pass.
