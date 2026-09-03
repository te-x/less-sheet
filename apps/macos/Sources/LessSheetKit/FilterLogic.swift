import Contracts

/// Maps one filter poll plus the app-tracked document row count into the
/// "Filtered — N of M rows" banner. A pure value transform; it never touches
/// the core. Semantics live in `Contracts/FilterControl.swift`.
public struct FilterControl: FilterControlling {
    public init() {}

    public func banner(_ snapshot: FilterSnapshot?, documentRows: RowCountInfo) -> FilterBanner? {
        guard let snapshot else { return nil }
        let progress: Double?
        let matchingIsFinal: Bool
        switch snapshot.phase {
        case let .scanning(polled):
            progress = polled
            matchingIsFinal = false
        case .done:
            progress = nil
            matchingIsFinal = true
        case let .cancelled(frozen):
            // The scan paused (slot contention, or a network document that never
            // scans in the background). The filter MODE persists, so the banner
            // holds the frozen progress rather than reading as final.
            progress = frozen
            matchingIsFinal = false
        }
        return FilterBanner(
            matching: snapshot.total,
            documentRows: documentRows.count,
            documentRowsEstimated: !documentRows.isExact,
            matchingIsFinal: matchingIsFinal,
            progress: progress
        )
    }
}
