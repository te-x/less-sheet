// Frozen behavior tests — window-budget slice, the macOS half (planner-owned).
// ARCH-window-budget AC7 / req. 8 / Technology decision 4: the pending-to-
// resolved window poll decision, implemented in LessSheetKit as `WindowPoll`
// (`WindowPolling`). Same pattern as DelayedProgressTests: the pure, no-GUI,
// fold-stable heart is pinned HERE; the live 100 ms loop, the identical
// re-request, and the reused per-cell loading placeholder (`DocumentModel`,
// AppKit — not importable by tests) are the build cell's concern.
//
// The backend half of window-budget (the 8 MiB aggregate budget, the short
// prefix, monotone no-livelock retry, the #6 nav proof) is pinned in the Zig
// suite. THIS file freezes only the ONE frontend acceptance criterion: AC7.
//
// PURE + HERMETIC — no real backend, no clock, no main actor: every test folds
// a controlled `WindowPollInputs` and asserts the (reissue, continue) decision,
// exactly as the driver would each poll tick.
//
// NO NEW ABI / NO PERCENTAGE (ARCH decision 4, non-goals): the pending suffix
// is signalled only by the short range; `WindowPollDecision` carries two
// booleans and NO fraction — these tests pin none, on purpose.
//
// WHAT EACH TEST PINS
//   windowPollConformancePin ................. signature drift fails the build.
//   AC7 budgetShortWindowKeepsPollingWhenIndexComplete  the CRUX (RED): index
//        complete + budget-short window, nothing else active → keep polling AND
//        re-issue; it must NOT treat "complete + short" as "done".
//   AC7 retriedWindowGrowsThenStopsWhenFilled  (RED→green) short → reissue+poll;
//        after the prefix grows to full → stop (no re-issue, no poll).
//   AC7 shortWindowStopsAtExactEOF ........... a prefix that reaches end-of-view
//        (fewer than requested, none more within view) → stop, never livelock.
//   AC7 desiredWindowShortnessIsIndependentOfIndexCompletion  the frozen
//        `isShort` semantic: shortness is pure window geometry — no index input.
//   AC7 scanningKeepsPollingWithFullWindow ... incomplete index, full window →
//        keep polling (existing scan poll-folding, no regression).
//   AC7 jumpSearchFilterKeepPollingWithFullWindow  each active signal alone,
//        index complete, full window → keep polling (no regression).
//   AC7 idleFullResolvedWindowStopsPolling ... complete, full, nothing active →
//        stop (idle documents cost nothing, no regression).
//
// RED SEED (planner freeze) — RED on BEHAVIOR, never compile/import: the Kit
// seed `WindowPoll.decide` reproduces the PRE-AC7 behaviour (a short window is
// not by itself a reason to keep polling / re-issue), so the AC7 "keeps
// polling / re-issues while short + index complete" assertions FAIL while the
// tree compiles (the conformance holds). The no-regression assertions are
// green-by-construction (the seed already folds the existing signals) and guard
// the build from breaking them on the way to green.
import Testing
import Contracts
import LessSheetKit

@Suite("window-budget poll (pure) — AC7")
struct WindowBudgetTests {

    // A never-short, fully-servable window (requested == returned).
    private func fullWindow(_ n: Int = 600) -> DesiredWindow {
        DesiredWindow(requestedCount: n, returnedCount: n, moreWithinView: false)
    }

    // Frozen conformance: the Kit type still satisfies the frozen signature.
    @Test func windowPollConformancePin() {
        let _: any WindowPolling = WindowPoll()
    }

    // AC7 (crux) — indexing reports COMPLETE, the first window is budget-short
    // (200 of a requested 600, more rows within the view), and no jump/search/
    // filter is active. The model must keep the request ACTIVE: continue the
    // 100 ms poll AND re-issue the identical range so the prefix can grow. RED:
    // the seed stalls (both false) because the index is complete.
    @Test func budgetShortWindowKeepsPollingWhenIndexComplete() {
        let poll = WindowPoll()
        let short = DesiredWindow(requestedCount: 600, returnedCount: 200, moreWithinView: true)
        let d = poll.decide(WindowPollInputs(
            window: short, indexComplete: true,
            jumpScanning: false, searchActive: false, filterOngoing: false
        ))
        #expect(d.continuePolling)   // must NOT stall on "index complete + short"
        #expect(d.reissueWindow)     // must retry the identical desired range
    }

