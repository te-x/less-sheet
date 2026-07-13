/// The pending-to-resolved window poll decision (ARCH-window-budget AC7 /
/// req. 8 / Technology decision 4) — the pure heart of "keep the existing
/// 100 ms poll loop alive while the desired row window is SHORT, re-issue the
/// identical request so the retained prefix grows, and stop once it is full
/// (or proven at EOF)."
///
/// WHY THIS EXISTS. A budget-truncated `ls_window_set` returns a shorter
/// contiguous `ls_row_range`: the completed rows are present, the unreturned
/// suffix is pending (waiting on the aggregate work budget, the scan frontier,
/// or both — the two causes are DELIBERATELY indistinguishable; the frontend
/// action is identical). Before this feature the macOS model kept polling only
/// while base indexing was incomplete or a jump/search/filter was active — so a
/// budget-short window whose indexing was ALREADY complete stalled forever with
/// a permanently short window. This decision folds the short-window fact in
/// alongside the existing activity signals so the loop no longer treats
/// "index complete + short range" as "done / nothing pending."
///
/// NO NEW ABI / NO PERCENTAGE (ARCH decision 1 & 4, non-goals). The pending
/// suffix is signalled ONLY by the existing short `ls_row_range`; this decision
/// carries just two booleans and NO fraction — window completion has no stable
/// denominator, and the pending cells already supply continuous feedback via
/// the existing per-cell loading placeholder (`DocumentModel.rowLoaded`, reused
/// unchanged). The 100 ms cadence, the identical (`desiredStart`,
/// `desiredCount`) request, and the placeholder all remain the driver's
/// (`DocumentModel`) concern — this type owns only the fold/continue decision,
/// exactly as `DelayedProgressGating` owns only the show/hide decision.
///
/// PURE + HERMETIC: no core calls, no clock, no main-actor assumptions — a
/// value transform the driver folds each poll tick, unit-testable without a
/// real backend (mirrors `JumpControlling.resolve` / `FindControlling.resolved`
/// / `DelayedProgressGating.indication`).

/// The viewer's desired row window relative to what the core has RETURNED so
/// far — the retained prefix. A budget-truncated OR frontier-pending window is
/// a short contiguous prefix: fewer rows than requested, with servable rows
/// still missing.
public struct DesiredWindow: Equatable, Sendable {
    /// Rows the frontend last REQUESTED for this window (the clamped desired
    /// count — `DocumentModel.desiredCount`).
    public let requestedCount: Int
    /// Contiguous rows the core has actually RETURNED so far (the retained
    /// prefix — `RowWindow.rows.count` for the identical request).
    public let returnedCount: Int
    /// Whether the first UNRETURNED row is still inside current row-count
    /// knowledge — i.e. more rows of the requested window could still become
    /// servable by re-issuing. FALSE once the returned prefix already reaches
    /// the end of the view (an exact row count proves the remainder is past
    /// EOF), so a short file never livelocks asking for rows that cannot exist.
    /// The driver computes it as `firstRow + returnedCount < displayRowCount`.
    public let moreWithinView: Bool

    public init(requestedCount: Int, returnedCount: Int, moreWithinView: Bool) {
        self.requestedCount = requestedCount
        self.returnedCount = returnedCount
        self.moreWithinView = moreWithinView
    }

    /// SHORT — a pending prefix with servable rows still missing (AC7): fewer
    /// rows returned than requested AND more rows within the view. This is TRUE
    /// regardless of index completion — the crux of the feature: a
    /// budget-truncated window whose indexing is already complete is STILL
    /// short, and must keep being retried until it fills.
    public var isShort: Bool {
        returnedCount < requestedCount && moreWithinView
    }
}

