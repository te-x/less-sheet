// Find-seek contracts (ARCH-find-seek app criteria 7–8): the search request
// / snapshot types shared with the bridged session (mirroring the
// workspace-frozen `api/lesssheet.h` search surface), the pinned numeric
// grammar, the frontend cell-matcher seam (highlights), and the find popup's
// pure view-model. The core job model (single scan slot, counts, navigation
// anchors) is normative in api/lesssheet.h — the doc comments here restate
// exactly what the frozen tests pin.

// MARK: - Requests

/// The popup's two modes (segmented switch). UI copy renders `predicate`
/// as "Where".
public enum FindMode: Equatable, Sendable {
    case text
    case predicate
}

/// Predicate operators. Raw values are pinned to the ABI (LS_SEARCH_OP_*).
/// `equals`/`notEquals` compare cell bytes with ASCII case folding per the
/// request's `caseSensitive` (insensitive by default), no trimming. The
/// ordering four are NUMERIC (both cell and value must satisfy
/// `NumericGrammar`, compared by exact mathematical value) and ignore case.
public enum SearchOperator: Int32, CaseIterable, Equatable, Sendable {
    case equals = 0
    case notEquals = 1
    case lessThan = 2
    case greaterThan = 3
    case lessOrEqual = 4
    case greaterOrEqual = 5

    /// The operators whose value field must be numeric (< > ≤ ≥).
    public var isOrdering: Bool {
        switch self {
        case .equals, .notEquals: false
        case .lessThan, .greaterThan, .lessOrEqual, .greaterOrEqual: true
        }
    }
}

/// A composed search request — what the bridge sends to the core (mirrors
/// `ls_search_request`). `caseSensitive` (the shared "Match case" control) is
/// the ONLY thing deciding ASCII case folding for the TEXT substring and
/// predicate `=`/`≠` (ordering ops ignore it): `false` (default) = ASCII
/// case-INSENSITIVE (bytes >= 0x80 always exact); `true` = byte-exact.
/// Smart-case is retired; the flag is part of the value's identity, so
/// flipping it re-issues (restarts) the active search.
public enum SearchRequest: Equatable, Sendable {
    /// Substring text search. `scope` is the 0-based columns to evaluate — nil
    /// means ALL columns; it is FIXED for the search's lifetime (visibility
    /// changes re-scope from the next run).
    case text(query: String, scope: [Int]?, caseSensitive: Bool)
    /// Single-column typed predicate. Any column may be targeted (hidden ones
    /// included — hiding is presentation state).
    case predicate(column: Int, comparison: SearchOperator, value: String, caseSensitive: Bool)
}

// MARK: - Navigation

/// Navigation direction (mirrors `ls_search_dir`).
public enum SearchDirection: Equatable, Sendable {
    case forward
    case backward
}

/// One matched cell landing: the matching row and the match column (the
/// lowest in-scope matching column for text; the predicate column for Where).
public struct SearchMatch: Equatable, Sendable {
    public let row: UInt64
    public let column: Int

    public init(row: UInt64, column: Int) {
        self.row = row
        self.column = column
    }
}

/// A navigation command (mirrors `ls_search_nav`). PINNED anchor semantics:
///   forward  — the FIRST matching row with row >= anchor;
///   backward — the LAST matching row with row < anchor (STRICTLY).
/// This asymmetry makes every navigation a plain anchor: first-in-file =
/// `.fromTop`; next-after-R = (R + 1, forward); previous-before-R =
/// (R, backward); last-in-file = `.fromEnd` (no data row can have index
/// UInt64.max). "Previous" from the first match is therefore a core-uniform
/// exhaustion, which the view-model turns into the wrap.
public struct SearchNav: Equatable, Sendable {
    public let anchor: UInt64
    public let direction: SearchDirection

    public init(anchor: UInt64, direction: SearchDirection) {
        self.anchor = anchor
        self.direction = direction
    }

    /// First match in the file.
    public static let fromTop = SearchNav(anchor: 0, direction: .forward)
    /// Last match in the file.
    public static let fromEnd = SearchNav(anchor: .max, direction: .backward)
}

// MARK: - Poll snapshot

