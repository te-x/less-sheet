// Sort-by-column contracts (ARCH-sort-by-column, app criterion AC-s14): the
// sort poll-snapshot mirror, the pure three-state CYCLE that both the header
// click and ⇧⌘S drive, and the header indicator the grid draws.
//
// The core model — a sort is a THIRD VIEW KIND that re-orders the current view
// by ONE column after a progress-reported, cancellable KEY PASS, after which
// every row accessor, jump, find, and copy speaks SORTED coordinates — is
// normative in api/lesssheet.h SORTED VIEWS and mirrored on `DocumentSession`
// (setSort / clearSort / sortStatus). The doc comments here restate exactly
// what the frozen tests pin, and nothing more.
//
// WHY A PURE CYCLE TYPE. FR11 gives the feature TWO entry points into the same
// state machine — a header click and ⇧⌘S on the keyboard cursor's column — plus
// a third (the progress affordance's Cancel) that must not contradict them.
// Routing all three through one `SortCycling.next(...)` is what keeps them from
// drifting; the display layer contributes only "which column was hit".
//
// The long-operation chrome is NOT redefined here: a building sort drives the
// existing `DelayedProgressGating` gate like every other long operation, and a
// failure renders through the app's normal error surface. This file adds only
// the sort-specific vocabulary.

// MARK: - The poll snapshot

/// Why a key pass failed (mirrors `ls_sort_error`). The two causes stay
/// distinct because the app says different things about a full disk and an
/// out-of-memory.
public enum SortFailure: Equatable, Sendable {
    /// Ephemeral scratch storage failed (disk full, I/O error, unusable temp
    /// directory) — `LS_SORT_ERROR_STORAGE`.
    case storage
    /// An allocation the pass needed failed — `LS_SORT_ERROR_MEMORY`.
    case memory
}

/// The sort's phase (mirrors `ls_sort_state` minus IDLE, which the bridge maps
/// to a nil snapshot — no sort, the rows are in file order).
///
/// `progress` is in [0, 1] and monotone within one build. `parked` is the core's
/// `LS_SORT_PARKED`: the key pass yielded the single scan slot to a jump or a
/// find. It is NOT a user cancellation and — unlike a cancelled FILTER, which
/// still serves its partial view — a parked sort serves NO sorted view at all;
/// under the app's LS_INDEX_AUTO documents it resumes and converges on its own,
/// so the UI treats it exactly like `building`.
public enum SortPhase: Equatable, Sendable {
    case building(progress: Double)
    case active
    case parked(progress: Double)
    case failed(SortFailure)
}

/// The direction of an active or requested sort (mirrors `ls_sort_direction`).
/// Descending is the ascending permutation read backwards, so equal values
/// appear in reverse source order — stated here because it is user-visible.
public enum SortDirection: Equatable, Sendable {
    case ascending
    case descending
}

/// One poll of the document's sort (mirrors `ls_sort_status`). A nil snapshot
/// means no sort is active. `column` and `direction` are the REQUESTED ones and
/// are valid in EVERY phase — including `building`, `parked`, and `failed` — so
/// the header indicator and the retry target stay on screen while a pass runs
/// or after it fails.
public struct SortSnapshot: Equatable, Sendable {
    public let phase: SortPhase
    public let column: Int
    public let direction: SortDirection

    public init(phase: SortPhase, column: Int, direction: SortDirection) {
        self.phase = phase
        self.column = column
        self.direction = direction
    }

    /// True while a key pass is outstanding (`building` or `parked`) — the
    /// condition the delayed-progress gate and the Cancel affordance key on.
    public var isWorking: Bool {
        switch phase {
        case .building, .parked: return true
        case .active, .failed: return false
        }
    }

    /// The pass's progress fraction while one is outstanding, else nil.
    public var progress: Double? {
        switch phase {
        case .building(let fraction), .parked(let fraction): return fraction
        case .active, .failed: return nil
        }
    }
}

// MARK: - The header indicator

/// What a column header cell draws (ARCH FR11). `none` for every column that is
/// not the sort column. The glyph itself is a display decision (the platform's
/// conventional ascending/descending chevron); this is only WHICH state it is in
/// and whether the sort has actually landed.
public struct SortIndicator: Equatable, Sendable {
    /// nil = this column is not sorted (draw nothing).
    public let direction: SortDirection?
    /// True while the pass for THIS column is still outstanding: the indicator
    /// is shown but the grid is NOT yet re-ordered (api/lesssheet.h "THE FLIP" —
    /// the view flips only at ACTIVE), so the header renders it in its pending
    /// styling rather than claiming an order the rows do not have.
    public let isPending: Bool
    /// True when the pass for THIS column FAILED: the indicator is shown in its
    /// error styling and a click retries (see `SortCycling`).
    public let didFail: Bool

