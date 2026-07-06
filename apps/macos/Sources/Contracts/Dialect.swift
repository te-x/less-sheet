/// Dialect types for the viewer-ui slice: the per-open override the app
/// sends to the core (mirrors `ls_open_options`) and the effective-dialect
/// report it gets back (mirrors `ls_dialect`). The pills and the Configure
/// window render `DialectReport`; user selections are turned into the next
/// open's `DialectOverride` by `DialectComposing`.
///
/// Domains (pinned by `api/lesssheet.h`): a custom separator/quote byte is
/// ASCII in 0x01...0x7F, never CR (0x0D) or LF (0x0A), and a forced
/// separator never equals a forced quote byte.

/// Separator override for one open.
public enum SeparatorOverride: Equatable, Sendable {
    /// Sniff (LS_SNIFF).
    case sniff
    /// Force this byte.
    case forced(UInt8)
}

/// Quote override for one open.
public enum QuoteOverride: Equatable, Sendable {
    /// Sniff (LS_SNIFF).
    case sniff
    /// Quoting disabled (LS_QUOTE_NONE): quote characters are literal text.
    case none
    /// Force this byte.
    case forced(UInt8)
}

/// Header override for one open.
public enum HeaderOverride: Equatable, Sendable {
    /// Apply the pinned suggestion grammar (LS_SNIFF).
    case sniff
    /// Force record 1 to be the header (LS_HEADER_ON).
    case on
    /// Force record 1 to be data row 0 (LS_HEADER_OFF).
    case off
}

/// The complete per-open dialect override (session-only; never persisted).
public struct DialectOverride: Equatable, Sendable {
    public var separator: SeparatorOverride
    public var quote: QuoteOverride
    public var header: HeaderOverride

    public init(
        separator: SeparatorOverride = .sniff,
        quote: QuoteOverride = .sniff,
        header: HeaderOverride = .sniff
    ) {
        self.separator = separator
        self.quote = quote
        self.header = header
    }

    /// Sniff everything — the default first open of any document.
    public static let sniffAll = DialectOverride()
}

/// The core's effective dialect for an open document (mirrors `ls_dialect`):
/// exactly what the guess-pills display. Constant for the document session.
public struct DialectReport: Equatable, Sendable {
    /// The effective separator byte.
    public let separator: UInt8
    /// The effective quote byte, or nil when quoting is disabled (NONE).
    public let quote: UInt8?
    /// True when record 1 is the header (forced or grammar-suggested).
    public let hasHeader: Bool
    /// Which parameters the caller forced (vs. sniffed / grammar-derived) —
    /// this is the pills' "user-overridden vs guessed" state, and the state
    /// `DialectComposing` carries into the next re-open.
    public let separatorForced: Bool
    public let quoteForced: Bool
    public let headerForced: Bool

    public init(
        separator: UInt8,
        quote: UInt8?,
        hasHeader: Bool,
        separatorForced: Bool,
        quoteForced: Bool,
        headerForced: Bool
    ) {
        self.separator = separator
        self.quote = quote
        self.hasHeader = hasHeader
        self.separatorForced = separatorForced
        self.quoteForced = quoteForced
        self.headerForced = headerForced
    }
}

/// The pill candidate lists (ARCH-viewer-ui req. 8), mirroring the core's
/// pinned sniffer candidates in the same preference order. The pills offer
/// these plus a "custom…" single-ASCII-character entry (separator/quote) and
/// NONE (quote only).
public enum DialectCandidates {
    /// ',' ';' TAB '|'
    public static let separators: [UInt8] = [0x2C, 0x3B, 0x09, 0x7C]
    /// '"' '\''
    public static let quotes: [UInt8] = [0x22, 0x27]
}

/// One user selection on a pill / Configure control.
public enum DialectChange: Equatable, Sendable {
    /// Force this separator byte.
    case separator(UInt8)
    /// Force this quote byte, or nil for NONE.
    case quote(UInt8?)
    /// Force the header on or off.
    case header(Bool)
}

/// Pure derivation of the next open's override from the current report and
/// one user selection (the "changing a pill re-opens with the forced
/// dialect" flow, ARCH req. 10).
///
/// Pinned semantics of `compose(from:changing:)`:
/// - Carry-forward: each parameter the report marks as forced starts from
///   its current effective value as a forced value; each non-forced
///   parameter starts as `.sniff` (so it is re-sniffed on the re-open, now
///   excluding any newly forced byte from its candidates — core behavior).
/// - The `change` is then applied as the forced value of its parameter
///   (header: `.on` / `.off`).
/// - Returns nil (selection rejected, no re-open) when the change is
///   invalid: a byte outside ASCII 0x01...0x7F, CR or LF, a separator byte
///   equal to the CARRIED forced quote byte, or a quote byte equal to the
///   carried forced separator byte. Changing a byte to equal a merely
///   SNIFFED value of the other parameter is valid (the re-open re-sniffs
///   the other parameter and excludes the conflict). Header changes are
///   always valid.
public protocol DialectComposing: Sendable {
    func compose(from current: DialectReport, changing change: DialectChange) -> DialectOverride?
}
