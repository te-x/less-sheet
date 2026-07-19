// Filtered-views contracts (ARCH-filtered-views app criteria 16–18): the
// filter poll-snapshot mirror and the "Filtered — N of M rows" banner
// view-model. The core model — a filter is an in-place VIEW MODE that remaps
// every row accessor, jump, and search into FILTERED coordinates, tracked by
// per-block counters (never a match-row list), with each match's original row
// number retrievable via the session's `sourceRow` — is normative in
// api/lesssheet.h FILTERED VIEWS and mirrored on `DocumentSession`
// (setFilter / clearFilter / filterStatus / sourceRow). The doc comments here
// restate exactly what the frozen tests pin.
//
// Composing a filter reuses the Find popup verbatim (ARCH req. 10 — "no new
// predicate UI"): the app validates the draft through `FindControlling.submit`
// and, on `.run(request)`, routes the SAME `SearchRequest` to
// `DocumentSession.setFilter` instead of `startSearch`. There is therefore no
// separate filter-composition entry point; the filter surface adds only the
// poll mirror, the source-row mapping (on the session), and this banner.

// MARK: - Filter poll snapshot

/// The filter-scan's phase (mirrors `ls_filter_state` minus IDLE, which the
/// bridge maps to a nil snapshot — no filter active, the identity view).
/// `progress` is in [0, 1], monotone within one filter; a cancelled scan (the
/// single scan slot was taken by a jump/find) carries its frozen progress while
/// the filter MODE persists.
public enum FilterScanPhase: Equatable, Sendable {
    case scanning(progress: Double)
    case done
    case cancelled(progress: Double)
}

/// One poll of the active filter (mirrors `ls_filter_status`). `total` (m) is
/// the number of matching rows counted so far — monotone within one filter,
/// exact for the counted region; `totalIsFinal` iff the filter-scan completed
/// (m final). While a filter is active this `total` equals the session's
/// `rowCount().count` (the view is m rows). A nil snapshot means no filter is
/// active.
public struct FilterSnapshot: Equatable, Sendable {
    public let phase: FilterScanPhase
    public let total: UInt64
    public let totalIsFinal: Bool

    public init(phase: FilterScanPhase, total: UInt64, totalIsFinal: Bool) {
        self.phase = phase
        self.total = total
        self.totalIsFinal = totalIsFinal
    }
}

// MARK: - The filtered banner view-model

/// The persistent "Filtered — N of M rows" indicator (ARCH req. 11 / criterion
/// 16). `matching` (N) is the matching-row count so far, converging with
/// `progress` until `matchingIsFinal`; `documentRows` (M) is the total
/// UNFILTERED document row count (see `FilterControlling.banner` — the app
/// supplies M, since while filtered the session's own `rowCount` is m);
/// `documentRowsEstimated` renders M with a "~" while the base index is still
/// converging. `progress` is the filter-scan fraction in [0, 1] shown as a %
/// while the scan runs (nil once complete — the % label + spinner appear
/// exactly while non-nil). The empty-result "no matching rows" state (criterion
/// 18) is `matching == 0 && matchingIsFinal`.
public struct FilterBanner: Equatable, Sendable {
    public let matching: UInt64
    public let documentRows: UInt64
    public let documentRowsEstimated: Bool
    public let matchingIsFinal: Bool
    public let progress: Double?

    public init(
        matching: UInt64,
        documentRows: UInt64,
        documentRowsEstimated: Bool,
        matchingIsFinal: Bool,
        progress: Double?
    ) {
        self.matching = matching
        self.documentRows = documentRows
        self.documentRowsEstimated = documentRowsEstimated
        self.matchingIsFinal = matchingIsFinal
        self.progress = progress
    }

    /// The empty-result state: the scan finished with zero matches (the grid
    /// shows "no matching rows").
    public var isEmptyResult: Bool { matchingIsFinal && matching == 0 }
}

/// Pure filter view-model logic. PINNED semantics (each is a frozen test):
///
/// - `banner(_:documentRows:)` — the "Filtered — N of M" banner for the current
///   filter poll, or nil when no filter is active (a nil snapshot ⇒ the
///   identity view, no banner). `documentRows` is the base (unfiltered)
///   row-count knowledge M the app tracks (captured from the identity view
///   before applying the filter — while filtered the session's `rowCount`
///   reports m). Mapping from the snapshot:
///     * `.scanning(p)`  → matching = total, progress = p, matchingIsFinal
///       false;
///     * `.done`         → matching = total, progress = nil, matchingIsFinal
///       true;
///     * `.cancelled(p)` → matching = total, progress = p, matchingIsFinal
///       false (the scan paused on slot contention; the mode persists, so the
///       banner keeps showing its frozen progress).
///   In every case documentRows = documentRows.count and
///   documentRowsEstimated = !documentRows.isExact.
public protocol FilterControlling: Sendable {
    func banner(_ snapshot: FilterSnapshot?, documentRows: RowCountInfo) -> FilterBanner?
}
