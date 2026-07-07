import Contracts

// find-seek view-model + viewport matcher (implementer-owned; conformances
// pinned by the frozen tests, semantics pinned in
// Sources/Contracts/FindControl.swift and api/lesssheet.h).
//
// SEED STUBS ONLY: these keep the contract conformance compiling while the
// behavior suite is RED. Implementation lands via the aidev build loop.

/// Implements `FindControlling` (see its pinned semantics).
public struct FindControl: FindControlling {
    public init() {}

    public func initial() -> FindSession {
        FindSession(
            draft: .empty,
            display: FindDisplay(
                request: nil,
                current: nil,
                position: nil,
                total: 0,
                totalIsFinal: false,
                progress: nil,
                notice: nil
            )
        )
    }

    public func submit(_ session: FindSession, visibleColumns: [Int], columnCount: Int) -> FindSubmit {
        _ = (session, visibleColumns, columnCount)
        return .ignored // NOT IMPLEMENTED (find-seek seed)
    }

    public func began(_ session: FindSession, running request: SearchRequest) -> FindSession {
        _ = request
        return session // NOT IMPLEMENTED (find-seek seed)
    }

    public func resolved(_ session: FindSession, with snapshot: SearchSnapshot?, navDirection: SearchDirection) -> FindSession {
        _ = (snapshot, navDirection)
        return session // NOT IMPLEMENTED (find-seek seed)
    }

    public func step(_ session: FindSession, _ direction: SearchDirection, viewportRow: UInt64) -> SearchNav? {
        _ = (session, direction, viewportRow)
        return nil // NOT IMPLEMENTED (find-seek seed)
    }

    public func wrapNav(_ session: FindSession) -> SearchNav? {
        _ = session
        return nil // NOT IMPLEMENTED (find-seek seed)
    }

    public func stopped(_ session: FindSession) -> FindSession {
        session // NOT IMPLEMENTED (find-seek seed)
    }

    public func closed(_ session: FindSession) -> FindSession {
        session // NOT IMPLEMENTED (find-seek seed)
    }

    public func invalidated(_ session: FindSession) -> FindSession {
        session // NOT IMPLEMENTED (find-seek seed)
    }
}

/// Implements `CellMatching` (see its pinned semantics — verdicts must be
/// byte-identical to the core matcher's over valid-UTF-8 cell text).
public struct CellMatcher: CellMatching {
    public init() {}

    public func matches(cell: String, column: Int, under request: SearchRequest) -> Bool {
        _ = (cell, column, request)
        return false // NOT IMPLEMENTED (find-seek seed)
    }
}
