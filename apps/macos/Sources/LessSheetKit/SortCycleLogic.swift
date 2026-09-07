import Contracts

/// The pure sort state machine behind the ⇧⌘S cycle and the progress
/// affordance's Cancel, plus the header context menu's stateful entries.
/// Semantics are normative in `Contracts/SortControl.swift` (`SortCycling`);
/// this is the whole implementation of them.
///
/// It reads only the snapshot's column, phase-kind and direction: never the
/// failure reason, never the progress fraction, never the document's column
/// count (clamping `column` to the document is the caller's job).
///
/// Since Amendment 3 the cycle's user-facing entry point is ⇧⌘S (plus the
/// progress affordance's Cancel, which must mean the same "stop"); the header's
/// CONTEXT MENU is `headerMenu(_:for:)`, whose entries are DIRECT intents
/// rather than cycle steps, so a menu never has to be read as a state machine.
public struct SortCycle: SortCycling {
    public init() {}

    public func next(_ snapshot: SortSnapshot?, for column: Int) -> SortIntent {
        // No sort, or a different column than the current one: start fresh.
        guard let snapshot, snapshot.column == column else {
            return .sort(column: column, direction: .ascending)
        }
        switch snapshot.phase {
        case .active:
            // The three-state cycle's second and third steps.
            switch snapshot.direction {
            case .ascending: return .sort(column: column, direction: .descending)
            case .descending: return .clear
            }
        case .building, .parked:
            // Acting on a pass that has not landed means STOP — the same intent
            // Cancel issues, so the two affordances cannot drift apart.
            return .clear
        case .failed:
            // A RETRY, not an advance: the direction the user asked for was
            // never applied, so moving on would answer the wrong question.
            return .sort(column: column, direction: snapshot.direction)
        }
    }

    public func headerMenu(_ snapshot: SortSnapshot?, for column: Int) -> [SortMenuEntry] {
        // The check follows the REQUESTED direction in EVERY phase — building,
        // parked and failed included — exactly as `indicator` draws the chevron
        // in those phases, so the menu and the header can never disagree about
        // which sort was asked for.
        let requested = snapshot?.column == column ? snapshot?.direction : nil
        // Clearing is a DOCUMENT-level act: offered from every header while any
        // sort is set, so a user who opens the wrong column's menu can still
        // undo the sort.
        let anySort = snapshot != nil
        return [
            SortMenuEntry(title: SortCommand.ascendingTitle,
                          intent: .sort(column: column, direction: .ascending),
                          isChecked: requested == .ascending, isEnabled: true),
            SortMenuEntry(title: SortCommand.descendingTitle,
                          intent: .sort(column: column, direction: .descending),
                          isChecked: requested == .descending, isEnabled: true),
            SortMenuEntry(title: SortCommand.clearTitle, intent: .clear,
                          isChecked: false, isEnabled: anySort)
        ]
    }

    public func indicator(_ snapshot: SortSnapshot?, for column: Int) -> SortIndicator {
        guard let snapshot, snapshot.column == column else { return .none }
        let didFail: Bool
        if case .failed = snapshot.phase { didFail = true } else { didFail = false }
        return SortIndicator(direction: snapshot.direction, isPending: snapshot.isWorking, didFail: didFail)
    }
}
