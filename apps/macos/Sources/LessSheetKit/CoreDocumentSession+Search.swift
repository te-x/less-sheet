import CLessSheet
import Contracts
import Foundation

// Jump, search and filter: the poll/control lane, internally synchronized in
// the core, so unlike the window lane these take no `lock`.
//
// The three an ORPHANED background copy can still reach — `startJump`,
// `jumpStatus` and `filterStatus`, all called from the copy's frontier pre-pass
// — take `copyBufferLock` and check `isClosed`, so they can never touch a `doc`
// that `close()` has already freed. Everything else here runs on the main actor
// against a live session.
extension CoreDocumentSession {
    public func startJump(to targetRow: UInt64) {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return }
        ls_jump_start(doc, targetRow)
    }

    public func cancelJump() {
        ls_jump_cancel(doc)
    }

    /// Reports `.done` once closed, which the copy's frontier wait treats as
    /// settled — so it stops promptly instead of looping.
    public func jumpStatus() -> JumpStatus {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return .done(landedRow: 0) }
        let status = ls_jump_poll(doc)
        switch status.state.rawValue {
        case ls_jump_state.RawValue(LS_JUMP_SCANNING.rawValue):
            return .scanning(progress: status.progress)
        case ls_jump_state.RawValue(LS_JUMP_DONE.rawValue):
            return .done(landedRow: status.landed_row)
        default:
            return .idle
        }
    }

    // MARK: - Request marshaling
    //
    // Find and filter build the SAME `ls_search_request`, validated identically
    // by the core — one choke point, so case sensitivity can only ever be
    // marshaled one way. The core copies whatever it keeps, so the value/scope
    // buffers need outlive nothing but the single call below.

    /// Builds the request and hands it to `body` with its buffers alive for the
    /// call. A column index outside UInt32 can never be valid, so it rejects
    /// gracefully rather than trapping on the conversion.
    private func withSearchRequest(_ request: SearchRequest, _ body: (inout ls_search_request) -> Bool) -> Bool {
        switch request {
        case let .text(query, scope, caseSensitive):
            let value = Array(query.utf8)
            return value.withUnsafeBufferPointer { valueBuffer in
                func run(scopePtr: UnsafePointer<UInt32>?, scopeLen: Int) -> Bool {
                    var req = ls_search_request(
                        kind: LS_SEARCH_TEXT,
                        op: LS_SEARCH_OP_EQ,          // ignored for TEXT
                        column: 0,                    // ignored for TEXT
                        value_ptr: valueBuffer.baseAddress,
                        value_len: valueBuffer.count,
                        scope_ptr: scopePtr,
                        scope_len: scopeLen,
                        case_sensitive: caseSensitive
                    )
                    return body(&req)
                }
                if let scope {
                    // A nil scope means all columns; a concrete one is fixed for
                    // the search's lifetime.
                    var columns = [UInt32]()
                    columns.reserveCapacity(scope.count)
                    for index in scope {
                        guard let column = UInt32(exactly: index) else { return false }
                        columns.append(column)
                    }
                    return columns.withUnsafeBufferPointer { run(scopePtr: $0.baseAddress, scopeLen: $0.count) }
                }
                return run(scopePtr: nil, scopeLen: 0)
            }
        case let .predicate(column, comparison, value, caseSensitive):
            guard let abiColumn = UInt32(exactly: column) else { return false }
            let value = Array(value.utf8)
            return value.withUnsafeBufferPointer { valueBuffer in
                var req = ls_search_request(
                    kind: LS_SEARCH_PREDICATE,
                    op: Self.abiOp(comparison),
                    column: abiColumn,
                    value_ptr: valueBuffer.baseAddress,
                    value_len: valueBuffer.count,
                    scope_ptr: nil,                   // ignored for PREDICATE
                    scope_len: 0,
                    case_sensitive: caseSensitive
                )
                return body(&req)
            }
        }
    }

    public func startSearch(_ request: SearchRequest) -> Bool {
        withSearchRequest(request) { req in ls_search_start(doc, &req) }
    }

    public func navigateSearch(_ nav: SearchNav) {
        ls_search_nav(doc, nav.anchor, Self.abiDir(nav.direction))
    }

    public func cancelSearch() {
        ls_search_cancel(doc)
    }

    public func searchStatus() -> SearchSnapshot? {
        let status = ls_search_poll(doc)
        let phase: SearchScanPhase
        switch status.state.rawValue {
        case ls_search_state.RawValue(LS_SEARCH_SCANNING.rawValue):
            phase = .scanning(progress: status.progress)
        case ls_search_state.RawValue(LS_SEARCH_DONE.rawValue):
            phase = .done
        case ls_search_state.RawValue(LS_SEARCH_CANCELLED.rawValue):
            phase = .cancelled(progress: status.progress)
        default:
            return nil   // IDLE: no search on this handle, including after a re-open
        }
        let nav: SearchNavStatus
        switch status.nav.rawValue {
        case ls_search_nav_state.RawValue(LS_SEARCH_NAV_SEARCHING.rawValue):
            nav = .searching
        case ls_search_nav_state.RawValue(LS_SEARCH_NAV_FOUND.rawValue):
            nav = .found(SearchMatch(row: status.found_row, column: Int(status.found_col)), position: status.position)
        case ls_search_nav_state.RawValue(LS_SEARCH_NAV_EXHAUSTED.rawValue):
            nav = .exhausted
        default:
            nav = .none   // LS_SEARCH_NAV_NONE
        }
        return SearchSnapshot(phase: phase, nav: nav, total: status.total, totalIsFinal: status.total_exact)
    }

    // MARK: - Filter
    //
    // `ls_source_row` looks like it belongs here but is a WINDOW-lane call per
    // the header's threading section, so it lives in `+Window` under `lock`.

    public func setFilter(_ request: SearchRequest) -> Bool {
        withSearchRequest(request) { req in ls_filter_set(doc, &req) }
    }

    public func clearFilter() {
        ls_filter_clear(doc)
    }

    /// Guarded like `jumpStatus`: an orphaned copy task calls this from
    /// `advanceFrontier` after `close()` may already have freed `doc`.
    public func filterStatus() -> FilterSnapshot? {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return nil }
        let status = ls_filter_poll(doc)
        let phase: FilterScanPhase
        switch status.state.rawValue {
        case ls_filter_state.RawValue(LS_FILTER_SCANNING.rawValue):
            phase = .scanning(progress: status.progress)
        case ls_filter_state.RawValue(LS_FILTER_DONE.rawValue):
            phase = .done
        case ls_filter_state.RawValue(LS_FILTER_CANCELLED.rawValue):
            phase = .cancelled(progress: status.progress)
        default:
            return nil   // IDLE: no filter active, i.e. the identity view
        }
        return FilterSnapshot(phase: phase, total: status.total, totalIsFinal: status.total_exact)
    }
}
