import Contracts

// window-budget pending-to-resolved poll decider (implementer-owned;
// conformance pinned by the frozen WindowBudgetTests, semantics pinned in
// Sources/Contracts/WindowPoll.swift and ARCH-window-budget AC7 / req. 8 /
// Technology decision 4).
//
// WindowPoll is a PURE value transform: the App driver (DocumentModel) folds
// one of these per 100 ms poll tick to decide whether to re-issue the identical
// desired window (so the retained prefix grows) and whether to keep the loop
// alive. It never touches the core.

/// Implements `WindowPolling` (see its pinned rules 1–4).
public struct WindowPoll: WindowPolling {
    public init() {}

    public func decide(_ inputs: WindowPollInputs) -> WindowPollDecision {
        // RED SEED (planner freeze) — RED on BEHAVIOR, never compile: this is
        // the faithful PRE-AC7 behaviour. A SHORT desired window is NOT, by
        // itself, a reason to keep polling or to re-issue the request; only an
        // incomplete index / active jump / active search / ongoing filter keeps
        // the loop alive, and a re-issue fires only while the index is still
        // scanning or a filter is ongoing. So a BUDGET-short window whose
        // indexing is already complete STALLS — `continuePolling == false`,
        // `reissueWindow == false` — the exact AC7 defect the build repairs.
        //
        // RED → GREEN (implementer): drive BOTH outputs off `window.isShort` so
        // a short window keeps polling AND re-issues regardless of index
        // completion (rule 1), while the existing activity signals still keep
        // polling alive (rule 3) — e.g.
        //   let short = inputs.window.isShort
        //   let otherwiseActive = !inputs.indexComplete || inputs.jumpScanning
        //       || inputs.searchActive || inputs.filterOngoing
        //   return WindowPollDecision(reissueWindow: short,
        //                             continuePolling: short || otherwiseActive)
        // then WIRE it into DocumentModel.applyPoll (LessSheetApp): replace the
        // inline re-materialize guard + poll-continuation return so the live
        // 100 ms loop reissues the identical (desiredStart, desiredCount)
        // request while short and stops when filled/at EOF (ARCH
        // "Pending-to-resolved flow" steps 5–7; the App wiring + the reused
        // rowLoaded placeholder are the build cell's concern, not this pure
        // test — same split as DelayedProgress).
        let otherwiseActive = !inputs.indexComplete
            || inputs.jumpScanning || inputs.searchActive || inputs.filterOngoing
        let reissue = (!inputs.indexComplete || inputs.filterOngoing) && inputs.window.isShort
        return WindowPollDecision(reissueWindow: reissue, continuePolling: otherwiseActive)
    }
}