/// The match-scan's phase (mirrors `ls_search_state` minus IDLE, which the
/// bridge maps to a nil snapshot). `progress` is in [0, 1], monotone within
/// one search; a cancelled scan carries its frozen progress.
public enum SearchScanPhase: Equatable, Sendable {
    case scanning(progress: Double)
    case done
    case cancelled(progress: Double)
}

/// The navigation slot (mirrors `ls_search_nav_state` + the found fields).
/// `found` persists until the next navigation or a new search; `position` is
/// the 1-based rank (n) of the found row among ALL matching rows — always
/// exact, with the snapshot's total >= position.
public enum SearchNavStatus: Equatable, Sendable {
    case none
    case searching
    case found(SearchMatch, position: UInt64)
    case exhausted
}

/// One poll of the active search (mirrors `ls_search_status`). `total` (m)
/// is the number of matching rows counted so far — monotone within one
/// search, exact for the counted region; `totalIsFinal` iff the scan
/// completed (then it stops growing).
public struct SearchSnapshot: Equatable, Sendable {
    public let phase: SearchScanPhase
    public let nav: SearchNavStatus
    public let total: UInt64
    public let totalIsFinal: Bool

    public init(phase: SearchScanPhase, nav: SearchNavStatus, total: UInt64, totalIsFinal: Bool) {
        self.phase = phase
        self.nav = nav
        self.total = total
        self.totalIsFinal = totalIsFinal
    }
}

// MARK: - The pinned numeric grammar (shared with the core, verbatim)

/// The core's pinned numeric grammar (api/lesssheet.h HEADER RULE — the same
/// grammar drives the ordering predicates): strip ASCII whitespace
/// (0x09...0x0D, 0x20) from both ends; the remainder must be non-empty and
/// fully match `sign? ( digits ('.' digits?)? | '.' digits )
/// (('e'|'E') sign? digits)?` with ASCII digits and '.' only. The popup's
/// ordering-value validation and the frontend matcher both use this; the
/// frozen tests pin it to the same accept/reject fixtures as the core's.
/// (Contract-level policy, small enough to live here — like
/// `GenericColumnName`.)
public enum NumericGrammar {
    /// True iff `text` fully matches the pinned numeric grammar (see above).
    /// Composed from small single-purpose scanners over the UTF-8 bytes so the
    /// whole grammar stays byte-for-byte identical to the core's, with each
    /// scanner advancing a shared cursor.
    public static func isNumeric(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let body = trimmedBody(bytes) else { return false }
        var cursor = body.lowerBound
        consumeSign(bytes, &cursor, body.upperBound)
        guard let hasSignificand = consumeSignificand(bytes, &cursor, body.upperBound),
              hasSignificand else { return false }
        guard consumeExponent(bytes, &cursor, body.upperBound) else { return false }
        return cursor == body.upperBound
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    /// The non-empty index range left after stripping ASCII whitespace from
    /// both ends, or nil when nothing (or only whitespace) remains.
    private static func trimmedBody(_ bytes: [UInt8]) -> Range<Int>? {
        var lower = 0
        var upper = bytes.count
        while lower < upper, isWhitespace(bytes[lower]) { lower += 1 }
        while upper > lower, isWhitespace(bytes[upper - 1]) { upper -= 1 }
        return lower < upper ? lower ..< upper : nil
    }

    /// Consume one optional leading `+`/`-` at `cursor`.
    private static func consumeSign(_ bytes: [UInt8], _ cursor: inout Int, _ upper: Int) {
        guard cursor < upper else { return }
        if bytes[cursor] == UInt8(ascii: "+") || bytes[cursor] == UInt8(ascii: "-") { cursor += 1 }
    }

    /// Consume consecutive ASCII digits at `cursor`; returns how many.
    private static func consumeDigits(_ bytes: [UInt8], _ cursor: inout Int, _ upper: Int) -> Int {
        var count = 0
        while cursor < upper, isDigit(bytes[cursor]) { cursor += 1; count += 1 }
        return count
    }

    /// Consume the significand (integer digits then an optional `.`-fraction).
    /// Returns true when at least one significant digit was seen, or nil when
    /// the significand is malformed: a lone `.`, or neither integer nor
    /// fraction digits present.
    private static func consumeSignificand(_ bytes: [UInt8], _ cursor: inout Int, _ upper: Int) -> Bool? {
        let intDigits = consumeDigits(bytes, &cursor, upper)
        if cursor < upper, bytes[cursor] == UInt8(ascii: ".") {
            cursor += 1
            let fracDigits = consumeDigits(bytes, &cursor, upper)
            if intDigits == 0 && fracDigits == 0 { return nil } // lone '.'
            return true
        }
        return intDigits > 0 ? true : nil
    }

    /// Consume an optional exponent (`(e|E) sign? digits`). Returns false ONLY
    /// for a dangling exponent (a marker with no digits); true when absent.
    private static func consumeExponent(_ bytes: [UInt8], _ cursor: inout Int, _ upper: Int) -> Bool {
        guard cursor < upper else { return true }
        let marker = bytes[cursor]
        guard marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") else { return true }
        cursor += 1
        consumeSign(bytes, &cursor, upper)
        return consumeDigits(bytes, &cursor, upper) > 0
    }
}

// MARK: - The find popup's pure view-model

/// What the user is editing in the popup: the mode and both modes' fields.
/// The draft is SESSION state: it survives Esc (popup close) and dialect
/// re-opens (query-retained semantics — re-running is one Enter). It never
/// starts a search by itself — only Enter (submit) does; a keystroke must
/// never trigger a scan.
public struct FindDraft: Equatable, Sendable {
    public var mode: FindMode
    /// Text mode's query field.
    public var text: String
    /// Where mode's column picker (0-based), operator, and value field.
    public var column: Int
    public var comparison: SearchOperator
    public var value: String
    /// "Match case": false (default) = ASCII case-INSENSITIVE, true = byte-exact.
    /// SHARED across Text/Where; session-scoped; `submit` maps it 1:1 to `.caseSensitive`.
    public var caseSensitive: Bool

