import Contracts

// filtered-views view-model (implementer-owned; conformance pinned by the
// frozen tests, semantics pinned in Sources/Contracts/FilterControl.swift and
// api/lesssheet.h FILTERED VIEWS).
//
// SEED STUB ONLY: keeps the contract conformance compiling while the behavior
// suite is RED. Implementation lands via the aidev build loop.

/// Implements `FilterControlling` (see its pinned semantics — the
/// "Filtered — N of M rows" banner state machine).
public struct FilterControl: FilterControlling {
    public init() {}

    public func banner(_ snapshot: FilterSnapshot?, documentRows: RowCountInfo) -> FilterBanner? {
        _ = (snapshot, documentRows)
        return nil // NOT IMPLEMENTED (filtered-views seed)
    }
}
