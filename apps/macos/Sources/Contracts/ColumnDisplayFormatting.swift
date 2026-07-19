import Foundation

/// Display-only column formatting (ARCH-column-config "Display output",
/// criteria 14/15). The core serves RAW cells and type metadata; THIS produces
/// the on-screen string. It never changes copy/Find/filter (those keep the raw
/// value — see ARCH criterion 17). Implemented in `LessSheetKit`
/// (`ColumnDisplayFormatter`) over Foundation `Decimal.FormatStyle` /
/// `Date.ISO8601FormatStyle`, pinned by a frozen conformance test.
///
/// The two responsibilities:
/// 1. `strictKind(of:)` — the display-side STRICT lexical grammar gate (the
///    exact v1 grammar, ASCII-only, locale-independent), used to decide whether
///    a visible raw cell matches the effective type (else it is a conflict, kept
///    raw) and is eligible for formatting.
/// 2. `display(raw:type:options:locale:)` — the display string, or a raw
///    fallback that NEVER lies.

/// The strict base kind of a SINGLE raw value (nil == matches no strict type, so
/// the value is text). Datetime carries its naive/zoned semantic.
public enum ColumnScalarKind: Equatable, Sendable {
    case boolean, integer, decimal, date, datetimeNaive, datetimeZoned
}

/// Date/datetime display preset (ARCH: Original, or a native localized preset).
public enum DatePreset: Equatable, Sendable {
    case original          // keep source spelling exactly (incl. 1–9 fraction digits)
    case localizedShort
    case localizedMedium
    case localizedLong
}

/// The session-only format controls for one column. `auto` = preserve source
/// spelling. Grouping applies to integer & decimal; `fractionDigits` (0…38) is
/// decimal-only fixed places (half-even); `datePreset` is date/datetime-only.
public struct ColumnFormatOptions: Equatable, Sendable {
    public var grouping: Bool
    public var fractionDigits: Int?
    public var datePreset: DatePreset

    public init(grouping: Bool = false, fractionDigits: Int? = nil, datePreset: DatePreset = .original) {
        self.grouping = grouping
        self.fractionDigits = fractionDigits
        self.datePreset = datePreset
    }

    /// Auto: preserve the original cell spelling exactly.
    public static let auto = ColumnFormatOptions()
}

/// The display outcome for one cell.
public enum ColumnDisplay: Equatable, Sendable {
    /// Show the original spelling exactly (Auto, or a kind with no v1 controls).
    case original(String)
    /// Show this exact formatted string (an exact round trip / valid preset).
    case formatted(String)
    /// Show the original spelling with a NON-CONFLICT "format unavailable"
    /// indicator: the value is outside Foundation's exact range or failed the
    /// exact round-trip guard, so formatting it would risk lying.
    case formatUnavailable(String)

    /// The text a grid draws (original spelling for `.original`/`.formatUnavailable`).
    public var text: String {
        switch self {
        case let .original(value), let .formatted(value), let .formatUnavailable(value): return value
        }
    }
}

/// Pure column display formatter. Pinned semantics (the spec the RED seed does
/// NOT yet satisfy — the seed returns `.original(raw)` for everything and
/// classifies nothing):
///
/// - AUTO (`options == .auto`) → `.original(raw)` for EVERY kind: source
///   spelling is preserved byte-for-byte (`2.00`, `+1e5`, a 38-digit decimal,
///   `1e400` all unchanged).
/// - TEXT / BOOLEAN / UNKNOWN / UNSUPPORTED → always `.original(raw)` (no v1
///   format controls).
/// - INTEGER with `grouping` → `.formatted` with the locale's grouping
///   separator; without grouping → `.original`.
/// - DECIMAL: parse `raw` with Foundation `Decimal` under an INVARIANT decimal
///   locale, then compare the parsed value's canonical base-10 spelling with
///   `raw` under the exact numeric grammar. ONLY an exact mathematical round
///   trip may be formatted (`.number` grouping + fixed `fractionDigits` with
///   HALF-EVEN rounding, `Double` never used). A value beyond Foundation's ≈38
///   exact digits, or one that fails the round-trip guard, is
///   `.formatUnavailable(raw)` — no rounding, no grouping, no conflict. Auto → `.original`.
/// - DATE / DATETIME: gate on `strictKind(of:)` first. `.original` preset →
///   `.original(raw)` (all source spelling, incl. 1–9 fraction digits). A
///   localized preset → `.formatted`, with NAIVE values keeping their wall time
///   and ZONED values kept in each value's SOURCE offset (never converted to the
///   system zone; differing offsets are not normalized).
/// - A value that does not match `type` under `strictKind`, or an empty string,
///   → `.original(raw)` (the caller renders conflicts/nulls/blank separately).
///
/// NOTE (verification split): the exact localized date/datetime STRINGS and the
/// tz/offset visual stability are a reviewer/host check (CLDR output is not a
/// robust frozen-unit pin); the frozen tests pin the deterministic core (strict
/// grammar, exact decimal round trip + half-even, raw fallback, Original-preset
/// byte preservation, and that a localized preset produces a non-original
/// `.formatted`).
public protocol ColumnDisplayFormatting: Sendable {
    func strictKind(of raw: String) -> ColumnScalarKind?
    func display(raw: String, type: ColumnType, options: ColumnFormatOptions, locale: Locale) -> ColumnDisplay
}
