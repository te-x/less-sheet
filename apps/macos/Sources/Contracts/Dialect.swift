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

/// The resolved source encoding the core REPORTS (mirrors the concrete
/// LS_ENCODING_* values — never "Automatic"). Raw values pin the ABI so the
/// bridge maps `ls_dialect.encoding` by rawValue.
public enum TextEncoding: UInt8, CaseIterable, Equatable, Sendable {
    case utf8 = 0
    case utf16LE = 1
    case utf16BE = 2
    case latin1 = 3 // ISO-8859-1
    case windows1252 = 4
}

/// Text-encoding override for one open (the Settings "Text encoding" picker's
/// value): detect (Automatic) or force one of the five. Mirrors
/// `ls_open_options.encoding` (LS_ENCODING_AUTO + the concrete values). A
/// forced encoding bypasses detection (a forced UTF-16 is honored without a
/// BOM); Automatic re-detects on the (re-)open.
public enum EncodingOverride: Equatable, Sendable, CaseIterable {
    case automatic
    case utf8
    case utf16LE
    case utf16BE
    case latin1
    case windows1252

    /// The forced override that pins a resolved `encoding`.
    public init(_ encoding: TextEncoding) {
        switch encoding {
        case .utf8: self = .utf8
        case .utf16LE: self = .utf16LE
        case .utf16BE: self = .utf16BE
        case .latin1: self = .latin1
        case .windows1252: self = .windows1252
        }
    }
}

/// The complete per-open dialect override (session-only; never persisted).
public struct DialectOverride: Equatable, Sendable {
    public var separator: SeparatorOverride
    public var quote: QuoteOverride
    public var header: HeaderOverride
    public var encoding: EncodingOverride

    public init(
        separator: SeparatorOverride = .sniff,
        quote: QuoteOverride = .sniff,
        header: HeaderOverride = .sniff,
        encoding: EncodingOverride = .automatic
    ) {
        self.separator = separator
        self.quote = quote
        self.header = header
        self.encoding = encoding
    }

    /// Sniff/detect everything — the default first open of any document.
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
    /// The effective (resolved) source encoding — what the picker shows in
    /// Automatic mode ("detected: …") and confirms when forced. Never carries
    /// an "Automatic" value (that lives only in `EncodingOverride`).
    public let encoding: TextEncoding
    /// Which parameters the caller forced (vs. sniffed / detected / grammar-
    /// derived) — the pills' + picker's "user-overridden vs guessed" state,
    /// carried into the next re-open by `DialectComposing`.
    public let separatorForced: Bool
    public let quoteForced: Bool
    public let headerForced: Bool
    public let encodingForced: Bool

    public init(
        separator: UInt8,
        quote: UInt8?,
        hasHeader: Bool,
        separatorForced: Bool,
        quoteForced: Bool,
        headerForced: Bool,
        encoding: TextEncoding = .utf8,
        encodingForced: Bool = false
    ) {
        self.separator = separator
        self.quote = quote
        self.hasHeader = hasHeader
        self.separatorForced = separatorForced
        self.quoteForced = quoteForced
        self.headerForced = headerForced
        self.encoding = encoding
        self.encodingForced = encodingForced
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
    /// Force this encoding (or `.automatic` to re-detect). Routed through the
    /// SAME compose/re-open path as the dialect parameters (ARCH req. 12).
    case encoding(EncodingOverride)
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
///   Encoding carries the same way: `.encoding(report.encoding)` when
///   `encodingForced`, else `.automatic` (re-detected on the re-open).
/// - The `change` is then applied as the forced value of its parameter
///   (header: `.on` / `.off`; encoding: the chosen `EncodingOverride`,
///   `.automatic` included — choosing Automatic re-detects).
/// - An `.encoding` change never fails (any `EncodingOverride` is valid) and
///   never affects the dialect bytes; it only sets `encoding`.
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

/// The Settings "Text encoding" picker's pure view-model (ARCH criterion 18):
/// the ordered options, the option a report shows as selected, and the
/// resolved encoding to surface as the Automatic subtitle. Contract-level
/// policy (small, presentation-neutral — like `GenericColumnName` /
/// `NumericGrammar`); the app owns the user-facing copy. The picker is a
/// Settings control, NOT a control-row pill.
public enum EncodingPicker {
    /// The picker options in order: Automatic, then the five encodings.
    public static let options: [EncodingOverride] = EncodingOverride.allCases

    /// The option shown selected for `report`: the forced encoding when
    /// `encodingForced`, else `.automatic` (detection chose the value).
    public static func selection(for report: DialectReport) -> EncodingOverride {
        report.encodingForced ? EncodingOverride(report.encoding) : .automatic
    }

    /// The resolved encoding to surface — the "Automatic — detected: X"
    /// subtitle in Automatic mode, or the confirmed value when forced. Always
    /// the report's concrete resolved encoding.
    public static func detected(in report: DialectReport) -> TextEncoding {
        report.encoding
    }
}
