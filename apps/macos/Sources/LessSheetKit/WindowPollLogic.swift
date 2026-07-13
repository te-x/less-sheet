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
        let short = inputs.window.isShort
        let otherwiseActive = !inputs.indexComplete
            || inputs.jumpScanning || inputs.searchActive || inputs.filterOngoing
        return WindowPollDecision(
            reissueWindow: short,
            continuePolling: short || otherwiseActive
        )
    }
}
