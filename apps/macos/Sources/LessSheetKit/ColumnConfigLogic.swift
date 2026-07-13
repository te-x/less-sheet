import Contracts
import Foundation

/// The fixed, type-derived alignment used by both the grid and the column
/// inspector. Conflict decoration is deliberately orthogonal to alignment.
public struct ColumnAlignmentRules: ColumnAligning {
    public init() {}

    public func alignment(for kind: ColumnKind, isConflict: Bool) -> ColumnTextAlignment {
        switch kind {
        case .unknown, .unsupported, .text:
            return .leading
        case .boolean:
            return .center
        case .integer, .decimal, .date, .datetime:
            return .trailing
        }
    }

    public var headerAlignment: ColumnTextAlignment { .leading }
}

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
            guard strictKind(of: raw) == .integer else { return .original(raw) }
            guard options.grouping else { return .original(raw) }
            return formatNumber(raw, grouping: true, fractionDigits: nil, locale: locale)

        case .decimal:
            guard strictKind(of: raw) == .decimal else { return .original(raw) }
            guard options.grouping || options.fractionDigits != nil else { return .original(raw) }
            guard options.fractionDigits.map({ (0...38).contains($0) }) ?? true else {
                return .formatUnavailable(raw)
            }
            return formatNumber(raw, grouping: options.grouping,
                                fractionDigits: options.fractionDigits, locale: locale)

        case .date:
            guard strictKind(of: raw) == .date else { return .original(raw) }
            guard options.datePreset != .original else { return .original(raw) }
            guard let fields = Self.dateFields(Array(raw.utf8)),
                  let date = Self.foundationDate(fields, time: nil, timeZone: .gmt) else {
                return .original(raw)
            }
            let style = Date.FormatStyle(date: Self.dateStyle(options.datePreset), time: .omitted,
                                         locale: locale, timeZone: .gmt)
            return .formatted(date.formatted(style))

        case .datetime:
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

        case .unknown, .unsupported, .text, .boolean:
            return .original(raw)
        }
    }

    private func formatNumber(_ raw: String, grouping: Bool, fractionDigits: Int?, locale: Locale) -> ColumnDisplay {
        let invariant = Locale(identifier: "en_US_POSIX")
        let trimmed = Self.trimASCIIWhitespace(Array(raw.utf8))
        guard let source = Self.numericToken(trimmed),
              source.significantDigits <= 38,
              var decimal = Decimal(string: String(decoding: trimmed, as: UTF8.self), locale: invariant),
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

    private struct NumericToken {
        let isDecimal: Bool
        let canonical: String
        let significantDigits: Int
    }

    /// Lexical numeric recognition independent of exponent magnitude. Exact
    /// representation checks happen later in `numericToken`; a syntactically
    /// valid huge exponent is still a decimal kind, then formats unavailable.
    private static func numericGrammar(_ bytes: [UInt8]) -> Bool? {
        guard !bytes.isEmpty else { return nil }
        var i = 0
        if bytes[i] == 0x2B || bytes[i] == 0x2D {
            i += 1
            guard i < bytes.count else { return nil }
        }
        let integralStart = i
        while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        let hasIntegral = i > integralStart
        var hasPoint = false
        var hasFractional = false
        if i < bytes.count, bytes[i] == 0x2E {
            hasPoint = true
            i += 1
            let start = i
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            hasFractional = i > start
        }
        guard hasIntegral || hasFractional else { return nil }
        var hasExponent = false
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            hasExponent = true
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            let start = i
            while i < bytes.count, isDigit(bytes[i]) { i += 1 }
            guard i > start else { return nil }
        }
        guard i == bytes.count else { return nil }
        return hasPoint || hasExponent
    }

    /// Parses the exact numeric grammar and produces a canonical mathematical
    /// spelling (`coefficient` + base-10 exponent) without numeric conversion.
    private static func numericToken(_ bytes: [UInt8]) -> NumericToken? {
        guard !bytes.isEmpty else { return nil }
        var i = 0
        var negative = false
        if bytes[i] == 0x2B || bytes[i] == 0x2D {
            negative = bytes[i] == 0x2D
            i += 1
            guard i < bytes.count else { return nil }
        }

        var integral = [UInt8]()
        while i < bytes.count, Self.isDigit(bytes[i]) {
            integral.append(bytes[i]); i += 1
        }
        var fractional = [UInt8]()
        var hasPoint = false
        if i < bytes.count, bytes[i] == 0x2E {
            hasPoint = true; i += 1
            while i < bytes.count, Self.isDigit(bytes[i]) {
                fractional.append(bytes[i]); i += 1
            }
        }
        guard !integral.isEmpty || !fractional.isEmpty else { return nil }

        var exponent = 0
        var hasExponent = false
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            hasExponent = true; i += 1
            var exponentNegative = false
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D {
                exponentNegative = bytes[i] == 0x2D; i += 1
            }
            let exponentStart = i
            while i < bytes.count, Self.isDigit(bytes[i]) {
                let digit = Int(bytes[i] - 0x30)
                guard exponent <= (Int.max - digit) / 10 else { return nil }
                exponent = exponent * 10 + digit
                i += 1
            }
            guard i > exponentStart else { return nil }
            if exponentNegative { exponent = -exponent }
        }
        guard i == bytes.count else { return nil }

        var coefficient = integral + fractional
        while coefficient.first == 0x30 { coefficient.removeFirst() }
        if coefficient.isEmpty {
            return NumericToken(isDecimal: hasPoint || hasExponent, canonical: "0", significantDigits: 1)
        }
        guard exponent >= Int.min + fractional.count else { return nil }
        exponent -= fractional.count
        while coefficient.last == 0x30 {
            coefficient.removeLast()
            guard exponent < Int.max else { return nil }
            exponent += 1
        }
        let digits = String(decoding: coefficient, as: UTF8.self)
        let sign = negative ? "-" : ""
        return NumericToken(isDecimal: hasPoint || hasExponent,
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

        var i = 19
        var nanosecond = 0
        if i < bytes.count, bytes[i] == 0x2E {
            i += 1
            let start = i
            while i < bytes.count, isDigit(bytes[i]), i - start < 9 {
                nanosecond = nanosecond * 10 + Int(bytes[i] - 0x30)
                i += 1
            }
            let count = i - start
            guard (1...9).contains(count) else { return nil }
            for _ in count..<9 { nanosecond *= 10 }
            if i < bytes.count, isDigit(bytes[i]) { return nil }
        }

        var offsetSeconds: Int?
        if i < bytes.count, bytes[i] == 0x5A {
            offsetSeconds = 0; i += 1
        } else if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D {
            let sign = bytes[i] == 0x2D ? -1 : 1
            guard i + 6 == bytes.count, bytes[i + 3] == 0x3A,
                  let hours = decimalDigits(bytes, (i + 1)..<(i + 3)),
                  let minutes = decimalDigits(bytes, (i + 4)..<(i + 6)),
                  (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
            i += 6
        }
        guard i == bytes.count else { return nil }
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
        for i in range {
            guard isDigit(bytes[i]) else { return nil }
            value = value * 10 + Int(bytes[i] - 0x30)
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
        return zip(lhs, rhs).allSatisfy { a, b in
            (a >= 0x41 && a <= 0x5A ? a + 0x20 : a) == b
        }
    }
}

public struct ColumnPanelLayout: ColumnPanelLayouting {
    public init() {}

    public func plan(for viewport: ColumnPanelViewport) -> ColumnPanelPlan {
        let total = max(viewport.totalColumns, 0)
        let count = viewport.visibleRowCount
        guard total > 0, count > 0 else { return ColumnPanelPlan(instantiatedRows: 0..<0) }

        let first = min(max(viewport.firstVisibleRow, 0), total)
        let visibleEnd = min(total, first.addingReportingOverflow(count).overflow ? total : first + count)
        let lower = max(0, first - min(first, count))
        let upper = min(total, visibleEnd.addingReportingOverflow(count).overflow ? total : visibleEnd + count)
        return ColumnPanelPlan(instantiatedRows: lower..<upper)
    }
}

public struct ColumnLabelSearch: ColumnLabelSearching {
    public init() {}
    public var batchSize: Int { columnLabelSearchBatchMax }

    public func matches(query: String, in candidates: [ColumnLabelCandidate], locale: Locale) -> [UInt32] {
        guard !query.isEmpty else { return [] }
        return candidates.compactMap { candidate in
            let text: String
            if let label = candidate.label, !label.isEmpty {
                text = label
            } else {
                let index = Int(candidate.column)
                text = "\(GenericColumnName.name(at: index)) \(index + 1)"
            }
            return text.range(of: query, options: [.caseInsensitive], locale: locale) == nil ? nil : candidate.column
        }
    }
}

public struct ColumnSessionModel: ColumnSessionModeling {
    public init() {}

    public func reset(_ settings: [Int: ColumnUserSettings]) -> [Int: ColumnUserSettings] { [:] }

    public func decide(change: ColumnReopenChange, oldCount: Int, newCount: Int,
                       oldHeaders: [ColumnHeaderIdentity]?, newHeaders: [ColumnHeaderIdentity]?) -> ColumnReopenDecision {
        guard oldCount == newCount else { return .resetAll }
        switch change {
        case .headerOnly:
            return .replayOrdinally
        case .separatorQuoteEncoding:
            guard let oldHeaders, let newHeaders,
                  oldHeaders.count == oldCount, newHeaders.count == newCount,
                  !oldHeaders.contains(where: \.truncated),
                  !newHeaders.contains(where: \.truncated),
                  oldHeaders == newHeaders else { return .resetAll }
            return .replayOrdinally
        }
    }
}
