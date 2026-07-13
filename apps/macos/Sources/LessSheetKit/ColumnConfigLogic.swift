import Contracts
import Foundation

// column-config slice (ARCH-column-config) — RED SEED of the macOS DISPLAY model
// (implementer-owned; conformances pinned by the frozen ColumnMetadataModelTests
// / ColumnFormattingTests / ColumnPanelTests / ColumnSessionTests). Each type
// reproduces the PRE-FEATURE behaviour so the tree COMPILES (conformance green)
// while every behavioural assertion is RED, exactly like `WindowPoll`'s seed.
//
// RED → GREEN is the /aidev:build cell's job:
//   - ColumnAlignmentRules  → map boolean→center, numeric/date/datetime→trailing.
//   - ColumnDisplayFormatter → strict v1 grammar + Foundation Decimal.FormatStyle
//     (exact round-trip guard, half-even) + Date/ISO8601FormatStyle presets.
//   - ColumnPanelLayout      → window to O(viewport) rows (3·visible+8), not all.
//   - ColumnLabelSearch      → 1024-batch localized substring match, IDs only.
//   - ColumnSessionModel     → clear-all reset + strict internal-re-open mapping.

/// RED SEED: everything left-aligned (the pre-feature default) — so the
/// boolean-center / numeric-trailing assertions fail. Header alignment (always
/// leading) is already correct.
public struct ColumnAlignmentRules: ColumnAligning {
    public init() {}
    public func alignment(for kind: ColumnKind, isConflict: Bool) -> ColumnTextAlignment { .leading }
    public var headerAlignment: ColumnTextAlignment { .leading }
}

/// RED SEED: classify nothing (so the strict-grammar accept cases fail) and
/// preserve the original spelling for everything (Auto), so every explicit
/// grouping / fixed-fraction / localized-preset / format-unavailable assertion
/// fails until the Foundation formatter + strict grammar are built.
public struct ColumnDisplayFormatter: ColumnDisplayFormatting {
    public init() {}
    public func strictKind(of raw: String) -> ColumnScalarKind? { nil }
    public func display(raw: String, type: ColumnType, options: ColumnFormatOptions, locale: Locale) -> ColumnDisplay {
        .original(raw)
    }
}

/// RED SEED: instantiate EVERY column — the old `ForEach(0..<columnCount)` — so
/// the O(viewport) bound assertion fails on a wide document.
public struct ColumnPanelLayout: ColumnPanelLayouting {
    public init() {}
    public func plan(for viewport: ColumnPanelViewport) -> ColumnPanelPlan {
        ColumnPanelPlan(instantiatedRows: 0 ..< max(viewport.totalColumns, 0))
    }
}

/// RED SEED: report a zero batch size and match nothing, so the 1024-batch and
/// substring-match assertions fail.
public struct ColumnLabelSearch: ColumnLabelSearching {
    public init() {}
    public var batchSize: Int { 0 }
    public func matches(query: String, in candidates: [ColumnLabelCandidate], locale: Locale) -> [UInt32] { [] }
}

/// RED SEED: never clear (reset returns its input) and never map safely (always
/// resetAll), so the reset-clears and safe-replay assertions fail while the
/// unsafe-reset cases pass.
public struct ColumnSessionModel: ColumnSessionModeling {
    public init() {}
    public func reset(_ settings: [Int: ColumnUserSettings]) -> [Int: ColumnUserSettings] { settings }
    public func decide(change: ColumnReopenChange, oldCount: Int, newCount: Int,
                       oldHeaders: [ColumnHeaderIdentity]?, newHeaders: [ColumnHeaderIdentity]?) -> ColumnReopenDecision {
        .resetAll
    }
}
