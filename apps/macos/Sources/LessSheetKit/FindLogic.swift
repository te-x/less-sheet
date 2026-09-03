import Contracts

/// The find state machine: composes requests from the draft, folds search polls
/// into the display, and decides the wrap / no-matches / stopped notices. A pure
/// value transform; the core owns the per-cell highlight verdicts
/// (`DocumentSession.windowMatchFlags`). Semantics live in
/// `Contracts/FindControl.swift`.
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
            // An empty query means "no search" — ignored, never an error.
            guard !draft.text.isEmpty else { return .ignored }
            // A concrete scope is fixed into the request, so a hidden-column
            // change only re-scopes from the next run.
            let scope: [Int]? = (visibleColumns.count == columnCount) ? nil : visibleColumns.sorted()
            return .run(.text(query: draft.text, scope: scope, caseSensitive: draft.caseSensitive))
        case .predicate:
            // Hidden columns are legal targets (the picker marks them); a column
            // outside the document is not.
            guard (0..<columnCount).contains(draft.column) else { return .rejected }
            // Ordering operators need a number; = and ≠ accept any value, the
            // empty one included (it matches empty cells).
            if draft.comparison.isOrdering, !NumericGrammar.isNumeric(draft.value) { return .rejected }
            return .run(.predicate(
                column: draft.column, comparison: draft.comparison,
                value: draft.value, caseSensitive: draft.caseSensitive
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
        // A nil (idle) poll, or a session with no active display request, never
        // resurrects or resets a display.
        guard let snapshot, let request = session.display.request else { return session }
        let old = session.display

        // Max folds so a stale poll can never regress the count or the progress;
        // totalIsFinal latches.
        let total = max(old.total, snapshot.total)
        let totalIsFinal = old.totalIsFinal || snapshot.totalIsFinal

        let progress: Double?
        switch snapshot.phase {
        case let .scanning(polled): progress = max(old.progress ?? 0, polled)
        case .done, .cancelled: progress = nil
        }

        // A landing holds until the next one lands.
        var current = old.current
        var position = old.position
        var landedThisPoll = false
        if case let .found(match, pos) = snapshot.nav {
            current = match
            position = pos
            landedThisPoll = true
        }

        // The notice derives purely from THIS snapshot, so a wrap notice
        // self-clears once the wrap navigation lands as a .found poll.
        var notice: FindNotice?
        if case .exhausted = snapshot.nav {
            if snapshot.total == 0, snapshot.totalIsFinal {
                notice = .noMatches
                current = nil
                position = nil
            } else {
                notice = (navDirection == .forward) ? .wrappedToStart : .wrappedToEnd
            }
        } else if case .cancelled = snapshot.phase, !landedThisPoll {
            // A network document never scans in the background: the core
            // navigates to the next match and re-parks the scan as CANCELLED in
            // the SAME poll, so a successful network find carries both a .found
            // landing and a cancelled phase. That is an "n of m" success. Only a
            // cancelled poll that landed nothing is a genuine stop. (A
            // user-invoked stop goes through `stopped()` instead.)
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
            let anchor = current.row == .max ? UInt64.max : current.row + 1
            return SearchNav(anchor: anchor, direction: .forward)
        case .backward:
            // Anchor on the current row, not one before it: the core treats
            // backward as strictly-before, and previous-from-row-0 exhausts
            // there into the wrap.
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

    /// Esc: highlights off, counts gone — the draft is retained so re-running is
    /// one Enter.
    public func closed(_ session: FindSession) -> FindSession {
        FindSession(draft: session.draft, display: initial().display)
    }

    /// A dialect re-open or a new document clears results exactly like Esc.
    public func invalidated(_ session: FindSession) -> FindSession {
        closed(session)
    }
}