    // AC7 — the retry loop: a short window keeps polling + re-issuing; once a
    // later poll's prefix has grown to cover the full requested range, the loop
    // stops (nothing else active). RED on the short tick; the filled tick is
    // green-by-construction and pins the STOP condition.
    @Test func retriedWindowGrowsThenStopsWhenFilled() {
        let poll = WindowPoll()

        // Tick 1: budget-short (400 of 600) → keep polling + re-issue. RED.
        let t1 = poll.decide(WindowPollInputs(
            window: DesiredWindow(requestedCount: 600, returnedCount: 400, moreWithinView: true),
            indexComplete: true, jumpScanning: false, searchActive: false, filterOngoing: false
        ))
        #expect(t1.continuePolling)
        #expect(t1.reissueWindow)

        // Tick 2: the prefix grew to the full requested range → stop.
        let t2 = poll.decide(WindowPollInputs(
            window: fullWindow(600),
            indexComplete: true, jumpScanning: false, searchActive: false, filterOngoing: false
        ))
        #expect(!t2.continuePolling)
        #expect(!t2.reissueWindow)
    }

    // AC7 — "stops ... when ... an exact row count proves the remainder is past
    // EOF": a short file returns fewer rows than requested, but the prefix
    // already reaches the end of the view (no more rows within view). The loop
    // must stop — never re-issue forever for rows that cannot exist.
    @Test func shortWindowStopsAtExactEOF() {
        let poll = WindowPoll()
        let atEOF = DesiredWindow(requestedCount: 600, returnedCount: 300, moreWithinView: false)
        #expect(!atEOF.isShort)   // not short: nothing more is servable
        let d = poll.decide(WindowPollInputs(
            window: atEOF, indexComplete: true,
            jumpScanning: false, searchActive: false, filterOngoing: false
        ))
        #expect(!d.continuePolling)
        #expect(!d.reissueWindow)
    }

    // AC7 — the crux, as a frozen value semantic: shortness is PURE window
    // geometry (returned < requested AND more within view). There is no index
    // input to `isShort` at all — so "index complete + short range" is still
    // short. Green-by-construction (pins the frozen type against drift).
    @Test func desiredWindowShortnessIsIndependentOfIndexCompletion() {
        // Fewer returned than requested, more within view → SHORT.
        #expect(DesiredWindow(requestedCount: 600, returnedCount: 200, moreWithinView: true).isShort)
        // Full prefix → not short.
        #expect(!DesiredWindow(requestedCount: 600, returnedCount: 600, moreWithinView: true).isShort)
        // Prefix reaches end-of-view → not short (EOF, not pending).
        #expect(!DesiredWindow(requestedCount: 600, returnedCount: 200, moreWithinView: false).isShort)
        // A zero-row request is never short.
        #expect(!DesiredWindow(requestedCount: 0, returnedCount: 0, moreWithinView: true).isShort)
    }

    // AC7 (no regression) — an INCOMPLETE index with a full window still keeps
    // polling (the frontier may advance into future scroll; the estimate is
    // still refining). Green-by-construction; guards the existing scan
    // poll-folding from being dropped on the way to green.
    @Test func scanningKeepsPollingWithFullWindow() {
        let poll = WindowPoll()
        let d = poll.decide(WindowPollInputs(
            window: fullWindow(), indexComplete: false,
            jumpScanning: false, searchActive: false, filterOngoing: false
        ))
        #expect(d.continuePolling)
    }

    // AC7 (no regression) — a jump-scan, an active search, or an ongoing filter,
    // each alone with a complete index and a full window, still keeps polling
    // (their landings/counts are still resolving). Green-by-construction; guards
    // the existing jump/search/filter poll-folding.
    @Test func jumpSearchFilterKeepPollingWithFullWindow() {
        let poll = WindowPoll()
        func decide(jump: Bool, search: Bool, filter: Bool) -> WindowPollDecision {
            poll.decide(WindowPollInputs(
                window: fullWindow(), indexComplete: true,
                jumpScanning: jump, searchActive: search, filterOngoing: filter
            ))
        }
        #expect(decide(jump: true, search: false, filter: false).continuePolling)
        #expect(decide(jump: false, search: true, filter: false).continuePolling)
        #expect(decide(jump: false, search: false, filter: true).continuePolling)
    }

    // AC7 (no regression) — a fully resolved, idle document (complete index,
    // full window, nothing active) stops polling and demands no re-issue, so it
    // costs nothing. Green-by-construction; guards against a green impl that
    // keeps a settled document spinning.
    @Test func idleFullResolvedWindowStopsPolling() {
        let poll = WindowPoll()
        let d = poll.decide(WindowPollInputs(
            window: fullWindow(), indexComplete: true,
            jumpScanning: false, searchActive: false, filterOngoing: false
        ))
        #expect(!d.continuePolling)
        #expect(!d.reissueWindow)
    }
}
