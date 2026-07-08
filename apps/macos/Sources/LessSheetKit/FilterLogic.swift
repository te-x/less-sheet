import Contracts

// filtered-views view-model (implementer-owned; conformance pinned by the
// frozen tests, semantics pinned in Sources/Contracts/FilterControl.swift and
// api/lesssheet.h FILTERED VIEWS).
//
// FilterControl is a PURE value transform — like FindControl, it never
// touches the core: it just maps one filter poll (+ the app-tracked document
// row count) into the banner's display fields.

/// Implements `FilterControlling` (see its pinned semantics — the
/// "Filtered — N of M rows" banner state machine).
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
            // The scan paused on slot contention; the filter MODE persists, so
            // the banner keeps showing its frozen progress (not final).
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
