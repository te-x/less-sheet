import Foundation

/// The settings-panel-redesign's PURE Settings-lifecycle reducer
/// (ARCH-column-config amendment, criteria 17/19/22). Settings is the sole
/// column-configuration surface; its selected column, search query, and the two
/// advanced disclosures (Null values, Width/Auto-fit) evolve DETERMINISTICALLY
/// as Settings opens/closes, columns are selected, disclosures toggle, a header
/// action deep-links a column, an internal Parsing re-open remaps, or a new
/// document begins. Nothing here is persisted — every value is session-scoped.
///
/// This owns only the SELECTION / SEARCH / DISCLOSURE presentation transitions.
/// The safe-vs-unsafe internal-re-open MAPPING decision stays with the existing
/// `ColumnSessionModeling.decide(...)` (`ColumnReopenDecision`), which this
/// reducer consumes rather than duplicates. Implemented in `LessSheetKit`
/// (`SettingsLifecycleReducer`), pinned by frozen conformance + behavior tests.

/// One of the two independent advanced disclosures in the inspector. Both are
/// collapsed whenever Settings opens; expanding one stays in effect while the
/// user changes selected columns during that opening, and ends when Settings
/// closes (ARCH criteria 12/17/22). Neither is persisted.
public enum SettingsDisclosure: Equatable, Sendable {
    case nullValues
    case widthAutoFit
}

/// The Settings surface's session-scoped selection/search/disclosure state.
/// `selection` is a 0-based logical column index, or `nil` when a document has
/// no column (an empty document has no selection).
public struct SettingsLifecycleState: Equatable, Sendable {
    public var selection: Int?
    public var query: String
    public var nullValuesExpanded: Bool
    public var widthAutoFitExpanded: Bool

    public init(selection: Int? = nil, query: String = "",
                nullValuesExpanded: Bool = false, widthAutoFitExpanded: Bool = false) {
        self.selection = selection
        self.query = query
        self.nullValuesExpanded = nullValuesExpanded
        self.widthAutoFitExpanded = widthAutoFitExpanded
    }
}

/// Pure Settings-lifecycle reducer (ARCH criteria 17/19/22). Implemented in
/// `LessSheetKit` (`SettingsLifecycleReducer`), pinned by a frozen conformance
/// test.
///
/// A 0-based selection is "valid for a document" iff `0 <= selection < columnCount`.
/// "Fall back to column 0" means: the 0-based first column when `columnCount > 0`,
/// else `nil`. Every transition below CLEARS the search query except
/// `columnSelected`, `disclosureSet`, and the header-action include case.
///
/// Pinned semantics (the spec the RED seed does NOT satisfy — the seed does not
/// validate/restore selection, never collapses a disclosure, and never clears
/// the query, i.e. the old always-expanded single-selection panel behavior):
///
/// - `opened(columnCount:restoring:)` — Settings opens (first open, or any
///   close→reopen, in the logical session): selection = `restoring` when valid,
///   else column-0 fallback; query = `""`; BOTH disclosures collapsed.
///
/// - `closed(_:)` — Settings closes: selection PRESERVED; query = `""`; BOTH
///   disclosures collapsed (disclosure expansion survives only until close).
///
/// - `columnSelected(_:column:)` — the user selects a discovery/result row or the
///   selection is programmatically moved: selection = `column`; query UNCHANGED;
///   BOTH disclosure expansions UNCHANGED (they survive a column change).
///
/// - `disclosureSet(_:_:expanded:)` — one disclosure is expanded/collapsed: only
///   that disclosure's flag changes; selection and query UNCHANGED.
///
/// - `headerAction(_:target:columnCount:targetInCurrentRows:)` — a column-header
///   action raises Settings and targets `target` (a valid 0-based column):
///   selection = `target`; disclosure expansions UNCHANGED. When
///   `targetInCurrentRows` (the target is already in the current discovery/result
///   rows) the query is PRESERVED; otherwise (above ten columns, current results
///   exclude it) the query is REPLACED with the exact direct address
///   `"#\(target + 1)"` so the target resolves as its sole result row.
///
/// - `parsingReopened(_:decision:columnCount:)` — a safe/unsafe internal Parsing
///   re-open in the SAME logical session (mapping decided by
///   `ColumnSessionModeling`): query = `""`; disclosure expansions UNCHANGED
///   (presentation state is not replayed by a re-open, but a re-open is not a
///   Settings open/close). On `.replayOrdinally` (safe) the selected ordinal is
///   PRESERVED (clamped to valid, else column-0 fallback); on `.resetAll`
///   (unsafe) selection = column-0 fallback.
///
/// - `documentOpened(columnCount:)` — an explicit new document begins a fresh
///   logical session: selection = column-0 fallback; query = `""`; BOTH
///   disclosures collapsed.
public protocol SettingsLifecycleReducing: Sendable {
    func opened(columnCount: Int, restoring: Int?) -> SettingsLifecycleState
    func closed(_ state: SettingsLifecycleState) -> SettingsLifecycleState
    func columnSelected(_ state: SettingsLifecycleState, column: Int?) -> SettingsLifecycleState
    func disclosureSet(_ state: SettingsLifecycleState, _ disclosure: SettingsDisclosure, expanded: Bool) -> SettingsLifecycleState
    func headerAction(_ state: SettingsLifecycleState, target: Int, columnCount: Int, targetInCurrentRows: Bool) -> SettingsLifecycleState
    func parsingReopened(_ state: SettingsLifecycleState, decision: ColumnReopenDecision, columnCount: Int) -> SettingsLifecycleState
    func documentOpened(columnCount: Int) -> SettingsLifecycleState
}
