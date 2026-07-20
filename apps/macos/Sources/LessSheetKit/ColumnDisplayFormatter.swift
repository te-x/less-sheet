import Contracts
import Foundation

/// Display-only formatting over the strict column grammar. Every formatter
/// path starts with a grammar/type check and falls back to the source spelling
/// whenever Foundation cannot represent the value exactly.
public struct ColumnDisplayFormatter: ColumnDisplayFormatting {
    public init() {}

    public func strictKind(of raw: String) -> ColumnScalarKind? {
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }

        let trimmed = Self.trimASCIIWhitespace(bytes)
        if Self.asciiCaseInsensitiveEqual(trimmed, Array("true".utf8))
            || Self.asciiCaseInsensitiveEqual(trimmed, Array("false".utf8)) {
            return .boolean
        }
        if let isDecimal = Self.numericGrammar(trimmed) {
            return isDecimal ? .decimal : .integer
        }
        // Unlike boolean/numeric input, ISO date forms do not permit edge
        // whitespace; validate the original ASCII bytes.
        if Self.dateFields(bytes) != nil { return .date }
        if let fields = Self.datetimeFields(bytes) {
            return fields.offsetSeconds == nil ? .datetimeNaive : .datetimeZoned
        }
        return nil
    }

    public func display(raw: String, type: ColumnType, options: ColumnFormatOptions, locale: Locale) -> ColumnDisplay {
        guard !raw.isEmpty, options != .auto else { return .original(raw) }

        switch type.kind {
        case .integer:
            return formatInteger(raw, options: options, locale: locale)
        case .decimal:
            return formatDecimal(raw, options: options, locale: locale)
        case .date:
            return formatDate(raw, options: options, locale: locale)
        case .datetime:
            return formatDatetime(raw, type: type, options: options, locale: locale)
        case .unknown, .unsupported, .text, .boolean:
            return .original(raw)
        }
    }

    private func formatInteger(_ raw: String, options: ColumnFormatOptions, locale: Locale) -> ColumnDisplay {
        guard strictKind(of: raw) == .integer else { return .original(raw) }
        guard options.grouping else { return .original(raw) }
        return formatNumber(raw, grouping: true, fractionDigits: nil, locale: locale)
    }

    private func formatDecimal(_ raw: String, options: ColumnFormatOptions, locale: Locale) -> ColumnDisplay {
        guard strictKind(of: raw) == .decimal else { return .original(raw) }
        guard options.grouping || options.fractionDigits != nil else { return .original(raw) }
        guard options.fractionDigits.map({ (0...38).contains($0) }) ?? true else {
            return .formatUnavailable(raw)
        }
        return formatNumber(raw, grouping: options.grouping,
                            fractionDigits: options.fractionDigits, locale: locale)
    }

    private func formatDate(_ raw: String, options: ColumnFormatOptions, locale: Locale) -> ColumnDisplay {
        guard strictKind(of: raw) == .date else { return .original(raw) }
        guard options.datePreset != .original else { return .original(raw) }
        guard let fields = Self.dateFields(Array(raw.utf8)),
              let date = Self.foundationDate(fields, time: nil, timeZone: .gmt) else {
            return .original(raw)
        }
        let style = Date.FormatStyle(date: Self.dateStyle(options.datePreset), time: .omitted,
                                     locale: locale, timeZone: .gmt)
        return .formatted(date.formatted(style))
    }

    private func formatDatetime(_ raw: String, type: ColumnType, options: ColumnFormatOptions,
                                locale: Locale) -> ColumnDisplay {
        guard let fields = Self.datetimeFields(Array(raw.utf8)) else { return .original(raw) }
        let expected: ColumnScalarKind = type.datetimeSemantics == .zoned ? .datetimeZoned : .datetimeNaive
        guard strictKind(of: raw) == expected else { return .original(raw) }
        guard options.datePreset != .original else { return .original(raw) }
        guard let zone = TimeZone(secondsFromGMT: fields.offsetSeconds ?? 0) else {
            return .original(raw)
        }
        guard let date = Self.foundationDate(fields.date, time: fields, timeZone: zone) else {
            return .original(raw)
        }
        let style = Date.FormatStyle(date: Self.dateStyle(options.datePreset), time: .standard,
                                     locale: locale, timeZone: zone)
        return .formatted(date.formatted(style))
    }

    private func formatNumber(_ raw: String, grouping: Bool, fractionDigits: Int?, locale: Locale) -> ColumnDisplay {
        let invariant = Locale(identifier: "en_US_POSIX")
        let trimmed = Self.trimASCIIWhitespace(Array(raw.utf8))
        guard let source = Self.numericToken(trimmed),
              source.significantDigits <= 38,
              var decimal = Decimal(string: String(bytes: trimmed, encoding: .utf8) ?? "", locale: invariant),
              !decimal.isNaN else {
            return .formatUnavailable(raw)
        }

        let foundationSpelling = NSDecimalString(&decimal, invariant as NSLocale)
        guard let roundTrip = Self.numericToken(Array(foundationSpelling.utf8)),
              source.canonical == roundTrip.canonical else {
            return .formatUnavailable(raw)
        }

        var style = Decimal.FormatStyle(locale: locale)
            .grouping(grouping ? .automatic : .never)
            .rounded(rule: .toNearestOrEven)
        if let fractionDigits {
            style = style.precision(.fractionLength(fractionDigits))
        }
        return .formatted(decimal.formatted(style))
    }
}

