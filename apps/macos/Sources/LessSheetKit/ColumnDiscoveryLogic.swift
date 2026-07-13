import Contracts
import Foundation

// RED SEED (planner freeze) for the settings-panel-redesign discovery + Settings
// lifecycle contracts (ARCH-column-config amendment, criteria 12/13/17/19/22).
// These two types satisfy the frozen `ColumnDiscoveryRouting` /
// `SettingsLifecycleReducing` signatures so the tree COMPILES, but each method
// deliberately reproduces the PRE-amendment behavior (always list the full
// column set, no `#N` addressing, unbounded match retention, an always-expanded
// single-selection panel that never validates/collapses/clears). That makes the
// new-behavior assertions in ColumnDiscoveryTests FAIL on VALUE while the guard
// cases pass — a behavior RED, never a compile/import failure.
//
// The implementer replaces these bodies with the pinned semantics documented on
// the protocols in Sources/Contracts (ColumnDiscovery.swift / SettingsLifecycle.swift).
// This file is implementer-owned (not frozen); the contracts + tests are.

public struct ColumnDiscovery: ColumnDiscoveryRouting {
    public init() {}

    public func mode(columnCount: Int) -> ColumnDiscoveryMode {
        // SEED: the old panel always showed a list regardless of column count.
        .fullList
    }

    public func resolveDirectAddress(_ query: String, columnCount: Int) -> ColumnDirectAddress? {
        // SEED: the old panel had no `#N` direct addressing — every input is an
        // ordinary label query.
        nil
    }

    public func accumulate(_ accumulation: ColumnMatchAccumulation, matches batch: [UInt32]) -> ColumnMatchAccumulation {
        // SEED: the old search appended every match and never capped / flagged
        // overflow (it retained all matching IDs).
        ColumnMatchAccumulation(retained: accumulation.retained + batch, overflow: false)
    }
}

public struct SettingsLifecycleReducer: SettingsLifecycleReducing {
    public init() {}

    public func opened(columnCount: Int, restoring: Int?) -> SettingsLifecycleState {
        // SEED: does not validate/fall back the restored selection and leaves
        // both disclosures expanded (the old panel had no collapsible sections).
        SettingsLifecycleState(selection: restoring, query: "",
                               nullValuesExpanded: true, widthAutoFitExpanded: true)
    }

    public func closed(_ state: SettingsLifecycleState) -> SettingsLifecycleState {
        // SEED: leaves the query and disclosure expansion untouched on close.
        state
    }

    public func columnSelected(_ state: SettingsLifecycleState, column: Int?) -> SettingsLifecycleState {
        // SEED: moves the selection but wrongly collapses the disclosures (they
        // must SURVIVE a column change).
        SettingsLifecycleState(selection: column, query: state.query,
                               nullValuesExpanded: false, widthAutoFitExpanded: false)
    }

    public func disclosureSet(_ state: SettingsLifecycleState, _ disclosure: SettingsDisclosure, expanded: Bool) -> SettingsLifecycleState {
        // SEED: ignores the disclosure toggle.
        state
    }

    public func headerAction(_ state: SettingsLifecycleState, target: Int, columnCount: Int, targetInCurrentRows: Bool) -> SettingsLifecycleState {
        // SEED: does not deep-link the target (neither selects it nor replaces an
        // excluding label query with `#N`).
        state
    }

    public func parsingReopened(_ state: SettingsLifecycleState, decision: ColumnReopenDecision, columnCount: Int) -> SettingsLifecycleState {
        // SEED: does not clear the search or reset the selection on an unsafe map.
        state
    }

    public func documentOpened(columnCount: Int) -> SettingsLifecycleState {
        // SEED: no column-0 fallback and leaves disclosures expanded.
        SettingsLifecycleState(selection: nil, query: "",
                               nullValuesExpanded: true, widthAutoFitExpanded: true)
    }
}
