// Frozen behavior tests — column-config DISPLAY formatting (planner-owned).
// ARCH-column-config criteria 14 (exact decimal, never lies) + 15 (strict ISO
// boundaries). Pure, no GUI, no core: `ColumnDisplayFormatting` maps a raw cell
// + effective type + format options + locale to a display string OR a raw
// fallback. Uses a FIXED locale so the deterministic pins are stable.
//
// VERIFICATION SPLIT (see ColumnDisplayFormatting.swift): the exact LOCALIZED
// date STRINGS and tz/offset visual stability are a reviewer/host check (CLDR
// output is not a robust frozen-unit pin). These frozen tests pin the
// deterministic core that "never lies": the strict grammar, the exact-decimal
// round-trip guard + half-even rounding, the raw fallback, Original-preset byte
// preservation, and that a localized preset yields a NON-original `.formatted`.
//
// RED SEED: `ColumnDisplayFormatter` classifies nothing and returns
// `.original(raw)` for everything (Auto), so the grammar-accept, grouping,
// fixed-fraction, format-unavailable, and localized-preset assertions fail; the
// grammar-reject and Auto-preservation guards pass.
import Foundation
import Testing
import Contracts
import LessSheetKit

@Suite("column-config display formatting")
struct ColumnFormattingTests {

    private let f = ColumnDisplayFormatter()
    private let en = Locale(identifier: "en_US")
    private var decimal: ColumnType { ColumnType(kind: .decimal) }
    private var integer: ColumnType { ColumnType(kind: .integer) }

    @Test func formatterConformancePin() {
        let _: any ColumnDisplayFormatting = ColumnDisplayFormatter()
    }

    // AC15 (+ AC7 echo) — the strict v1 lexical grammar gate. Accepts (RED: seed
    // returns nil) and rejects (guard: seed returns nil == expected).
    @Test func strictGrammarAcceptsExactFormsOnly() {
        // accepted forms (RED against the seed).
        #expect(f.strictKind(of: "true") == .boolean)
        #expect(f.strictKind(of: "FALSE") == .boolean)
        #expect(f.strictKind(of: "1") == .integer)
        #expect(f.strictKind(of: "0") == .integer)           // 0/1 are integers, NOT booleans
        #expect(f.strictKind(of: "-2") == .integer)
        #expect(f.strictKind(of: "1.5") == .decimal)
        #expect(f.strictKind(of: ".5") == .decimal)
        #expect(f.strictKind(of: "+1e5") == .decimal)        // exponent -> decimal
        #expect(f.strictKind(of: "2020-01-01") == .date)
        #expect(f.strictKind(of: "2020-01-01T00:00:00") == .datetimeNaive)
        #expect(f.strictKind(of: "2020-01-01T00:00:00Z") == .datetimeZoned)
        #expect(f.strictKind(of: "2020-01-01T00:00:00+05:00") == .datetimeZoned)
        #expect(f.strictKind(of: "2020-01-01T00:00:00.123456789Z") == .datetimeZoned)
        // rejected forms -> nil (fall back to text) — guards.
        #expect(f.strictKind(of: "yes") == nil)
        #expect(f.strictKind(of: "2020-1-1") == nil)
        #expect(f.strictKind(of: "2020-01-01 00:00:00") == nil)   // space, not 'T'
        #expect(f.strictKind(of: "2020-01-01t00:00:00") == nil)   // lowercase 't'
        #expect(f.strictKind(of: "2020-01-01T00:00") == nil)      // missing seconds
        #expect(f.strictKind(of: "2020-13-01") == nil)            // invalid month
        #expect(f.strictKind(of: "2020-01-01T00:00:00.1234567890Z") == nil) // >9 fraction digits
        #expect(f.strictKind(of: "abc") == nil)
        #expect(f.strictKind(of: "") == nil)
    }

    // AC14 — Auto preserves the source spelling byte-for-byte (guards).
    @Test func autoPreservesSourceSpelling() {
        #expect(f.display(raw: "2.00", type: decimal, options: .auto, locale: en) == .original("2.00"))
        #expect(f.display(raw: "+1e5", type: decimal, options: .auto, locale: en) == .original("+1e5"))
        #expect(f.display(raw: "007", type: integer, options: .auto, locale: en) == .original("007"))
    }

    // AC14 — explicit integer/decimal formatting uses locale separators + fixed
    // places with HALF-EVEN, never Double. RED against the Auto seed.
    @Test func explicitFormattingGroupsAndRoundsHalfEven() {
        #expect(f.display(raw: "1234567", type: integer, options: ColumnFormatOptions(grouping: true), locale: en)
                == .formatted("1,234,567"))
        #expect(f.display(raw: "1234.5", type: decimal, options: ColumnFormatOptions(grouping: true, fractionDigits: 2), locale: en)
                == .formatted("1,234.50"))
        // half-even ties: 2.5 -> 2 (even), 3.5 -> 4 (even), 0.125 -> 0.12 (even).
        #expect(f.display(raw: "2.5", type: decimal, options: ColumnFormatOptions(fractionDigits: 0), locale: en)
                == .formatted("2"))
        #expect(f.display(raw: "3.5", type: decimal, options: ColumnFormatOptions(fractionDigits: 0), locale: en)
                == .formatted("4"))
        #expect(f.display(raw: "0.125", type: decimal, options: ColumnFormatOptions(fractionDigits: 2), locale: en)
                == .formatted("0.12"))
    }

    // AC14 — a value outside Foundation's exact range, or failing the round-trip
    // guard, stays ORIGINAL with a NON-conflict format-unavailable flag: no
    // rounding, no grouping inserted. RED against the Auto seed (`.original`).
    @Test func inexactValuesFallBackToRawFormatUnavailable() {
        // 1e400: far beyond Decimal's range.
        #expect(f.display(raw: "1e400", type: decimal, options: ColumnFormatOptions(fractionDigits: 2), locale: en)
                == .formatUnavailable("1e400"))
        // 39 significant digits: Foundation Decimal would change it (~38 exact).
        let d39 = "1.23456789012345678901234567890123456789"
        #expect(f.display(raw: d39, type: decimal, options: ColumnFormatOptions(grouping: true, fractionDigits: 2), locale: en)
                == .formatUnavailable(d39))
    }

    // AC15 — Original preset keeps ALL source spelling (incl. 1–9 fraction
    // digits) exactly (guard); a localized preset produces a NON-original
    // `.formatted` string (RED against the Auto seed).
    @Test func datePresetsOriginalVersusLocalized() {
        let naive = ColumnType(kind: .datetime, datetimeSemantics: .naive)
        let raw = "2020-01-01T00:00:00.123456789"
        #expect(f.display(raw: raw, type: naive, options: ColumnFormatOptions(datePreset: .original), locale: en)
                == .original(raw))
        let localized = f.display(raw: raw, type: naive, options: ColumnFormatOptions(datePreset: .localizedMedium), locale: en)
        // RED: the seed returns `.original(raw)`; a built formatter returns a
        // non-empty `.formatted` string (its exact text is a reviewer check).
        if case let .formatted(s) = localized {
            #expect(!s.isEmpty)
        } else {
            Issue.record("localized preset must produce a .formatted string, got \(localized)")
        }
    }
}