// The numeric / date grammar recognition lives in an extension so the primary
// struct body stays small; every member below is pure and stateless.
extension ColumnDisplayFormatter {
    private struct NumericToken {
        let isDecimal: Bool
        let canonical: String
        let significantDigits: Int
    }

    private struct ExponentScan {
        let next: Int
        let value: Int
        let hasExponent: Bool
    }

    /// Lexical numeric recognition independent of exponent magnitude. Exact
    /// representation checks happen later in `numericToken`; a syntactically
    /// valid huge exponent is still a decimal kind, then formats unavailable.
    private static func numericGrammar(_ bytes: [UInt8]) -> Bool? {
        guard !bytes.isEmpty else { return nil }
        var index = 0
        if bytes[index] == 0x2B || bytes[index] == 0x2D {
            index += 1
            guard index < bytes.count else { return nil }
        }
        let integralStart = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        let hasIntegral = index > integralStart
        var hasPoint = false
        var hasFractional = false
        if index < bytes.count, bytes[index] == 0x2E {
            hasPoint = true
            index += 1
            let start = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            hasFractional = index > start
        }
        guard hasIntegral || hasFractional else { return nil }
        guard let exponent = scanExponent(bytes, from: index) else { return nil }
        guard exponent.next == bytes.count else { return nil }
        return hasPoint || exponent.hasExponent
    }

    /// Scans an optional exponent (`[eE][+-]?digits`) for GRAMMAR validation
    /// only — it deliberately does NOT bound the exponent magnitude (a
    /// syntactically valid huge exponent is still a decimal kind). Returns the
    /// index after the exponent and whether one was present, or nil on a
    /// malformed exponent (a lone `e`).
    private static func scanExponent(_ bytes: [UInt8], from start: Int) -> (next: Int, hasExponent: Bool)? {
        var index = start
        guard index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 else {
            return (index, false)
        }
        index += 1
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        let digitsStart = index
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        guard index > digitsStart else { return nil }
        return (index, true)
    }

    /// Parses the exact numeric grammar and produces a canonical mathematical
    /// spelling (`coefficient` + base-10 exponent) without numeric conversion.
    private static func numericToken(_ bytes: [UInt8]) -> NumericToken? {
        guard !bytes.isEmpty else { return nil }
        var index = 0
        var negative = false
        if bytes[index] == 0x2B || bytes[index] == 0x2D {
            negative = bytes[index] == 0x2D
            index += 1
            guard index < bytes.count else { return nil }
        }

        var integral = [UInt8]()
        while index < bytes.count, Self.isDigit(bytes[index]) {
            integral.append(bytes[index]); index += 1
        }
        var fractional = [UInt8]()
        var hasPoint = false
        if index < bytes.count, bytes[index] == 0x2E {
            hasPoint = true; index += 1
            while index < bytes.count, Self.isDigit(bytes[index]) {
                fractional.append(bytes[index]); index += 1
            }
        }
        guard !integral.isEmpty || !fractional.isEmpty else { return nil }

        guard let exponent = Self.scanExponentValue(bytes, from: index) else { return nil }
        guard exponent.next == bytes.count else { return nil }

        return canonicalToken(integral: integral, fractional: fractional, exponent: exponent.value,
                              negative: negative, isDecimal: hasPoint || exponent.hasExponent)
    }

