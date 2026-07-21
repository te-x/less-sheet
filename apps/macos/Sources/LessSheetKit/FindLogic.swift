import Contracts

// find-seek view-model (implementer-owned; conformances pinned by the frozen
// tests, semantics pinned in Sources/Contracts/FindControl.swift and
// api/lesssheet.h).
//
// FindControl is a PURE value state machine: it never touches the core — it
// composes requests from the draft, folds search polls into the display, and
// decides wrap/no-matches/stopped notices. Viewport highlight VERDICTS are no
// longer computed here: thin-frontend-shared-core Phase 1 moved them into the
// core (ls_window_match_flags → DocumentSession.windowMatchFlags), deleting the
// former frontend `CellMatcher` duplicate. NumericGrammar (in
// Sources/Contracts/FindControl.swift) stays — FindControl.submit validates an
// ordering value with it.

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
        let draft = session.draft
        switch draft.mode {
        case .text:
            // The empty query means "no search" — ignored, never an error.
            guard !draft.text.isEmpty else { return .ignored }
            // scope nil iff every column is visible; else the ASCENDING visible
            // set is fixed into the request (hidden-column changes re-scope from
            // the next run).
            let scope: [Int]? = (visibleColumns.count == columnCount) ? nil : visibleColumns.sorted()
            // SEED (planner): the implementer marshals the shared "Match case" here
            // (`caseSensitive: draft.caseSensitive`, for BOTH branches). Hard-false until
            // then, so the caseSensitive-ON composer/behavior tests are RED.
            return .run(.text(query: draft.text, scope: scope, caseSensitive: false))
        case .predicate:
            // A column outside the document rejects (blink + shake), before any
            // core call. Hidden columns are legal targets (the picker marks them).
            guard (0..<columnCount).contains(draft.column) else { return .rejected }
            // Ordering operators need a numeric value; the empty value fails too.
            // = / ≠ accept ANY value (the empty one matches empty cells).
            if draft.comparison.isOrdering, !NumericGrammar.isNumeric(draft.value) { return .rejected }
            return .run(.predicate(
                column: draft.column, comparison: draft.comparison,
                value: draft.value, caseSensitive: false
            ))
        }
    }

    public func began(_ session: FindSession, running request: SearchRequest) -> FindSession {
        FindSession(
            draft: session.draft,
            display: FindDisplay(
                request: request,
                current: nil,
                position: nil,
                total: 0,
                totalIsFinal: false,
                progress: 0,
                notice: nil
            )
        )
    }

    public func resolved(
        _ session: FindSession,
        with snapshot: SearchSnapshot?,
        navDirection: SearchDirection
    ) -> FindSession {
        // A nil (idle) poll, or a session with no active display request (closed
        // / cleared), never resurrects or resets a display.
        guard let snapshot, let request = session.display.request else { return session }
        let old = session.display

        // Count: max fold (never regress on a stale poll); totalIsFinal latches.
        let total = max(old.total, snapshot.total)
        let totalIsFinal = old.totalIsFinal || snapshot.totalIsFinal

        // Progress: max fold while scanning; the % display ends on done/cancelled.
        let progress: Double?
        switch snapshot.phase {
        case let .scanning(polled): progress = max(old.progress ?? 0, polled)
        case .done, .cancelled: progress = nil
        }

        // Landing: a .found nav sets current + its exact position; kept on
        // non-found polls (the old landing holds until the next one lands).
        var current = old.current
        var position = old.position
        var landedThisPoll = false
        if case let .found(match, pos) = snapshot.nav {
            current = match
            position = pos
            landedThisPoll = true
        }

        // Notice derives PURELY from this snapshot (so a wrap notice self-clears
        // when the wrap navigation lands as a .found poll).
        var notice: FindNotice?
        if case .exhausted = snapshot.nav {
            if snapshot.total == 0, snapshot.totalIsFinal {
                // Zero matches anywhere (scan complete): plainly "No matches",
                // and the (never-set) landing stays cleared.
                notice = .noMatches
                current = nil
                position = nil
            } else {
                // Exhausted a direction with matches known (or still scanning):
                // wrap, keeping the current landing until the wrap lands.
                notice = (navDirection == .forward) ? .wrappedToStart : .wrappedToEnd
            }
        } else if case .cancelled = snapshot.phase, !landedThisPoll {
            // On an http_range document the core navigates to the first match
            // and then RE-PARKS the scan at LS_SEARCH_CANCELLED in the SAME
            // poll (api nfd_ac6 — it never runs a background network scan). So
            // a SUCCESSFUL network find poll carries BOTH a .found landing and
            // a cancelled phase; that is a "n of m" success, never "Stopped".
            // Only a cancelled poll that landed NOTHING is a genuine phase-stop
            // here — the count folds through when a match landed. (The
            // user-invoked stop is the separate `stopped()` method, unaffected.)
            notice = .stopped
        }

        return FindSession(
            draft: session.draft,
            display: FindDisplay(
                request: request,
                current: current,
                position: position,
                total: total,
                totalIsFinal: totalIsFinal,
                progress: progress,
                notice: notice
            )
        )
    }

    public func step(_ session: FindSession, _ direction: SearchDirection, viewportRow: UInt64) -> SearchNav? {
        guard session.display.request != nil else { return nil }
        guard let current = session.display.current else {
            // No landing yet: navigate relative to what the user sees.
            return SearchNav(anchor: viewportRow, direction: direction)
        }
        switch direction {
        case .forward:
            // next = first match at-or-after current.row + 1 (saturating).
            let anchor = current.row == .max ? UInt64.max : current.row + 1
            return SearchNav(anchor: anchor, direction: .forward)
        case .backward:
            // previous = last match STRICTLY before current.row (no decrement;
            // previous-from-row-0 exhausts core-side into the wrap).
            return SearchNav(anchor: current.row, direction: .backward)
        }
    }

    public func wrapNav(_ session: FindSession) -> SearchNav? {
        switch session.display.notice {
        case .wrappedToStart: return .fromTop
        case .wrappedToEnd: return .fromEnd
        default: return nil
        }
    }

    public func stopped(_ session: FindSession) -> FindSession {
        // The scan-cancel affordance: keep everything known so far, end the
        // progress UI, and state "Stopped". No-op when nothing is active.
        guard session.display.request != nil else { return session }
        let display = session.display
        return FindSession(
            draft: session.draft,
            display: FindDisplay(
                request: display.request,
                current: display.current,
                position: display.position,
                total: display.total,
                totalIsFinal: display.totalIsFinal,
                progress: nil,
                notice: .stopped
            )
        )
    }

    public func closed(_ session: FindSession) -> FindSession {
        // Esc: highlights off, counts gone — but the DRAFT is retained so
        // re-running is one Enter.
        FindSession(draft: session.draft, display: initial().display)
    }

    public func invalidated(_ session: FindSession) -> FindSession {
        // Dialect re-open / new document identity clears results exactly like
        // Esc, and retains the typed query.
        closed(session)
    }
}
