import CLessSheet
import Contracts
import Foundation

// MARK: - Jump / search / filter (poll/control lane).
// Split out of CoreDocumentSession.swift as a same-module extension (pure code
// motion). These sit on the poll/control lane (internally synchronized in the
// core), so — unlike the window lane — they take no `lock`; the jump race
// guards take `copyBufferLock` exactly as before. `withSearchRequest` stays
// `private` (used only by `startSearch` / `setFilter` in this same file).
extension CoreDocumentSession {
    /// RACE GUARD (round 5: closes the residual UAF round 4 left — the copy
    /// task's `advanceFrontier` pre-pass calls THIS before ever reaching
    /// `copyCell`). SAME `copyBufferLock` / reasoning as `copyCell`/`close()`
    /// below: mutually exclusive with `close()`'s {set isClosed; ls_close},
    /// so an orphaned copy waiting in `advanceFrontier` can no longer touch a
    /// freed `doc` here either. A no-op once closed (nothing left to start).
    public func startJump(to targetRow: UInt64) {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return }
        ls_jump_start(doc, targetRow)
    }

    public func cancelJump() {
        ls_jump_cancel(doc)
    }

    /// RACE GUARD (round 5), same lock/reasoning as `startJump` above: once
    /// closed, reports `.done` — `advanceFrontier`'s `if case .done = ...
    /// { return }` treats that as settled and stops polling promptly, rather
    /// than looping (or touching a freed `doc` again) after a close.
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

    // MARK: - Search + filter request marshaling (shared) — ls_search_start
    // (Find) and ls_filter_set (filtered-views) both take a freshly built
    // ls_search_request, validated identically by the core (api/lesssheet.h).
    // Both sit on the poll/control lane (internally synchronized, safe from any
    // thread except concurrently with ls_close — the app stops polling before
    // close), so neither needs the window-lane lock, exactly like the jump
    // bridge. The request struct + its value/scope buffers are borrowed only
    // for the duration of the one call (the core copies what it keeps), so the
    // withUnsafeBufferPointer scopes cover exactly that call.
    //
    // NOTE: an earlier integration "rejection" on this path was mistaken for a
    // marshaling bug — it was actually a STALE LINK. SwiftPM does not track
    // liblesssheet.a as a build input (it is linked via -L / linkedLibrary in
    // Package.swift), so the test binary stayed linked against the seed
    // archive until a source edit forced a relink against the rebuilt core
    // (see the STALE-LINK GUARD in .aidev/profile.sh).

    /// Builds the `ls_search_request` for `request` and hands it to `body`
    /// (either `ls_search_start` or `ls_filter_set`) with its buffers alive
    /// for the call. A scope/column index outside UInt32 can never be a valid
    /// column — reject gracefully (false) rather than trap converting it; the
    /// core rejects genuinely out-of-range indices itself.
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
                        // "Match case" marshaled 1:1 (false = ASCII-insensitive fold,
                        // true = byte-exact) — the single ABI choke point for Find,
                        // filter, and the match-flags verdict alike.
                        case_sensitive: caseSensitive
                    )
                    return body(&req)
                }
                if let scope {
                    // nil scope means ALL columns; a concrete scope is fixed for
                    // the search's lifetime (visibility changes re-scope next run).
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
                    case_sensitive: caseSensitive     // "Match case" (see the TEXT branch)
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
            // LS_SEARCH_IDLE (no search started on this handle) -> nil snapshot;
            // a fresh session, including a dialect re-open, reports this.
            return nil
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

    // MARK: - Filter bridge (filtered-views) — over ls_filter_* / ls_source_row
    // in api/lesssheet.h. ls_filter_set / ls_filter_clear / ls_filter_poll sit
    // on the poll/control lane, exactly like the search bridge above (no
    // window-lane lock). ls_source_row, though, is grouped with ls_window_set /
    // ls_cell / ls_header_cell in the THREADING section — the WINDOW lane — so
    // it takes the same `lock` as `setWindow` (see `sourceRow` in +Window).

    public func setFilter(_ request: SearchRequest) -> Bool {
        withSearchRequest(request) { req in ls_filter_set(doc, &req) }
    }

    public func clearFilter() {
        ls_filter_clear(doc)
    }

    public func filterStatus() -> FilterSnapshot? {
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
            // LS_FILTER_IDLE -> nil snapshot; no filter active (identity view),
            // exactly like a fresh/re-opened handle's search state.
            return nil
        }
        return FilterSnapshot(phase: phase, total: status.total, totalIsFinal: status.total_exact)
    }
}
