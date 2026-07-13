import Foundation

/// The settings-panel-redesign's PURE column-discovery routing
/// (ARCH-column-config amendment, criteria 12/13). Settings is now the sole
/// column-configuration surface; its Columns section shows discovery/results and
/// the inspector side by side. Discovery is ADAPTIVE in the document's logical
/// column count, and every column stays reachable through exact `#N` addressing
/// even when ordinary label results are capped at ten.
///
/// This owns the DETERMINISTIC frontend decisions the ARCH calls "feature-local
/// frontend behavior outside the frozen Swift search/layout contracts": the
/// adaptive threshold, the `#N` recognizer, and the ten-result cap + overflow.
/// It sits BESIDE the unchanged `ColumnPanel.swift` contracts
/// (`ColumnPanelLayouting` still plans the virtualized row viewport;
/// `ColumnLabelSearching` still owns the localized-substring MATCH decision) —
/// this layer only ROUTES around them. No AppKit/SwiftUI here; the AppKit
/// `NSTableView` reuse and off-main search scheduling live in `LessSheetApp`.
/// Implemented in `LessSheetKit` (`ColumnDiscovery`), pinned by frozen
/// conformance + behavior tests.

/// The greatest logical column count that still shows the full, unfiltered,
/// source-order list (with NO search field). Above it there is no unfiltered
/// list: discovery is search-only (ARCH criterion 13).
public let columnDiscoveryInlineListMax: Int = 10

/// The most ordinary label results discovery ever renders/retains in source
/// order; an (max+1)-th match sets overflow ("More matches—refine your search")
/// and stops the scan (ARCH criterion 12).
public let columnDiscoveryResultMax: Int = 10

/// What the discovery area shows, as a pure function of the logical column count
/// (ARCH criterion 13).
public enum ColumnDiscoveryMode: Equatable, Sendable {
    /// Zero columns: an empty state; no column row, metadata request, or search.
    case empty
    /// 1...`columnDiscoveryInlineListMax` columns: the complete unfiltered list
    /// in source-column order, and NO search field.
    case fullList
    /// More than `columnDiscoveryInlineListMax` columns: NO unfiltered list — a
    /// search field, an empty query showing zero result rows (the inspector
    /// still shows the current selection), and exact `#N` direct addressing.
    case searchOnly
}

/// The resolution of a `#N` direct-address query (ARCH criterion 12). It is
/// frontend routing layered BEFORE `ColumnLabelSearching`, so the approved Swift
/// search contract is unchanged.
public enum ColumnDirectAddress: Equatable, Sendable {
    /// A valid 1-based `#N` in `1...columnCount`, resolved to its 0-based index.
    case column(Int)
    /// A `#`-prefixed input that is not a valid address (`#0`, a sign,
    /// whitespace, non-ASCII digits, arithmetic overflow, or `> columnCount`):
    /// "No such column", leaving the current selection unchanged.
    case noSuchColumn
}

/// The bounded running state of an ordinary label search across batches
/// (ARCH criterion 12 memory bound). It retains at most
/// `columnDiscoveryResultMax` matching IDs plus a single overflow Boolean —
/// NEVER all matching labels/IDs — so a broad query stays O(1) in retained
/// frontend memory regardless of how many labels match.
public struct ColumnMatchAccumulation: Equatable, Sendable {
    /// The first at most `columnDiscoveryResultMax` matches, in source order.
    public var retained: [UInt32]
    /// True once an (`columnDiscoveryResultMax`+1)-th match has been seen.
    public var overflow: Bool

    public init(retained: [UInt32] = [], overflow: Bool = false) {
        self.retained = retained
        self.overflow = overflow
    }

    /// The empty accumulator a fresh query starts from.
    public static let empty = ColumnMatchAccumulation()

    /// Whether the caller should STOP scanning further batches: true exactly
    /// when overflow is set (the eleventh match was found; the UI shows
    /// "More matches—refine your search" and needs no more IDs).
    public var stop: Bool { overflow }
}

/// Pure adaptive column-discovery routing (ARCH criteria 12/13). Implemented in
/// `LessSheetKit` (`ColumnDiscovery`), pinned by a frozen conformance test.
///
/// Pinned semantics (the spec the RED seed does NOT satisfy — the seed always
/// reports `.fullList`, never recognizes `#N` (`resolveDirectAddress` returns
/// `nil`), and `accumulate` retains EVERY match with overflow never set, i.e.
/// the old unbounded, always-listed panel behavior):
///
/// - `mode(columnCount:)`:
///   * `columnCount <= 0` → `.empty`;
///   * `1 ... columnDiscoveryInlineListMax` → `.fullList`;
///   * `> columnDiscoveryInlineListMax` → `.searchOnly`.
///
/// - `resolveDirectAddress(_:columnCount:)`:
///   * returns `nil` iff `query` does NOT begin with `"#"` (an ordinary label
///     query — hand it to `ColumnLabelSearching`);
///   * otherwise the entire remainder after `"#"` must be `[1-9][0-9]*` (ASCII
///     digits, no leading zero, no sign, no whitespace, no non-ASCII digits) and
///     parse without overflow to `n` with `1 <= n <= columnCount` → `.column(n - 1)`;
///   * every other `#`-prefixed value (`"#"`, `"#0"`, `"#01"`, `"#5 "`, `"#+5"`,
///     a non-ASCII digit, an overflowing run of digits, or `n > columnCount`) →
///     `.noSuchColumn`.
///   Note: a value that does NOT begin with `"#"` (e.g. a leading space `" #5"`)
///   is an ordinary label query (`nil`), never a direct address.
///
/// - `accumulate(_:matches:)` folds one batch of source-order match IDs into the
///   running accumulation: it appends in order, retains at most
///   `columnDiscoveryResultMax`, and sets `overflow` once the total number of
///   matches seen would exceed `columnDiscoveryResultMax`. Once `overflow` is
///   set, `retained` is frozen at the first `columnDiscoveryResultMax` IDs and
///   `stop` is true. Exactly `columnDiscoveryResultMax` matches is NOT overflow.
public protocol ColumnDiscoveryRouting: Sendable {
    func mode(columnCount: Int) -> ColumnDiscoveryMode
    func resolveDirectAddress(_ query: String, columnCount: Int) -> ColumnDirectAddress?
    func accumulate(_ accumulation: ColumnMatchAccumulation, matches batch: [UInt32]) -> ColumnMatchAccumulation
}
