// Frozen behavior tests — column-config SESSION model (planner-owned).
// ARCH-column-config criterion 19 (session reset / no persistence) + criterion
// 18 (strict, transactional internal-re-open mapping). Pure, no GUI, no core:
// `ColumnSessionModeling` owns the two decisions the frontend makes — clear all
// user settings, and decide whether authored settings map safely onto a
// Parsing-change candidate.
//
// RED SEED: `ColumnSessionModel.reset` returns its input unchanged and `decide`
// always returns `.resetAll`, so the reset-clears and the safe-replay
// assertions fail; the unsafe-reset cases pass as guards.
import Foundation
import Testing
import Contracts
import LessSheetKit

@Suite("column-config session + internal re-open")
struct ColumnSessionTests {

    private let m = ColumnSessionModel()

    @Test func conformancePin() {
        let _: any ColumnSessionModeling = ColumnSessionModel()
    }

    // AC19 — an explicit close/open clears EVERY column's user settings. RED:
    // the seed returns the populated map unchanged.
    @Test func resetClearsAllUserSettings() {
        let settings: [Int: ColumnUserSettings] = [
            0: ColumnUserSettings(overrideType: ColumnType(kind: .integer)),
            3: ColumnUserSettings(nullSentinel: Array("NA".utf8), hidden: true),
            7: ColumnUserSettings(format: ColumnFormatOptions(grouping: true), manualWidth: 120),
        ]
        #expect(m.reset(settings).isEmpty)   // RED: seed returns `settings`
    }

    // A default `ColumnUserSettings` is recognisably Auto; any authored field
    // makes it non-default (guard for the value type).
    @Test func userSettingsDefaultDetection() {
        #expect(ColumnUserSettings.default.isDefault)
        #expect(!ColumnUserSettings(overrideType: ColumnType(kind: .text)).isDefault)
        #expect(!ColumnUserSettings(nullSentinel: []).isDefault)          // empty sentinel is authored
        #expect(!ColumnUserSettings(hidden: true).isDefault)
    }

    // AC18 — a header-only re-open replays ordinally IFF the column count is
    // unchanged. RED on the equal-count replay; the mismatch reset is a guard.
    @Test func headerOnlyReopenMapping() {
        #expect(m.decide(change: .headerOnly, oldCount: 5, newCount: 5, oldHeaders: nil, newHeaders: nil) == .replayOrdinally) // RED
        #expect(m.decide(change: .headerOnly, oldCount: 5, newCount: 6, oldHeaders: nil, newHeaders: nil) == .resetAll)        // guard
    }

    // AC18 — a separator/quote/encoding re-open replays ONLY with equal counts
    // AND byte-identical, non-truncated, present header identities. RED on the
    // safe case; every unsafe case (reorder, count mismatch, truncation,
    // headerless) resets — guards.
    @Test func separatorQuoteEncodingReopenMapping() {
        func id(_ s: String, truncated: Bool = false) -> ColumnHeaderIdentity {
            ColumnHeaderIdentity(bytes: Array(s.utf8), truncated: truncated)
        }
        let a = [id("name"), id("age"), id("city")]
        let reordered = [id("age"), id("name"), id("city")]
        let truncated = [id("name"), id("age"), id("city", truncated: true)]

        // safe: same count, identical non-truncated headers (RED).
        #expect(m.decide(change: .separatorQuoteEncoding, oldCount: 3, newCount: 3, oldHeaders: a, newHeaders: a) == .replayOrdinally)
        // unsafe cases (guards).
        #expect(m.decide(change: .separatorQuoteEncoding, oldCount: 3, newCount: 3, oldHeaders: a, newHeaders: reordered) == .resetAll)
        #expect(m.decide(change: .separatorQuoteEncoding, oldCount: 3, newCount: 4, oldHeaders: a, newHeaders: a) == .resetAll)
        #expect(m.decide(change: .separatorQuoteEncoding, oldCount: 3, newCount: 3, oldHeaders: a, newHeaders: truncated) == .resetAll)
        // headerless on either side is NEVER safe for a dialect/encoding change.
        #expect(m.decide(change: .separatorQuoteEncoding, oldCount: 3, newCount: 3, oldHeaders: nil, newHeaders: a) == .resetAll)
        #expect(m.decide(change: .separatorQuoteEncoding, oldCount: 3, newCount: 3, oldHeaders: a, newHeaders: nil) == .resetAll)
    }
}