/// One poll tick's inputs to the window-continuation decision: the desired
/// window's fill state plus the OTHER activity that independently keeps the
/// 100 ms poll alive today. Folding all of them in one place is what lets the
/// existing scan/jump/search/filter polling continue EXACTLY as before while
/// the short-window fact is added (no regression).
public struct WindowPollInputs: Equatable, Sendable {
    /// The desired window vs. the retained prefix (see `DesiredWindow`).
    public let window: DesiredWindow
    /// Whether base indexing reports complete (`ScanProgress.isComplete`). When
    /// complete the row count is exact, so `window.moreWithinView` reflects true
    /// EOF.
    public let indexComplete: Bool
    /// Whether a jump-scan is in flight (the existing `.scanning` jump flow).
    public let jumpScanning: Bool
    /// Whether a search still needs polling — its match-scan runs or a
    /// navigation is being served (the existing `searchActive` derivation).
    public let searchActive: Bool
    /// Whether a filter-scan is still ongoing (its total is not yet final; a
    /// cancelled AUTO filter-scan still counts as ongoing — the existing
    /// `filterOngoing` derivation).
    public let filterOngoing: Bool

    public init(
        window: DesiredWindow,
        indexComplete: Bool,
        jumpScanning: Bool,
        searchActive: Bool,
        filterOngoing: Bool
    ) {
        self.window = window
        self.indexComplete = indexComplete
        self.jumpScanning = jumpScanning
        self.searchActive = searchActive
        self.filterOngoing = filterOngoing
    }
}

/// The decision for one poll tick. Two booleans — no fraction, no new signal
/// (ARCH decision 4).
public struct WindowPollDecision: Equatable, Sendable {
    /// Re-issue the IDENTICAL desired row request now, so the core resumes
    /// retained work and the returned prefix grows. The driver re-materializes
    /// the SAME (`desiredStart`, `desiredCount`) range — never a suffix-only
    /// request (ARCH decision 3).
    public let reissueWindow: Bool
    /// Keep the 100 ms poll loop alive for another tick. False only when the
    /// desired window is filled (or proven at EOF) AND nothing else
    /// (index/jump/search/filter) needs polling — so a fully-resolved, idle
    /// document costs nothing.
    public let continuePolling: Bool

    public init(reissueWindow: Bool, continuePolling: Bool) {
        self.reissueWindow = reissueWindow
        self.continuePolling = continuePolling
    }
}

/// The reusable window-poll decider. Implemented in `LessSheetKit` as
/// `WindowPoll`, pinned by a frozen conformance test
/// (`let _: any WindowPolling = WindowPoll()`).
///
/// PINNED rules (this doc-comment is the spec the RED seed does NOT yet
/// satisfy):
///
/// 1. SHORT WINDOW KEEPS THE LOOP ALIVE. When `inputs.window.isShort`, the
///    decision MUST have `continuePolling == true` AND `reissueWindow == true`
///    — regardless of `indexComplete` and regardless of jump/search/filter.
///    This is the AC7 repair: a budget-short window with indexing already
///    complete keeps retrying instead of stalling.
///
/// 2. STOPS WHEN FILLED OR AT EOF. When the window is NOT short
///    (`returnedCount >= requestedCount`, or the prefix reaches the end of the
///    view so `moreWithinView == false`) AND no other activity is present, the
///    decision is `reissueWindow == false`, `continuePolling == false`. A
///    re-issue is demanded ONLY while the window is short (no needless churn on
///    a settled window).
///
/// 3. NO REGRESSION TO EXISTING POLLING. Independent of the window, an
///    incomplete index, an in-flight jump, an active search, or an ongoing
///    filter each still keeps `continuePolling == true` — the existing
///    scan/jump/search/filter poll-folding is unchanged.
///
/// 4. COARSE. The decision carries no fraction and no new callback/ABI signal —
///    the pending suffix is the existing short range; feedback is the existing
///    placeholder.
public protocol WindowPolling: Sendable {
    /// PURE, hermetic fold of one poll tick (reads no clock, makes no core
    /// call — see rules 1–4 above).
    func decide(_ inputs: WindowPollInputs) -> WindowPollDecision
}