    public init(
        mode: FindMode = .text,
        text: String = "",
        column: Int = 0,
        comparison: SearchOperator = .equals,
        value: String = "",
        caseSensitive: Bool = false
    ) {
        self.mode = mode
        self.text = text
        self.column = column
        self.comparison = comparison
        self.value = value
        self.caseSensitive = caseSensitive
    }

    public static let empty = FindDraft()
}

/// The outcome of submitting the draft (Enter).
public enum FindSubmit: Equatable, Sendable {
    /// Start this request in the core (then navigate `.fromTop`).
    case run(SearchRequest)
    /// Invalid input: red blink + shake (Reduce Motion: blink only). No core
    /// call is made.
    case rejected
    /// Nothing to do (empty text query): no search, no error.
    case ignored
}

/// One-shot popup notices. Sentence-case user copy renders them
/// ("Wrapped to start", "Wrapped to end", "No matches", "Stopped").
public enum FindNotice: Equatable, Sendable {
    case wrappedToStart
    case wrappedToEnd
    case noMatches
    case stopped
}

/// The active search as the popup + grid render it. The grid shows match
/// highlights exactly while `request` is non-nil (re-evaluating
/// `CellMatching` over the viewport); `current` is the strong highlight.
public struct FindDisplay: Equatable, Sendable {
    /// The request behind the active search; nil = no active search
    /// (no highlights).
    public let request: SearchRequest?
    /// The current landing, if any.
    public let current: SearchMatch?
    /// 1-based position (n) of `current`; nil iff `current` is nil.
    public let position: UInt64?
    /// Matches known so far (m); the popup shows "match n of m…" while it
    /// grows and "match n of m" once final.
    public let total: UInt64
    public let totalIsFinal: Bool
    /// Scan progress in [0, 1] while scanning; nil otherwise (the % label
    /// and cancel affordance show exactly while non-nil).
    public let progress: Double?
    public let notice: FindNotice?

    public init(
        request: SearchRequest?,
        current: SearchMatch?,
        position: UInt64?,
        total: UInt64,
        totalIsFinal: Bool,
        progress: Double?,
        notice: FindNotice?
    ) {
        self.request = request
        self.current = current
        self.position = position
        self.total = total
        self.totalIsFinal = totalIsFinal
        self.progress = progress
        self.notice = notice
    }
}

/// The find feature's whole session state: the editable draft + the active
/// search's display.
public struct FindSession: Equatable, Sendable {
    public var draft: FindDraft
    public var display: FindDisplay

