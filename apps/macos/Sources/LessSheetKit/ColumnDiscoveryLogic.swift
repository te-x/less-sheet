import Contracts
import Foundation

public struct ColumnDiscovery: ColumnDiscoveryRouting {
    public init() {}

    public func mode(columnCount: Int) -> ColumnDiscoveryMode {
        if columnCount <= 0 { return .empty }
        return columnCount <= columnDiscoveryInlineListMax ? .fullList : .searchOnly
    }

    public func resolveDirectAddress(_ query: String, columnCount: Int) -> ColumnDirectAddress? {
        guard query.first == "#" else { return nil }
        let digits = query.dropFirst().utf8
        guard !digits.isEmpty, digits.first != Character("0").asciiValue else {
            return .noSuchColumn
        }
        var value = 0
        for digit in digits {
            guard digit >= 0x30, digit <= 0x39 else { return .noSuchColumn }
            let (timesTen, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = timesTen.addingReportingOverflow(Int(digit - 0x30))
            guard !multiplyOverflow, !addOverflow else { return .noSuchColumn }
            value = next
        }
        guard value > 0, value <= columnCount else { return .noSuchColumn }
        return .column(value - 1)
    }

    public func accumulate(_ accumulation: ColumnMatchAccumulation,
                           matches batch: [UInt32]) -> ColumnMatchAccumulation {
        guard !accumulation.overflow else { return accumulation }
        let remaining = max(0, columnDiscoveryResultMax - accumulation.retained.count)
        var retained = accumulation.retained
        retained.append(contentsOf: batch.prefix(remaining))
        return ColumnMatchAccumulation(retained: retained, overflow: batch.count > remaining)
    }
}

public struct SettingsLifecycleReducer: SettingsLifecycleReducing {
    public init() {}

    public func opened(columnCount: Int, restoring: Int?) -> SettingsLifecycleState {
        SettingsLifecycleState(selection: valid(restoring, columnCount: columnCount) ?? fallback(columnCount))
    }

    public func closed(_ state: SettingsLifecycleState) -> SettingsLifecycleState {
        SettingsLifecycleState(selection: state.selection)
    }

    public func columnSelected(_ state: SettingsLifecycleState, column: Int?) -> SettingsLifecycleState {
        SettingsLifecycleState(selection: column, query: state.query,
                               nullValuesExpanded: state.nullValuesExpanded,
                               widthAutoFitExpanded: state.widthAutoFitExpanded)
    }

    public func disclosureSet(_ state: SettingsLifecycleState, _ disclosure: SettingsDisclosure,
                              expanded: Bool) -> SettingsLifecycleState {
        var next = state
        switch disclosure {
        case .nullValues: next.nullValuesExpanded = expanded
        case .widthAutoFit: next.widthAutoFitExpanded = expanded
        }
        return next
    }

    public func headerAction(_ state: SettingsLifecycleState, target: Int, columnCount: Int,
                             targetInCurrentRows: Bool) -> SettingsLifecycleState {
        guard valid(target, columnCount: columnCount) != nil else { return state }
        var next = state
        next.selection = target
        if !targetInCurrentRows { next.query = "#\(target + 1)" }
        return next
    }

    public func parsingReopened(_ state: SettingsLifecycleState, decision: ColumnReopenDecision,
                                columnCount: Int) -> SettingsLifecycleState {
        var next = state
        next.query = ""
        switch decision {
        case .replayOrdinally:
            next.selection = valid(state.selection, columnCount: columnCount) ?? fallback(columnCount)
        case .resetAll:
            next.selection = fallback(columnCount)
        }
        return next
    }

    public func documentOpened(columnCount: Int) -> SettingsLifecycleState {
        SettingsLifecycleState(selection: fallback(columnCount))
    }

    private func valid(_ selection: Int?, columnCount: Int) -> Int? {
        guard let selection, selection >= 0, selection < columnCount else { return nil }
        return selection
    }

    private func fallback(_ columnCount: Int) -> Int? { columnCount > 0 ? 0 : nil }
}