    /// Scans the optional exponent AND its signed magnitude for canonical-token
    /// construction. Returns the index after the exponent, the signed exponent
    /// value, and whether one was present — or nil on overflow / a malformed
    /// exponent.
    private static func scanExponentValue(_ bytes: [UInt8], from start: Int) -> ExponentScan? {
        var index = start
        guard index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 else {
            return ExponentScan(next: index, value: 0, hasExponent: false)
        }
        index += 1
        var exponentNegative = false
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            exponentNegative = bytes[index] == 0x2D; index += 1
        }
        let exponentStart = index
        var value = 0
        while index < bytes.count, Self.isDigit(bytes[index]) {
            let digit = Int(bytes[index] - 0x30)
            guard value <= (Int.max - digit) / 10 else { return nil }
            value = value * 10 + digit
            index += 1
        }
        guard index > exponentStart else { return nil }
        if exponentNegative { value = -value }
        return ExponentScan(next: index, value: value, hasExponent: true)
    }

    /// Normalizes the coefficient digits (strip leading/trailing zeros, folding
    /// the shift into the exponent) into the canonical `NumericToken`, or nil on
    /// exponent overflow.
    private static func canonicalToken(integral: [UInt8], fractional: [UInt8], exponent: Int,
                                       negative: Bool, isDecimal: Bool) -> NumericToken? {
        var coefficient = integral + fractional
        while coefficient.first == 0x30 { coefficient.removeFirst() }
        if coefficient.isEmpty {
            return NumericToken(isDecimal: isDecimal, canonical: "0", significantDigits: 1)
        }
        var exponent = exponent
        guard exponent >= Int.min + fractional.count else { return nil }
        exponent -= fractional.count
        while coefficient.last == 0x30 {
            coefficient.removeLast()
            guard exponent < Int.max else { return nil }
            exponent += 1
        }
        let digits = String(bytes: coefficient, encoding: .utf8) ?? ""
        let sign = negative ? "-" : ""
        return NumericToken(isDecimal: isDecimal,
                            canonical: "\(sign)\(digits)e\(exponent)",
                            significantDigits: coefficient.count)
    }

    private struct DateFields {
        let year: Int
        let month: Int
        let day: Int
    }

    private struct DatetimeFields {
        let date: DateFields
        let hour: Int
        let minute: Int
        let second: Int
        let nanosecond: Int
        let offsetSeconds: Int?
    }

    private static func dateFields(_ bytes: [UInt8]) -> DateFields? {
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D,
              let year = decimalDigits(bytes, 0..<4),
              let month = decimalDigits(bytes, 5..<7),
              let day = decimalDigits(bytes, 8..<10),
              (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day) else { return nil }
        return DateFields(year: year, month: month, day: day)
    }

    private static func datetimeFields(_ bytes: [UInt8]) -> DatetimeFields? {
        guard bytes.count >= 19, bytes[10] == 0x54,
              let date = dateFields(Array(bytes[0..<10])),
              bytes[13] == 0x3A, bytes[16] == 0x3A,
              let hour = decimalDigits(bytes, 11..<13),
              let minute = decimalDigits(bytes, 14..<16),
              let second = decimalDigits(bytes, 17..<19),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }

        var index = 19
        var nanosecond = 0
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let start = index
            while index < bytes.count, isDigit(bytes[index]), index - start < 9 {
                nanosecond = nanosecond * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            let count = index - start
            guard (1...9).contains(count) else { return nil }
            for _ in count..<9 { nanosecond *= 10 }
            if index < bytes.count, isDigit(bytes[index]) { return nil }
        }

        var offsetSeconds: Int?
        if index < bytes.count, bytes[index] == 0x5A {
            offsetSeconds = 0; index += 1
        } else if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
            let sign = bytes[index] == 0x2D ? -1 : 1
            guard index + 6 == bytes.count, bytes[index + 3] == 0x3A,
                  let hours = decimalDigits(bytes, (index + 1)..<(index + 3)),
                  let minutes = decimalDigits(bytes, (index + 4)..<(index + 6)),
                  (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
            index += 6
        }
        guard index == bytes.count else { return nil }
        return DatetimeFields(date: date, hour: hour, minute: minute, second: second,
                              nanosecond: nanosecond, offsetSeconds: offsetSeconds)
    }

    private static func foundationDate(_ date: DateFields, time: DatetimeFields?, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.hour = time?.hour ?? 0
        components.minute = time?.minute ?? 0
        components.second = time?.second ?? 0
        components.nanosecond = time?.nanosecond ?? 0
        return calendar.date(from: components)
    }

    private static func dateStyle(_ preset: DatePreset) -> Date.FormatStyle.DateStyle {
        switch preset {
        case .original: return .numeric
        case .localizedShort: return .numeric
        case .localizedMedium: return .abbreviated
        case .localizedLong: return .long
        }
    }

    private static func decimalDigits(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        var value = 0
        for index in range {
            guard isDigit(bytes[index]) else { return nil }
            value = value * 10 + Int(bytes[index] - 0x30)
        }
        return value
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func trimASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var lower = 0
        var upper = bytes.count
        while lower < upper, isASCIIWhitespace(bytes[lower]) { lower += 1 }
        while upper > lower, isASCIIWhitespace(bytes[upper - 1]) { upper -= 1 }
        return Array(bytes[lower..<upper])
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func asciiCaseInsensitiveEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { lhsByte, rhsByte in
            (lhsByte >= 0x41 && lhsByte <= 0x5A ? lhsByte + 0x20 : lhsByte) == rhsByte
        }
    }
}
