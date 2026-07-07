import Contracts

// find-seek view-model + viewport matcher (implementer-owned; conformances
// pinned by the frozen tests, semantics pinned in
// Sources/Contracts/FindControl.swift and api/lesssheet.h).
//
// FindControl is a PURE value state machine: it never touches the core — it
// composes requests from the draft, folds search polls into the display, and
// decides wrap/no-matches/stopped notices. CellMatcher is the frontend twin of
// the core's per-cell matcher (byte-identical verdicts over valid UTF-8), used
// to paint viewport highlights with zero core calls.

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
            return .run(.text(query: draft.text, scope: scope))
        case .predicate:
            // A column outside the document rejects (blink + shake), before any
            // core call. Hidden columns are legal targets (the picker marks them).
            guard (0..<columnCount).contains(draft.column) else { return .rejected }
            // Ordering operators need a numeric value; the empty value fails too.
            // = / ≠ accept ANY value (the empty one matches empty cells).
            if draft.op.isOrdering, !NumericGrammar.isNumeric(draft.value) { return .rejected }
            return .run(.predicate(column: draft.column, op: draft.op, value: draft.value))
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
        if case let .found(match, pos) = snapshot.nav {
            current = match
            position = pos
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
        } else if case .cancelled = snapshot.phase {
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
        let d = session.display
        return FindSession(
            draft: session.draft,
            display: FindDisplay(
                request: d.request,
                current: d.current,
                position: d.position,
                total: d.total,
                totalIsFinal: d.totalIsFinal,
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

/// Implements `CellMatching` (see its pinned semantics — verdicts must be
/// byte-identical to the core matcher's over valid-UTF-8 cell text).
public struct CellMatcher: CellMatching {
    public init() {}

    public func matches(cell: String, column: Int, under request: SearchRequest) -> Bool {
        switch request {
        case let .text(query, scope):
            // Out-of-scope columns never match (scope filtering is part of the
            // verdict).
            if let scope, !scope.contains(column) { return false }
            return Self.smartCaseContains(query: query, in: cell)
        case let .predicate(col, op, value):
            guard column == col else { return false }
            switch op {
            case .equals:
                return Array(cell.utf8) == Array(value.utf8)     // byte-exact
            case .notEquals:
                return Array(cell.utf8) != Array(value.utf8)
            case .lessThan, .greaterThan, .lessOrEqual, .greaterOrEqual:
                // Numeric: BOTH sides must parse under the pinned grammar; a
                // non-numeric cell never matches an ordering operator. Compared
                // by EXACT mathematical value (never through binary float).
                guard let c = Self.parse(cell), let v = Self.parse(value) else { return false }
                let cmp = Self.compare(c, v)
                switch op {
                case .lessThan: return cmp < 0
                case .greaterThan: return cmp > 0
                case .lessOrEqual: return cmp <= 0
                case .greaterOrEqual: return cmp >= 0
                default: return false
                }
            }
        }
    }

    // MARK: - Smart-case ASCII-folded byte substring (Text)

    /// The query matches when it occurs as a byte substring of the cell. If the
    /// query holds any ASCII uppercase byte the comparison is byte-exact;
    /// otherwise ASCII letters fold case-insensitively and every non-ASCII byte
    /// (>= 0x80) still compares exactly. Pinned in api/lesssheet.h.
    static func smartCaseContains(query: String, in cell: String) -> Bool {
        let q = Array(query.utf8)
        guard !q.isEmpty else { return true }
        let c = Array(cell.utf8)
        let hasUpper = q.contains { (0x41...0x5A).contains($0) }
        if hasUpper {
            return contains(c, q)
        }
        return contains(c.map(fold), q.map(fold))
    }

    private static func fold(_ b: UInt8) -> UInt8 {
        (0x41...0x5A).contains(b) ? b &+ 0x20 : b
    }

    /// Naive byte-substring search — O(cell × query), fine at viewport scale.
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            var k = 0
            while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
            if k == needle.count { return true }
            i += 1
        }
        return false
    }

    // MARK: - The pinned numeric grammar as an EXACT decimal (ordering)

    /// A finite decimal `± D × 10^exp` where `digits` holds D's significant
    /// digits with NO leading or trailing zeros (empty digits == the value 0).
    /// Two of these compare by exact mathematical value.
    private struct Decimal10 {
        let negative: Bool
        let digits: [UInt8]   // each 0...9; most-significant first
        let exp: Int
    }

    /// Parse under the pinned grammar (verbatim with `NumericGrammar`); nil for
    /// any non-numeric text. Returns the canonical exact decimal.
    private static func parse(_ text: String) -> Decimal10? {
        let bytes = Array(text.utf8)
        var lo = 0
        var hi = bytes.count
        func isWs(_ b: UInt8) -> Bool { b == 0x20 || (0x09...0x0D).contains(b) }
        while lo < hi, isWs(bytes[lo]) { lo += 1 }
        while hi > lo, isWs(bytes[hi - 1]) { hi -= 1 }
        guard lo < hi else { return nil }
        func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }

        var i = lo
        var negative = false
        if bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        var intPart: [UInt8] = []
        while i < hi, isDigit(bytes[i]) { intPart.append(bytes[i] - 0x30); i += 1 }
        var fracPart: [UInt8] = []
        var hasSignificand = !intPart.isEmpty
        if i < hi, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while i < hi, isDigit(bytes[i]) { fracPart.append(bytes[i] - 0x30); i += 1 }
            if intPart.isEmpty, fracPart.isEmpty { return nil }  // lone '.'
            if !fracPart.isEmpty { hasSignificand = true }
        } else if intPart.isEmpty {
            return nil
        }
        guard hasSignificand else { return nil }

        var exp = 0
        if i < hi, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            var expNegative = false
            if i < hi, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
                expNegative = bytes[i] == UInt8(ascii: "-")
                i += 1
            }
            var expDigits = 0
            var magnitude = 0
            var overflow = false
            while i < hi, isDigit(bytes[i]) {
                if !overflow {
                    let (m, o1) = magnitude.multipliedReportingOverflow(by: 10)
                    let (s, o2) = m.addingReportingOverflow(Int(bytes[i] - 0x30))
                    if o1 || o2 { overflow = true } else { magnitude = s }
                }
                expDigits += 1
                i += 1
            }
            if expDigits == 0 { return nil }  // dangling exponent
            // Documented latitude: exponents beyond int64 saturate.
            exp = overflow ? (expNegative ? Int.min : Int.max) : (expNegative ? -magnitude : magnitude)
        }
        guard i == hi else { return nil }

        // significant digits = intPart ++ fracPart ; effective exponent shifts
        // left by the fraction length.
        var digits = intPart + fracPart
        var e = satSub(exp, fracPart.count)
        // Strip leading zeros (value-preserving).
        var start = 0
        while start < digits.count, digits[start] == 0 { start += 1 }
        if start == digits.count { return Decimal10(negative: false, digits: [], exp: 0) } // zero
        digits.removeFirst(start)
        // Strip trailing zeros, shifting the exponent up to preserve the value.
        while let l = digits.last, l == 0 {
            digits.removeLast()
            e = satAdd(e, 1)
        }
        return Decimal10(negative: negative, digits: digits, exp: e)
    }

    /// -1 / 0 / +1 for a < b / a == b / a > b, by exact value.
    private static func compare(_ a: Decimal10, _ b: Decimal10) -> Int {
        let aZero = a.digits.isEmpty
        let bZero = b.digits.isEmpty
        if aZero, bZero { return 0 }
        if aZero { return b.negative ? 1 : -1 }
        if bZero { return a.negative ? -1 : 1 }
        if a.negative != b.negative { return a.negative ? -1 : 1 }
        let magnitude = compareMagnitude(a, b)
        return a.negative ? -magnitude : magnitude
    }

    /// Magnitude comparison of two non-zero normalized decimals.
    private static func compareMagnitude(_ a: Decimal10, _ b: Decimal10) -> Int {
        // Position (power of ten) of the leading digit.
        let msdA = satAdd(a.exp, a.digits.count - 1)
        let msdB = satAdd(b.exp, b.digits.count - 1)
        if msdA != msdB { return msdA < msdB ? -1 : 1 }
        // Aligned at the leading digit: compare digit sequences; a longer run of
        // (non-zero-terminated) digits is strictly larger.
        let n = min(a.digits.count, b.digits.count)
        var k = 0
        while k < n {
            if a.digits[k] != b.digits[k] { return a.digits[k] < b.digits[k] ? -1 : 1 }
            k += 1
        }
        if a.digits.count == b.digits.count { return 0 }
        return a.digits.count < b.digits.count ? -1 : 1
    }

    // Saturating Int arithmetic (exponents may be pathological; never trap).
    private static func satAdd(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? (b > 0 ? Int.max : Int.min) : r
    }

    private static func satSub(_ a: Int, _ b: Int) -> Int {
        let (r, o) = a.subtractingReportingOverflow(b)
        return o ? (b < 0 ? Int.max : Int.min) : r
    }
}
