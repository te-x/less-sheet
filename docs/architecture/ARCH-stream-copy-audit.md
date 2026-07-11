# ARCH-stream-copy — AC9 audit: every long-running operation's delayed-progress status

Companion to `ARCH-stream-copy.md` (win #2 / AC8-AC9): the reusable "subtle
progress after ~500 ms" affordance is the frozen `Contracts.DelayedProgressGating`
protocol, implemented as `LessSheetKit.DelayedProgressGate` and driven by
`DocumentModel` (`apps/macos/Sources/LessSheetApp/ViewerModel.swift`) — ONE
shared `DelayedProgressGate` + `ContinuousClock` instance (`progressGate` /
`progressClock`) every long op below reads from, so the whole app agrees on a
single ~500 ms band. Each operation is either **wired-here** (newly gated
through that shared instance in this build), **already-compliant** (never
presents a frozen/blank UI today, no change needed), or a listed
**fast-follow** (out of this feature's "just wiring" scope).

## Copy — wired-here (AC8, the primary deliverable)
`DocumentModel.copySelection()` records a real `ContinuousClock.Instant` at
copy start (`copyStartedAt`), sleeps the shared `progressGate.threshold`
(~500 ms), then computes the real elapsed and calls `progressGate.indication
(for: .running(elapsed:, cancellable: true))`; only an `.isVisible` result
reveals the "Copying…" notice (`copyNotice`) and the reusable
`DelayedProgressSpinner` (`DelayedProgressIndicator.swift`) inside it
(`CopyNoticeView`, `OverlayView.swift`) — respecting Reduce Motion (a static
glyph instead of the spinner). The existing Task/Esc/Cancel button is
unchanged. `copyProgress` resets to `.hidden` on completion (`completeCopy`)
and cancellation (`cancelCopy`), so the indicator is gone the instant either
happens. A sub-threshold copy still shows nothing (AC2's "instant result for
small selections" is unchanged) — the only behavioral delta is the threshold
now reads the ONE shared ~500 ms band instead of a private 300 ms constant.

## Background index (auto-scan on open) — already-compliant
The live grid never renders a not-yet-scanned row as blank/frozen: any cell
past the scan frontier draws `SheetRowView.drawPendingPlaceholder` (a subtle,
static redacted-line bar) the instant it scrolls into view — see
`NativeGrid.swift`'s `rv.pending = !model.rowLoaded(forRow:)` and the
placeholder's own doc comment ("so scrolling ahead of the scan frontier reads
as 'loading', never as silently-empty data"). That is a STRONGER guarantee
than "surfaces past ~500 ms" — it surfaces immediately (0 ms) — so background
indexing already satisfies "no covered operation over ~500 ms presents a
frozen/blank UI" without new wiring. (The row-count knowledge shown while
scanning, "~12.4M rows, estimating…", is a related but separate persistent
label inside the jump popup / filter banner — not itself the frozen/blank
guard; the per-row placeholder is.)

## Jump-scan — wired-here (AC9 "just wiring")
`DocumentModel.jumpProgressIndication` feeds the SAME `progressGate` /
`progressClock`, timed from `jumpScanStartedAt` — set/cleared centrally by
the new `setJumpFlow` helper, now the ONLY place `jumpFlow` is assigned.
`JumpControlView.popup` (`OverlayView.swift`) shows the existing percentage
progress bar + Cancel only once `jumpProgressIndication.isVisible`; a scan
that lands sooner keeps showing the plain field, so the progress chrome never
flickers for a sub-threshold jump. Esc still cancels the REAL scan either way
— `field(onExit:)` is parameterized so the sub-threshold field's Esc also
calls `cancelJump()`, not merely `dismissPopups()`, so gating the VISUAL never
weakens actual cancellability. Cancellable (`cancellable: true`), matching the
jump's existing Task/Esc/Cancel affordance.

## Filter-scan — wired-here (AC9 "just wiring")
`DocumentModel.filterProgressIndication` feeds the same shared gate, timed
from `filterScanStartedAt` (set when `applyFindAsFilter` establishes a filter,
cleared by `clearFilter` / a fresh open). `FilterBannerView`
(`FilterBanner.swift`) shows its existing progress-bar + % only once
`filterProgressIndication.isVisible`; the "Filtered — N of M rows" text +
Clear (✕) stay unconditional, since that is a persistent VIEW-MODE indicator
(the filter IS the current view), not a transient long-op affordance. No
cancel is offered (`cancellable: false`) — a filter is a standing mode, not a
one-shot operation to cancel (ARCH: "Filter's indicator need not offer
cancel").

## Open (cold document open) — fast-follow, not built here
The open path is O(head) and budgeted under 500 ms end-to-end (`PROJECT.md`'s
cold-start bar); today it shows no progress affordance at all while `phase ==
.launch`. It is NOT one of the three operations ARCH-stream-copy calls out for
"just wiring" (background index / jump-scan / filter-scan) — unlike those
three, `CoreSessionOpener`/`ls_open` reports no progress value at all today
(it is one blocking call), so there is no existing signal to wire the gate to.
A genuinely pathological open exceeding ~500 ms (an adversarial head sniff)
would today present a blank launch screen; closing that gap needs a NEW
progress signal from the open path — out of this feature's scope. Listed here
as a fast-follow, not built.