    public init(draft: FindDraft, display: FindDisplay) {
        self.draft = draft
        self.display = display
    }
}

/// Pure find view-model logic. PINNED semantics (each is a frozen test):
///
/// - `initial()` — empty draft + empty display (request nil, current nil,
///   position nil, total 0, not final, progress nil, notice nil).
///
/// - `submit(_:visibleColumns:columnCount:)` — Enter. Text mode: the empty
///   query -> `.ignored`; else `.run(.text(...))` (scope = nil when every
///   column is visible, else the ASCENDING visible set — hidden-column
///   changes re-scope next run). Where mode: a column outside 0..<columnCount
///   or an ordering operator whose value fails `NumericGrammar` (empty
///   included) -> `.rejected`; else `.run(.predicate(...))` (=/≠ accept ANY
///   value, empty matching empty cells). BOTH modes carry the draft's
///   `caseSensitive` verbatim (the shared "Match case" control).
///
/// - `began(_:running:)` — a submitted request started in the core: draft
///   unchanged; display = (request, current nil, position nil, total 0, not
///   final, progress 0, notice nil). The caller also issues the `.fromTop`
///   navigation.
///
/// - `resolved(_:with:navDirection:)` — fold one poll. A nil snapshot or a
///   session with no active display request is returned UNCHANGED. Otherwise:
///   total' = max(displayed, polled) and totalIsFinal latches once true
///   (the growing -> final count state machine; the display never regresses);
///   progress' = max fold while `.scanning`, nil on `.done`/`.cancelled`;
///   a `.found` nav sets current + position (kept on non-found polls).
///   The notice derives purely from the snapshot: `.exhausted` with polled
///   total == 0 AND final -> `.noMatches` (current/position become nil);
///   any other `.exhausted` -> `.wrappedToStart` when navDirection is
///   .forward, `.wrappedToEnd` when .backward (current/position kept — the
///   wrap has not landed yet); else `.cancelled` phase -> `.stopped`; else
///   nil (so a wrap notice clears when the wrap navigation lands).
///   `navDirection` is the direction of the outstanding navigation (the
///   initial `.fromTop` is .forward).
///
/// - `step(_:_:viewportRow:)` — ⌘G/⇧⌘G. nil when there is no active search.
///   With a current match: forward -> anchor current.row + 1 (saturating),
///   backward -> anchor current.row (the pinned strictly-before rule needs
///   no decrement, and previous-from-row-0 exhausts core-side). With none:
///   anchor viewportRow in both directions (navigate relative to what the
///   user sees).
///
/// - `wrapNav(_:)` — the follow-up navigation for a wrap notice:
///   `.wrappedToStart` -> `.fromTop`, `.wrappedToEnd` -> `.fromEnd`, else
///   nil. The caller issues it and keeps polling.
///
/// - `stopped(_:)` — the scan-cancel affordance (the caller also calls
///   `cancelSearch()`): keep everything known so far, progress nil, notice
///   `.stopped`. Unchanged when there is no active search.
///
/// - `closed(_:)` — Esc: display cleared to `initial()`'s (highlights off,
///   counts gone; the caller also cancels the core search) while the DRAFT
///   is retained for the session.
///
/// - `invalidated(_:)` — dialect re-open / new document identity: exactly
///   like `closed` — results cleared, draft retained so re-running is one
///   Enter.
public protocol FindControlling: Sendable {
    func initial() -> FindSession
    func submit(_ session: FindSession, visibleColumns: [Int], columnCount: Int) -> FindSubmit
    func began(_ session: FindSession, running request: SearchRequest) -> FindSession
    func resolved(_ session: FindSession, with snapshot: SearchSnapshot?, navDirection: SearchDirection) -> FindSession
    func step(_ session: FindSession, _ direction: SearchDirection, viewportRow: UInt64) -> SearchNav?
    func wrapNav(_ session: FindSession) -> SearchNav?
    func stopped(_ session: FindSession) -> FindSession
    func closed(_ session: FindSession) -> FindSession
    func invalidated(_ session: FindSession) -> FindSession
}
