import Contracts

/// A pure value transform the poll loop folds once per tick: whether to
/// re-issue the identical desired window (so a budget-short prefix grows) and
/// whether to keep polling. Semantics live in `Contracts/WindowPoll.swift`.
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
