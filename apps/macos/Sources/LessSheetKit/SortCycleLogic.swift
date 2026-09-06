import Contracts

/// SEED (planner-authored, implementer-owned file): the sort cycle's shape with
/// none of its behavior, so the frozen `SortByColumnTests` COMPILE and fail on
/// BEHAVIOR rather than on a missing symbol — the `ColumnConfigLogic` precedent.
///
/// `next` always answers `.clear` and `indicator` always answers `.none`, so
/// every row of the pinned truth table (start-fresh, ascending -> descending,
/// retry-on-failure) and every indicator case is RED until the real state
/// machine in `SortCycling` (Sources/Contracts/SortControl.swift) is written.
public struct SortCycle: SortCycling {
    public init() {}

    public func next(_ snapshot: SortSnapshot?, for column: Int) -> SortIntent {
        .clear
    }

    public func indicator(_ snapshot: SortSnapshot?, for column: Int) -> SortIndicator {
        .none
    }
}
