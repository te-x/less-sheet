/// The per-session, never-persisted column configuration model
/// (ARCH-column-config "Logical-session internal re-open", criteria 18/19). Two
/// pure decisions the frontend owns: (1) the user-authored settings SNAPSHOT and
/// its full reset, and (2) whether those settings map SAFELY onto an
/// internal-re-open candidate (a Parsing change in the same logical session) or
/// must be reset. Implemented in `LessSheetKit` (`ColumnSessionModel`), pinned
/// by frozen conformance tests. Nothing here persists anything.

/// The user-authored settings for one column — the ONLY things replayed across
/// an internal re-open (ARCH: override, null sentinel, format, visibility,
/// manual width). Inference, conflicts, proposals, automatic widths, active
/// jobs, and generations are NEVER part of the snapshot.
public struct ColumnUserSettings: Equatable, Sendable {
    public var overrideType: ColumnType?      // nil == Auto
    public var nullSentinel: [UInt8]?         // nil == no sentinel; [] == empty sentinel
    public var format: ColumnFormatOptions    // .auto by default
    public var hidden: Bool                   // visibility
    public var manualWidth: Double?           // nil == auto width

    public init(overrideType: ColumnType? = nil, nullSentinel: [UInt8]? = nil,
                format: ColumnFormatOptions = .auto, hidden: Bool = false,
                manualWidth: Double? = nil) {
        self.overrideType = overrideType
        self.nullSentinel = nullSentinel
        self.format = format
        self.hidden = hidden
        self.manualWidth = manualWidth
    }

    /// True iff this column carries NO user-authored setting (pure Auto).
    public var isDefault: Bool {
        overrideType == nil && nullSentinel == nil && format == .auto && !hidden && manualWidth == nil
    }

    public static let `default` = ColumnUserSettings()
}

/// One column's decoded header identity for internal-re-open mapping.
public struct ColumnHeaderIdentity: Equatable, Sendable {
    public let bytes: [UInt8]   // decoded source header bytes
    public let truncated: Bool  // the label was display-capped

    public init(bytes: [UInt8], truncated: Bool) {
        self.bytes = bytes
        self.truncated = truncated
    }
}

/// The kind of internal re-open (a Parsing change in the SAME logical session).
public enum ColumnReopenChange: Equatable, Sendable {
    /// Only the header on/off decision changed.
    case headerOnly
    /// A separator, quote, or encoding change.
    case separatorQuoteEncoding
}

/// The mapping decision.
public enum ColumnReopenDecision: Equatable, Sendable {
    /// SAFE: replay the five user-authored setting classes ordinally onto the
    /// candidate, then restart inference/automatic widths afresh.
    case replayOrdinally
    /// UNSAFE: reset all column settings on the candidate (and explain it).
    case resetAll
}

/// Pure session model. Pinned semantics (the spec the RED seed does NOT satisfy
/// — the seed's `reset` returns the input unchanged and `decide` always returns
/// `.resetAll`):
///
/// - `reset(_:)` — clear EVERY column's user settings (all Auto, no sentinel, no
///   override, visible, auto width): an explicit close/open is a fresh session.
/// - `decide(change:oldCount:newCount:oldHeaders:newHeaders:)`:
///   * `.headerOnly` → `.replayOrdinally` IFF `oldCount == newCount`, else `.resetAll`;
///   * `.separatorQuoteEncoding` → `.replayOrdinally` IFF `oldCount == newCount`
///     AND both sides HAVE a header (`oldHeaders`/`newHeaders` non-nil) AND no
///     identity on either side is truncated AND the ordered decoded header
///     identities are byte-identical; else `.resetAll`;
///   * a headerless side (nil headers) on a `.separatorQuoteEncoding` change is
///     NEVER safe (`.resetAll`); count mismatch, reorder, rename, or truncation
///     is `.resetAll`.
public protocol ColumnSessionModeling: Sendable {
    func reset(_ settings: [Int: ColumnUserSettings]) -> [Int: ColumnUserSettings]
    func decide(change: ColumnReopenChange, oldCount: Int, newCount: Int,
                oldHeaders: [ColumnHeaderIdentity]?, newHeaders: [ColumnHeaderIdentity]?) -> ColumnReopenDecision
}
