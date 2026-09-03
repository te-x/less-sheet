import Contracts
import Foundation

/// The fixed, type-derived alignment shared by the grid and the column
/// inspector. Conflict decoration is deliberately orthogonal to alignment.
public struct ColumnAlignmentRules: ColumnAligning {
    public init() {}

    public func alignment(for kind: ColumnKind, isConflict: Bool) -> ColumnTextAlignment {
        switch kind {
        case .unknown, .unsupported, .text:
            return .leading
        case .boolean:
            return .center
        case .integer, .decimal, .date, .datetime:
            return .trailing
        }
    }

    public var headerAlignment: ColumnTextAlignment { .leading }
}

public struct ColumnPanelLayout: ColumnPanelLayouting {
    public init() {}

    public func plan(for viewport: ColumnPanelViewport) -> ColumnPanelPlan {
        let total = max(viewport.totalColumns, 0)
        let count = viewport.visibleRowCount
        guard total > 0, count > 0 else { return ColumnPanelPlan(instantiatedRows: 0..<0) }

        let first = min(max(viewport.firstVisibleRow, 0), total)
        let visibleEnd = min(total, first.addingReportingOverflow(count).overflow ? total : first + count)
        let lower = max(0, first - min(first, count))
        let upper = min(total, visibleEnd.addingReportingOverflow(count).overflow ? total : visibleEnd + count)
        return ColumnPanelPlan(instantiatedRows: lower..<upper)
    }
}

public struct ColumnLabelSearch: ColumnLabelSearching {
    public init() {}
    public var batchSize: Int { columnLabelSearchBatchMax }

    public func matches(query: String, in candidates: [ColumnLabelCandidate], locale: Locale) -> [UInt32] {
        guard !query.isEmpty else { return [] }
        return candidates.compactMap { candidate in
            let text: String
            if let label = candidate.label, !label.isEmpty {
                text = label
            } else {
                let index = Int(candidate.column)
                text = "\(GenericColumnName.name(at: index)) \(index + 1)"
            }
            return text.range(of: query, options: [.caseInsensitive], locale: locale) == nil ? nil : candidate.column
        }
    }
}

public struct ColumnSessionModel: ColumnSessionModeling {
    public init() {}

    public func reset(_ settings: [Int: ColumnUserSettings]) -> [Int: ColumnUserSettings] { [:] }

    public func decide(change: ColumnReopenChange, oldCount: Int, newCount: Int,
                       oldHeaders: [ColumnHeaderIdentity]?,
                       newHeaders: [ColumnHeaderIdentity]?) -> ColumnReopenDecision {
        guard oldCount == newCount else { return .resetAll }
        switch change {
        case .headerOnly:
            return .replayOrdinally
        case .separatorQuoteEncoding:
            guard let oldHeaders, let newHeaders,
                  oldHeaders.count == oldCount, newHeaders.count == newCount,
                  !oldHeaders.contains(where: \.truncated),
                  !newHeaders.contains(where: \.truncated),
                  oldHeaders == newHeaders else { return .resetAll }
            return .replayOrdinally
        }
    }
}
