import CLessSheet
import Contracts
import Foundation

// SORTED VIEWS: the third view kind, over the same poll/control lane the jump,
// search and filter primitives use (internally synchronized in the core, so
// unlike the window lane these take no `lock`).
//
// `sortStatus` is guarded like `filterStatus`: the off-main poll loop calls it
// once per tick, so it must never reach a `doc` that `close()` has freed. The
// two mutators run on the main actor against a live session, exactly like
// `setFilter` / `clearFilter`.
extension CoreDocumentSession {
    public func setSort(column: Int, direction: SortDirection) -> Bool {
        // A column index outside UInt32 can never be a valid column, so it is
        // rejected gracefully rather than trapping on the conversion.
        guard let abiColumn = UInt32(exactly: column) else { return false }
        return ls_sort_set(doc, abiColumn, Self.abiSortDirection(direction))
    }

    public func clearSort() {
        ls_sort_clear(doc)
    }

    public func sortStatus() -> SortSnapshot? {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return nil }
        let status = ls_sort_poll(doc)
        let phase: SortPhase
        switch status.state.rawValue {
        case ls_sort_state.RawValue(LS_SORT_BUILDING.rawValue):
            phase = .building(progress: status.progress)
        case ls_sort_state.RawValue(LS_SORT_ACTIVE.rawValue):
            phase = .active
        case ls_sort_state.RawValue(LS_SORT_PARKED.rawValue):
            phase = .parked(progress: status.progress)
        case ls_sort_state.RawValue(LS_SORT_FAILED.rawValue):
            phase = .failed(Self.sortFailure(status.error))
        default:
            return nil   // IDLE: no sort on this handle, i.e. file order
        }
        return SortSnapshot(
            phase: phase,
            column: Int(status.column),
            direction: status.direction.rawValue == ls_sort_direction.RawValue(LS_SORT_DESCENDING.rawValue)
                ? .descending : .ascending
        )
    }

    private static func abiSortDirection(_ direction: SortDirection) -> ls_sort_direction {
        switch direction {
        case .ascending: return LS_SORT_ASCENDING
        case .descending: return LS_SORT_DESCENDING
        }
    }

    /// The two causes stay distinct because the app says different things about
    /// a full disk and an out-of-memory. Anything else the core could report is
    /// mapped to `.storage` — the ephemeral-scratch failure — rather than
    /// inventing a third user-facing story.
    private static func sortFailure(_ error: ls_sort_error) -> SortFailure {
        error.rawValue == ls_sort_error.RawValue(LS_SORT_ERROR_MEMORY.rawValue) ? .memory : .storage
    }
}