    public init(direction: SortDirection?, isPending: Bool, didFail: Bool) {
        self.direction = direction
        self.isPending = isPending
        self.didFail = didFail
    }

    /// Draw nothing.
    public static let none = SortIndicator(direction: nil, isPending: false, didFail: false)
}

// MARK: - The cycle

/// What the app should ask the core to do next (fed straight to
/// `DocumentSession.setSort` / `clearSort`).
public enum SortIntent: Equatable, Sendable {
    case sort(column: Int, direction: SortDirection)
    case clear
}

/// The pure sort state machine. PINNED semantics (each row is a frozen test):
///
/// - `next(_:for:)` — the THREE-STATE CYCLE, the single decision behind a header
///   click, ⇧⌘S on the keyboard cursor's column, and the progress affordance's
///   Cancel. Given the current snapshot (nil = no sort) and the column the user
///   acted on:
///     * no sort, or a DIFFERENT column than the current one
///                                  → `.sort(column, .ascending)` (start fresh);
///     * same column, `.active` ascending   → `.sort(column, .descending)`;
///     * same column, `.active` descending  → `.clear` (the third state, "off");
///     * same column, `.building` / `.parked` → `.clear`. Acting on a pass that
///       has not landed means STOP — which is also exactly what Cancel means, so
///       the two affordances cannot drift apart. (`ls_sort_clear` is both verbs.)
///     * same column, `.failed`     → `.sort(column, sameDirection)` — a RETRY,
///       not an advance. Silently moving to a direction the user never saw
///       applied would be the wrong answer to "that didn't work"; the core
///       explicitly re-runs the pass for an identical request on a failed sort.
///   The cycle NEVER inspects the failure reason, the progress value, or the
///   column count — clamping a column to the document is the caller's job.
///
/// - `indicator(_:for:)` — the header cell state for `column` given the
///   snapshot: `.none` unless `column` is the snapshot's column, else the
///   requested direction with `isPending` iff the snapshot `isWorking` and
///   `didFail` iff the phase is `.failed`.
public protocol SortCycling: Sendable {
    func next(_ snapshot: SortSnapshot?, for column: Int) -> SortIntent
    func indicator(_ snapshot: SortSnapshot?, for column: Int) -> SortIndicator
}

// MARK: - The command declaration (one source for the menu and the shortcut)

/// A keyboard accelerator, described without AppKit so this module stays
/// display-free. The app maps `key` + the modifier flags onto an
/// `NSMenuItem.keyEquivalent` / `keyEquivalentModifierMask`.
public struct KeyAccelerator: Equatable, Sendable {
    public let key: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
    }
}

/// The SINGLE declaration of the sort command's menu presentation and keyboard
/// shortcut (ARCH-sort-by-column FR11 / AC-s14). Both the View-menu item and the
/// grid's key routing read THESE values, so the accelerator a user sees in the
/// menu is always the one that actually fires — the discipline the GTK frontend
/// gets from its single `lsg_a11y_shortcuts` table, applied here to the one
/// command this slice adds.
///
/// The shortcut acts on the KEYBOARD CURSOR's column (the selection anchor's
/// column when a selection exists) and runs the same `SortCycling.next(_:for:)`
/// a header click runs, so the two entry points cannot diverge.
public enum SortCommand {
    /// The menu this item belongs to. The app's main menu has no View menu today
    /// (an empty SwiftUI one was removed for launch cost); this slice adds it
    /// back with exactly this item in it.
    public static let menuSection = "View"
    public static let menuTitle = "Sort by Column"
    /// ⇧⌘S.
    public static let accelerator = KeyAccelerator(key: "s", command: true, shift: true)
}

// MARK: - DocumentSession RED seeds for the sort members

/// The sort members' RED DEFAULTS live here rather than in `DocumentSession.swift`
/// so the whole sort vocabulary — snapshot, cycle, indicator, command, and the
/// session seeds — reads as one file. They are DEFAULTS, not requirements: the
/// three members are declared in the `DocumentSession` protocol BODY, so a real
/// conformer's override is dispatched through `any DocumentSession` via the
/// witness table, which is exactly what flips the bridge tests from RED to GREEN.
public extension DocumentSession {
    /// DEFAULT (RED seed): REJECTS every request, so NOTHING ever sorts through
    /// it. A conformer wires sorting to the core by OVERRIDING this to call
    /// `ls_sort_set`.
    func setSort(column: Int, direction: SortDirection) -> Bool { false }

    /// DEFAULT (RED seed): does nothing — there is nothing to clear until
    /// `setSort` is wired.
    func clearSort() {}

    /// DEFAULT (RED seed): always nil — "no sort active".
    func sortStatus() -> SortSnapshot? { nil }
}
