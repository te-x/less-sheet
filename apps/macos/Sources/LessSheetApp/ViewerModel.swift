import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The presentation model for one viewer window. Owns the live windowed
// `DocumentSession`, pages row windows as the user scrolls (O(viewport)),
// polls index/jump progress OFF the main actor, drives the jump flow, holds
// hidden-column and dialect override state, and the floating overlay's
// reveal/fade presentation state. Every open — panel, launch, CLI, drag,
// dialect re-open — funnels through `open(path:forcing:)`.

// MARK: - Layout constants (grid geometry; shared by on-screen + dump paths)

enum GridMetrics {
    static let rowHeight: CGFloat = 22
    static let minColumnWidth: CGFloat = 72
    static let maxColumnWidth: CGFloat = 360
    static let fillerColumnWidth: CGFloat = 120
    static let cellHPadding: CGFloat = 10
    /// Rows kept behind the scan frontier as scroll buffer each direction
    /// (well under LS_WINDOW_MAX_ROWS so a window request never over-asks).
    static let scrollBufferRows = 600
    /// Row-number gutter: inner horizontal padding, and a floor on the digit
    /// count so the gutter never looks cramped. The gutter is fixed against
    /// horizontal scroll and sized to the largest VISIBLE 1-based number.
    static let rowNumberHPadding: CGFloat = 8
    static let rowNumberMinDigits = 2
    /// Extra gutter width reserved, UNCONDITIONALLY, for the oversized-row
    /// marker (ARCH-huge-row-budget req. 7) drawn before the row number.
    /// Reserved regardless of whether any currently-visible row is oversized
    /// so the gutter's width never changes as oversized rows scroll in/out —
    /// a scroll-triggered geometry change is exactly the class of bug the
    /// column-width-growth fixes upstream had to correct.
    static let oversizedMarkerReserve: CGFloat = 14
    /// Extra columns kept measured/materialized on EACH side of the horizontal
    /// column window (ARCH-column-windowing) — the horizontal analog of
    /// `scrollBufferRows`: a small scroll settles inside already-accurate
    /// columns instead of immediately needing a fresh window + refine.
    static let columnOverscan = 8
    /// Extra columns FETCHED on each side of the current column window
    /// whenever `materialize` (re-)issues `setWindow(columns:)` (ARCH-column-
    /// windowing round-2, AC7) — the fetch analog of `scrollBufferRows`, sized
    /// larger than `columnOverscan` (which only pads what gets MEASURED/DRAWN)
    /// so a scroll that outgrows the drawn overscan by a handful of columns
    /// still lands inside cells already fetched instead of needing another
    /// core round-trip on the very next tick.
    static let columnFetchBuffer = 32
    /// Columns fetched for the very FIRST materialize of a session, before the
    /// grid's first geometry callback establishes a real horizontal column
    /// window (the column analog of `lastVisibleCount = 40` for rows). Every
    /// column carries at least `minColumnWidth` (72 pt), so any document with
    /// this many columns or fewer is already wider than any real viewport —
    /// i.e. it can never be a viewport-FITTING file — so this bound never
    /// shortchanges `measureColumnWidths`'s sample for a file AC4 actually
    /// applies to, while still keeping an extremely wide document's cold-open
    /// fetch O(hundreds) of columns, never O(columnCount) (the round-2 fix
    /// that carries wide_100k_cols under the AC5 budget).
    static let initialColumnFetchCount = 256
    /// End-of-file overscroll: rows of empty filler grid kept BELOW the last
    /// data row so the user can scroll a little past it and the bottom-right
    /// floating controls never cover the final rows. 5 rows (110 pt) clears the
    /// control cluster (36 pt button + 24 pt inset ≈ 60 pt) with margin. Pure
    /// fill — never counted as data (row count / scrollbar estimate ignore it).
    static let overscrollRows = 5
    /// Height of the transparent title-bar region (the window's top safe area on
    /// this chromeless titled window). The grid extends UNDER it (so content
    /// scrolls beneath and frosts) but insets its scrollable content by this much
    /// so row 1 rests fully below it at (0,0). Matches the measured safe-area top.
    static let titleBarInset: CGFloat = 32
}

struct PanelColumnLabel {
    let text: String
    let truncated: Bool
}

struct WindowCellPresentation {
    let text: String
    let formatUnavailable: Bool
    let conflict: Bool
}

@MainActor
@Observable
final class DocumentModel {
    static let shared = DocumentModel()

    enum Phase: Equatable {
        case launch                                   // nothing opened yet
        case document                                 // a document is open (may be empty)
        case failure(DocumentOpenError, path: String)
    }

    // MARK: Observable presentation state

    private(set) var phase: Phase = .launch
    /// Bumped on every completed open; keys the first-frame timing marker and
    /// the grid's `.task(id:)` refresh.
    private(set) var openGeneration = 0

    // Document facts (constant for the open session).
    private(set) var path: String = ""
    private(set) var columnCount = 0
    private(set) var headerCells: [String]?
    /// Bounded label cache for the core-backed grid fetch. Unlike the legacy
    /// protocol property, this never grows with the document: every horizontal
    /// re-materialize replaces it with exactly that buffered column window.
    private var windowColumnLabels: [Int: String] = [:]
    private var windowTruncatedLabels: Set<Int> = []
    private var windowColumnMetadata: [Int: ColumnMetadata] = [:]
    private var gridInferenceIDs: [UInt32] = []
    private var panelInferenceIDs: [UInt32] = []
    private var panelSelectedColumn: UInt32?
    private var panelLabels: [Int: PanelColumnLabel] = [:]
    private var panelMetadata: [Int: ColumnMetadata] = [:]
    private var panelFetchTask: Task<Void, Never>?
    private var columnMetadataGeneration: UInt64 = 0
    private(set) var columnPresentationRevision = 0
    private(set) var columnWidthRevision = 0
    private(set) var columnConfigurationRevision = 0
    private(set) var columnPanelRevision = 0
    private struct ColumnConfigurationEvent {
        let revision: Int
        let columns: Set<Int>
    }
    private var columnConfigurationEvents: [ColumnConfigurationEvent] = []
    private(set) var columnInferenceProgress: Double?
    private(set) var settingsLifecycle = SettingsLifecycleState()
    private var settingsDiscoveryRows: [Int] = []
    private(set) var dialect = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: false,
        separatorForced: false, quoteForced: false, headerForced: false
    )
    private(set) var columnWidths: [CGFloat] = []      // per ORIGINAL column index
    /// The current horizontal column window (ARCH-column-windowing) — the
    /// column analog of `window` (`RowWindow`): the contiguous run of columns
    /// the live grid's measure/fetch/draw stays bounded to, reported by the
    /// grid from its horizontal scroll clip (see `horizontalViewportChanged`).
    /// Indices are positions into `visibleColumns` (render order), matching
    /// what `ColumnLayouting.window(widths:...)` was given. Empty until the
    /// grid reports its first real viewport (fresh open, before any layout).
    private(set) var columnWindow = ColumnWindow(first: 0, count: 0, firstX: 0)

    // Windowed data + progress knowledge.
    private(set) var window = RowWindow(firstRow: 0, rows: [])
    private(set) var rowCountInfo = RowCountInfo(count: 0, isExact: true)
    private(set) var indexProgress = ScanProgress(bytesScanned: 0, bytesTotal: 0, isComplete: true)

    // Hidden-column + jump view-model state.
    private(set) var visibility = ColumnVisibility(columnCount: 0, hiddenColumns: [])
    private(set) var columnUserSettings: [Int: ColumnUserSettings] = [:]
    private(set) var sessionLocale = Locale.current
    private(set) var jumpFlow: JumpFlow = .idle

    // Selection + copy (ARCH-select-copy AC1-4): the live rectangular
    // selection (index space; nil = nothing selected) and a brief post-copy
    // status line (ARCH AC2: "a subtle notice"). Both session-scoped, reset
    // on every (re-)open like the find/filter state below.
    private(set) var selection: Selection?
    private(set) var copyNotice: String?

    // Find (search) session state: the editable draft + the active search's
    // display (highlights render exactly while `display.request` is non-nil).
    // The draft survives Esc / dialect re-open (query-retained semantics).
    var findSession: FindSession = FindControl().initial()

    // Filter (filtered-views) state: the active filter's poll snapshot, or nil
    // for the identity view (ARCH-filtered-views reqs. 10-18).
    // `filterDocumentRows` captures M — the base (unfiltered) row-count
    // knowledge from the identity view at the moment filtering began — held
    // fixed while filtered, since the session's own `rowCount()` reports the
    // filtered m from then on.
    private(set) var filterSnapshot: FilterSnapshot?
    private(set) var filterDocumentRows: RowCountInfo?

    // A row the grid should bring into view (jump landing / cancel restore),
    // consumed and cleared by the grid once applied.
    var pendingScrollRow: UInt64?
    /// Direct AppKit hand-off for jump/find landings. SwiftUI observation is
    /// still the state bridge of record (`pendingScrollRow`), but an update can
    /// legitimately be coalesced while the representable is attaching to its
    /// window. The native controller installs this weak callback so every
    /// landing also schedules a post-layout apply; no request is lost merely
    /// because there was no subsequent observable mutation.
    @ObservationIgnored var viewportLandingHandler: ((UInt64) -> Void)?

    // Overlay presentation state.
    var overlayRevealed = false
    var expandedPill: PillKind?
    var jumpFieldActive = false
    var findFieldActive = false
    private(set) var settingsOpen = false
    /// Bumped by the ⌘J command to ask the overlay to reveal + focus the jump
    /// field (the keyboard reveal path).
    private(set) var jumpFocusRequests = 0
    /// Bumped whenever a jump is REJECTED (target past the last row, or invalid
    /// input): the jump field re-arms and the overlay blinks/shakes it (item 4).
    private(set) var jumpRejections = 0
    /// Bumped by ⌘F to reveal the overlay + focus the find field.
    private(set) var findFocusRequests = 0
    /// Bumped whenever a find submit is REJECTED (ordering predicate with a
    /// non-numeric value): the value field blinks red + shakes (Reduce Motion =
    /// blink only), reusing the jump rejection components.
    private(set) var findRejections = 0

    // MARK: Collaborators (pure view-model logic; pinned by frozen tests)

    private let opener: any DocumentSessionOpening
    private let visibilityManager = ColumnVisibilityManager()
    /// The pure horizontal column-window geometry + width-growth algebra
    /// (ARCH-column-windowing); see `horizontalViewportChanged` /
    /// `growColumnWidthsToFitWindow`.
    private let columnLayout = ColumnLayout()
    private let jumpControl = JumpControl()
    private let composer = DialectComposer()
    private let findControl = FindControl()
    private let filterControl = FilterControl()
    private let windowPoll = WindowPoll()
    private let cellMatcher = CellMatcher()
    /// The pure selection geometry, TSV copy builder, and column-width algebra
    /// (ARCH-select-copy) — same layering as the collaborators above.
    private let selectionModel = SelectionModel()
    private let copyBuilder = TSVCopyBuilder()
    private let columnSizer = ColumnSizer()
    /// The direction of the outstanding search navigation (drives the wrap
    /// notice's start/end choice when a poll reports exhaustion).
    private var searchNavDirection: SearchDirection = .forward

    private var session: (any DocumentSession)?
    private var markedGeneration = -1
    private var firstVisibleRow = 0
    /// `visibilityManager.visibleColumns(visibility)`, memoized: kept in
    /// lockstep by `setVisibility` (the ONLY place `visibility` is assigned)
    /// so every read is O(1) — this list is read many times per frame (every
    /// visible row's cells/truncation/highlights, the header labels, the
    /// widths) and a fresh `0..<columnCount` filter on each of those reads
    /// would itself be the O(total-columns) cost this slice removes, on a
    /// wide document with nothing hidden (ARCH-column-windowing).
    private var cachedVisibleColumns: [Int] = []
    /// `visibleColumns.map { Double(columnWidths[$0]) }`, plus its sum, both
    /// memoized together and rebuilt ONLY when `markLayoutWidthsStale` is
    /// called — after a width batch changes (open, or a monotone grow) or
    /// `visibility` changes — never per scroll tick. ARCH-column-windowing
    /// calls for exactly this ("rebuilt only when a width batch changes, off
    /// the per-frame path"): converting/summing 100k `CGFloat`s is measurably
    /// NOT free in a debug build (tens of ms, closure/array overhead), so
    /// recomputing either on every call would silently reintroduce an
    /// O(columnCount) per-frame cost this whole slice exists to remove.
    private var cachedLayoutWidths: [Double] = []
    private var cachedTotalVisibleWidth: CGFloat = 0
    private var layoutWidthsStale = true
    /// Set on a header on/off re-open (consumed by the grid): how a data-row
    /// index shifts across the re-derivation so the viewport can re-anchor to the
    /// SAME file record. +1 when the header turns OFF (the former header record
    /// becomes data row 0, pushing every data row down one), −1 when it turns ON
    /// (the first data row is absorbed as the header), 0 for a no-op. `nil` for a
    /// fresh open or a separator/quote change (those rest at the top as before).
    private var pendingHeaderShift: Int?
    private var lastVisibleCount = 1
    private var desiredStart: UInt64 = 0
    private var desiredCount = 0
    private var pollTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var wrapNavTask: Task<Void, Never>?
    /// Whether a copy build is currently running off-main. `private(set)` (not
    /// fully private) so verification (`SelectCopyProbe`) can poll for a
    /// SPECIFIC copy's completion without racing a stale `copyNotice` left
    /// over from a PRIOR copy (`copyNotice` alone can't tell "this" copy's
    /// completion apart from the last one's, since consecutive copies can
    /// legitimately produce identical notice text).
    private(set) var copyInFlight = false
    private var copyNoticeTask: Task<Void, Never>?
    /// The off-main copy build (ARCH-select-copy round 2, findings 2/3):
    /// stored so a fresh ⌘C, Esc, or the "Copying…" notice's Cancel button
    /// can cancel a running one (`cancelCopy`) rather than leaving it to
    /// finish unseen. See `cancelCopy`'s doc comment for exactly what
    /// cancellation can and cannot interrupt.
    private var copyTask: Task<Void, Never>?
    /// Manual column-width overrides (ARCH-select-copy AC5), keyed by ABSOLUTE
    /// column index — session-scoped, reset on every (re-)open. Layered over
    /// the AUTO baseline (`columnWidths`) via `ColumnSizing.effectiveWidths`
    /// wherever a width is read for drawing/layout; `growColumnWidthsToFitWindow`
    /// skips an overridden column so auto-grow never fights it.
    private var manualColumnWidths: [Int: Double] = [:]
    /// ARCH-stream-copy AC8/AC9: ONE shared gate + clock driving the "subtle
    /// progress after ~500 ms" affordance for every long op this model tracks
    /// (copy / jump-scan / filter-scan) — see `copyProgress` /
    /// `jumpProgressIndication` / `filterProgressIndication` below, and
    /// `DelayedProgressSpinner` for the rendered affordance. One instance
    /// means one shared threshold band the whole app reads consistently.
    private let progressGate = DelayedProgressGate()
    private let progressClock = ContinuousClock()
    private var copyStartedAt: ContinuousClock.Instant?
    private var jumpScanStartedAt: ContinuousClock.Instant?
    private var filterScanStartedAt: ContinuousClock.Instant?
    /// Bumped on every `copySelection()` call — lets the delayed-reveal task
    /// below (`copySelection`) tell "am I still THIS copy?" apart from the
    /// shared `copyInFlight` flag, which is true for ANY in-flight copy: a
    /// rapid supersede (⌘C again before the threshold) would otherwise let a
    /// stale task, woken at the OLD copy's threshold, reveal progress for the
    /// NEW copy using the old elapsed (round-2 review finding).
    private var copyGeneration = 0
    /// COPY's live delayed-progress indication (AC8): hidden until the
    /// running copy passes the shared threshold, then visible with cancel;
    /// cleared by `completeCopy`/`cancelCopy`. Recomputed once, at the
    /// threshold tick in `copySelection` — copy needs no finer resolution
    /// (accuracy is a non-goal; ARCH scope).
    private(set) var copyProgress: ProgressIndication = .hidden

    init(opener: any DocumentSessionOpening = CoreSessionOpener()) {
        self.opener = opener
    }

    // MARK: - Opening (single funnel)

    /// The one open path shared by panel / launch / CLI / drag. `forcing`
    /// defaults to sniff-all (a fresh open); dialect re-opens pass a composed
    /// override and carry the caller's prior column visibility.
    func open(path: String, forcing override: DialectOverride = .sniffAll, carrying previous: ColumnVisibility? = nil) async {
        await stopPolling()
        // Cancel any in-flight copy against the OLD handle BEFORE closing it
        // (round-4 UAF fix): an orphaned copy build keeps calling
        // `session.copyCell` from a detached Task after `cancelCopy` merely
        // asks it to stop, so the handle must still be open while that ask
        // lands — closing first left a window where the orphaned build could
        // call `ls_cell_copy` on an already-freed `doc`.
        cancelCopy()
        let oldSession = session
        let oldDialect = dialect
        let authoredSettings = columnUserSettings
        let authoredManualWidths = manualColumnWidths

        do {
            let candidate = try await opener.open(path: path, forcing: override)
            var replayAuthoredSettings = false
            var reopenDecision: ColumnReopenDecision?
            if previous != nil, let oldSession {
                let headerOnly = oldDialect.separator == candidate.dialect.separator
                    && oldDialect.quote == candidate.dialect.quote
                    && oldDialect.encoding == candidate.dialect.encoding
                let change: ColumnReopenChange = headerOnly ? .headerOnly : .separatorQuoteEncoding
                let oldHeaders = change == .separatorQuoteEncoding ? Self.headerIdentities(oldSession) : nil
                let newHeaders = change == .separatorQuoteEncoding ? Self.headerIdentities(candidate) : nil
                let decision = ColumnSessionModel().decide(
                    change: change, oldCount: oldSession.columnCount, newCount: candidate.columnCount,
                    oldHeaders: oldHeaders, newHeaders: newHeaders
                )
                reopenDecision = decision
                replayAuthoredSettings = decision == .replayOrdinally

                if replayAuthoredSettings, let core = candidate as? CoreDocumentSession {
                    var replaySucceeded = true
                    for (column, setting) in authoredSettings {
                        guard let id = UInt32(exactly: column),
                              core.setColumnOverride(setting.overrideType, column: id),
                              core.setColumnNullSentinel(setting.nullSentinel, column: id) else {
                            replaySucceeded = false
                            break
                        }
                    }
                    if !replaySucceeded {
                        candidate.close()
                        startPolling()
                        return
                    }
                }
            }

            oldSession?.close()
            let session = candidate
            self.session = candidate
            self.path = path
            self.columnCount = session.columnCount
            self.dialect = session.dialect
            if session is CoreDocumentSession {
                // Do not touch the compatibility `headerCells` property here:
                // it intentionally materializes all labels for legacy callers.
                self.headerCells = session.dialect.hasHeader ? [] : nil
            } else {
                self.headerCells = session.headerCells
            }
            self.windowColumnLabels = [:]
            self.windowTruncatedLabels = []
            self.windowColumnMetadata = [:]
            self.gridInferenceIDs = []
            self.panelInferenceIDs = []
            self.panelSelectedColumn = nil
            self.panelLabels = [:]
            self.panelMetadata = [:]
            self.panelFetchTask?.cancel()
            self.panelFetchTask = nil
            self.columnMetadataGeneration = 0
            self.columnInferenceProgress = nil
            self.columnPresentationRevision += 1
            self.rowCountInfo = session.rowCount()
            self.indexProgress = session.indexProgress()
            if let reopenDecision {
                self.settingsLifecycle = SettingsLifecycleReducer().parsingReopened(
                    self.settingsLifecycle, decision: reopenDecision, columnCount: session.columnCount
                )
            } else {
                self.settingsLifecycle = SettingsLifecycleReducer().documentOpened(columnCount: session.columnCount)
            }
            self.settingsDiscoveryRows = []
            if self.settingsOpen {
                self.panelSelectedColumn = self.settingsLifecycle.selection.flatMap(UInt32.init(exactly:))
            }

            // Hidden-column state: carry across a re-open when the column count
            // is unchanged, else reset to all-visible (ARCH req. 10).
            if let previous, replayAuthoredSettings {
                setVisibility(visibilityManager.carriedOver(previous, toColumnCount: session.columnCount))
            } else {
                setVisibility(visibilityManager.allVisible(columnCount: session.columnCount))
                self.columnUserSettings = [:]
                if previous == nil { self.sessionLocale = .current }
                if previous == nil { self.pendingHeaderShift = nil } // a fresh open never re-anchors
            }

            // Verification-only: pre-hide columns (comma-separated indices) so a
            // headless dump can show hidden-column reflow. Absent in normal use.
            if previous == nil, let raw = ProcessInfo.processInfo.environment["LESSSHEET_HIDE_COLS"] {
                for token in raw.split(separator: ",") {
                    if let column = Int(token.trimmingCharacters(in: .whitespaces)) {
                        setVisibility(visibilityManager.toggling(self.visibility, column: column))
                    }
                }
            }
            // The horizontal window is a function of the widths this open is
            // about to establish; it resets here and the grid re-derives it
            // from its (possibly unchanged) viewport on the next layout pass.
            self.columnWindow = ColumnWindow(first: 0, count: 0, firstX: 0)

            // First window from the top; frozen column widths from that head
            // sample (O(head), measured once for the session).
            self.firstVisibleRow = 0
            self.lastVisibleCount = 40   // sensible default until the first geometry callback
            materialize(start: 0, count: GridMetrics.scrollBufferRows)
            self.columnWidths = Self.measureColumnWidths(
                header: self.headerCells,
                sample: window.rows,
                columnCount: session.columnCount
            )
            markLayoutWidthsStale()
            self.setJumpFlow(.idle)
            // New document identity: the core's search AND filter state died
            // with the old handle — clear results/highlights, retain the typed
            // query so re-running is one Enter (ARCH req. 10;
            // FindControlling.invalidated); a fresh/re-opened session has no
            // filter either (ARCH-filtered-views req. 9).
            self.cancelWrapNav()
            self.findSession = findControl.invalidated(self.findSession)
            self.searchNavDirection = .forward
            self.filterSnapshot = nil
            self.filterDocumentRows = nil
            self.filterScanStartedAt = nil
            self.pendingScrollRow = nil
            // Session-scoped select-copy state dies with the old handle too
            // (ARCH-select-copy): row/column indices from a prior document are
            // meaningless here. `cancelCopy` already ran at the TOP of this
            // method, BEFORE the old handle closed (round-4 UAF fix) — by now
            // there is nothing left to cancel, only this leftover selection
            // state to clear.
            self.selection = nil
            if !replayAuthoredSettings {
                self.manualColumnWidths = [:]
                self.columnUserSettings = [:]
            } else {
                self.manualColumnWidths = authoredManualWidths
                self.columnUserSettings = authoredSettings
            }
            self.phase = .document
            startPolling()
        } catch {
            if previous != nil, oldSession != nil {
                self.session = oldSession
                startPolling()
            } else {
                oldSession?.close()
                self.session = nil
                self.phase = .failure(error, path: path)
            }
        }
        openGeneration += 1
        if SettingsRedesignProbe.active {
            DispatchQueue.main.async {
                AppDelegate.shared?.runSettingsProbeAfterFirstPaint(model: self)
            }
        }
    }

    /// Ordered decoded identities for the strict dialect/encoding re-open
    /// check. This path runs only for an explicit Parsing change, never cold
    /// open; the core copy itself stays in ABI-bounded batches.
    private static func headerIdentities(_ session: any DocumentSession) -> [ColumnHeaderIdentity]? {
        guard session.dialect.hasHeader else { return nil }
        if let core = session as? CoreDocumentSession {
            var identities = [ColumnHeaderIdentity]()
            identities.reserveCapacity(session.columnCount)
            var start = 0
            while start < session.columnCount {
                let end = min(session.columnCount, start + columnLabelSearchBatchMax)
                let values = core.columnLabels((start..<end).map { UInt32($0) })
                guard values.count == end - start else { return nil }
                identities.append(contentsOf: values.map { $0 ?? ColumnHeaderIdentity(bytes: [], truncated: false) })
                start = end
            }
            return identities
        }
        guard let headers = session.headerCells, headers.count == session.columnCount else { return nil }
        return headers.map { ColumnHeaderIdentity(bytes: Array($0.utf8), truncated: false) }
    }

    /// Re-open the current document with one dialect parameter changed
    /// (popup / Settings edit). Returns false — with no re-open — when the
    /// selection is invalid (`DialectComposing` rejected it).
    @discardableResult
    func applyDialectChange(_ change: DialectChange) -> Bool {
        guard case .document = phase, let override = composer.compose(from: dialect, changing: change) else {
            return false
        }
        let path = self.path
        let carried = self.visibility
        // A header toggle preserves the viewport: record how the data-row index
        // shifts so the grid can re-anchor to the same file record across the
        // re-open (it captures its own exact top row from the live scroll, so we
        // only pass the ±1 shift). A separator/quote change resets to the top.
        if case let .header(newValue) = change {
            pendingHeaderShift = (newValue == dialect.hasHeader) ? 0 : (newValue ? -1 : +1)
        } else {
            pendingHeaderShift = nil
        }
        Task { await self.open(path: path, forcing: override, carrying: carried) }
        return true
    }

    /// The grid reads (and clears) the pending header-toggle shift when it handles
    /// a re-open, to decide whether to re-anchor the viewport (header toggle) or
    /// rest at the top-left (every other open). Returns nil when there is none.
    func consumePendingHeaderShift() -> Int? {
        defer { pendingHeaderShift = nil }
        return pendingHeaderShift
    }

    func closeDocument() {
        // cancelCopy() BEFORE close() — same round-4 UAF fix as `open()`: an
        // orphaned copy must stop touching the handle before it's freed.
        Task { await stopPolling(); cancelCopy(); session?.close(); session = nil }
    }

    // MARK: - Windowed paging (O(viewport); UI-thread fast path)

    /// The grid reports its visible row range on scroll/resize; we page the
    /// core window (viewport + 2× scroll buffer) only when the range leaves a
    /// comfort zone inside the current window. `setWindow` never scans, so this
    /// stays on the main thread per the contract.
    func viewportChanged(firstVisibleRow: Int, visibleRowCount: Int) {
        guard columnCount > 0 else { return }
        self.firstVisibleRow = max(0, firstVisibleRow)
        self.lastVisibleCount = max(visibleRowCount, 1)

        let buffer = GridMetrics.scrollBufferRows
        let guardRows = min(buffer / 3, 200)
        let wStart = Int(window.firstRow)
        let wLen = window.rows.count
        let v = self.firstVisibleRow
        let vc = self.lastVisibleCount

        let coversLeft = wStart == 0 || v >= wStart + guardRows
        let coversRight = (v + vc <= wStart + wLen - guardRows) || (wStart + wLen >= displayRowCount)
        if wLen > 0 && coversLeft && coversRight { return }

        let newStart = max(0, v - buffer)
        let newCount = vc + buffer * 2
        materialize(start: UInt64(newStart), count: newCount)
        if desiredWindow.isShort {
            // A settled document's poll task may already have exited. Wake the
            // coalesced driver for this changed request so its short prefix is
            // retried at the normal cadence until it fills or reaches EOF.
            startPolling()
        }
    }

    /// The grid reports its horizontal scroll clip (x-offset + viewport
    /// width) so the column window can be (re)derived, newly-revealed columns
    /// RE-FETCHED once the comfort zone of the last `setWindow(columns:)` call
    /// is exhausted (ARCH-column-windowing round-2, "Horizontal-scroll
    /// re-materialize" — see the coversLeft/coversRight check below, which
    /// mirrors `viewportChanged`'s row-window one), and accurately measured —
    /// the horizontal analog of `viewportChanged`'s row window. The widths
    /// array fed to `ColumnLayouting.window` is the MEMOIZED
    /// `cachedLayoutWidths` (rebuilt only on a width-batch change, never
    /// here), so a scroll tick is genuinely O(1) setup + `window`'s own
    /// O(window position) scan, plus an O(window) `setWindow(columns:)`
    /// re-fetch only when the comfort zone ran out — never O(columnCount)
    /// either way. A no-op once the window settles (unchanged from the last
    /// report), so neither the fetch nor `growColumnWidthsToFitWindow`
    /// re-touches a stable window.
    func horizontalViewportChanged(viewportX: CGFloat, viewportWidth: CGFloat) {
        refreshLayoutWidthsIfNeeded()
        guard !cachedLayoutWidths.isEmpty else { return }
        let win = columnLayout.window(
            widths: cachedLayoutWidths, viewportX: Double(viewportX), viewportWidth: Double(viewportWidth),
            overscan: GridMetrics.columnOverscan
        )
        guard win != columnWindow else { return }
        columnWindow = win

        // Re-materialize ONLY when the new window would spill past the LAST
        // fetch (`window.firstColumn` .. its rows' width) beyond a
        // `columnOverscan` comfort margin — a small scroll settles inside an
        // already-fetched range with no extra core call; the moment it does
        // not, re-issuing setWindow(columns:) over the SAME row range (via
        // `materialize`) fetches the newly-revealed columns' real cells
        // before they are drawn, and `materialize` itself re-runs
        // `growColumnWidthsToFitWindow` against the refreshed cells — so this
        // branch does not also call it directly.
        let target = absoluteColumnWindow()
        let guardCols = GridMetrics.columnOverscan
        let fetchedEnd = window.firstColumn + (window.rows.first?.count ?? 0)
        let coversLeft = target.isEmpty || window.firstColumn == 0 || target.lowerBound >= window.firstColumn + guardCols
        let coversRight = target.isEmpty || target.upperBound <= fetchedEnd - guardCols || fetchedEnd >= columnCount
        if !window.rows.isEmpty, coversLeft, coversRight {
            growColumnWidthsToFitWindow()
        } else {
            materialize(start: desiredStart, count: desiredCount)
        }
    }

    /// The ABSOLUTE column range the CURRENT `columnWindow` spans — the
    /// enclosing span of its in-window visible columns
    /// (`windowColumns().first ..< .last + 1`). Identical to `columnWindow.
    /// range` whenever no column is hidden (every existing fixture, and
    /// wide_100k_cols); a hidden column strictly BETWEEN two in-window visible
    /// ones is folded in too — `setWindow(columns:)` needs one contiguous
    /// absolute range, and this is a cheap superset, never a fresh
    /// `0..<columnCount` scan. Empty (`0..<0`) before any column window is
    /// established (a fresh open) or when nothing is in view.
    private func absoluteColumnWindow() -> Range<Int> {
        let cols = windowColumns()
        guard let first = cols.first, let last = cols.last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// The ABSOLUTE column range `materialize` asks the core to fetch: the
    /// current column window (`absoluteColumnWindow`) padded by
    /// `columnFetchBuffer` on each side and clamped to `0..<columnCount` — the
    /// horizontal analog of `viewportChanged`'s buffered `newStart`/`newCount`
    /// row request, so a horizontal scroll settles inside an already-fetched
    /// range instead of re-materializing on every tick. Before the grid's
    /// first geometry callback (`columnWindow` still empty — a fresh open)
    /// falls back to the leftmost `initialColumnFetchCount` columns (see its
    /// doc) rather than the whole document: `measureColumnWidths`'s head
    /// sample reads exactly this fetch, which is what makes the session's
    /// FIRST materialize — and every one after it — O(hundreds) of columns,
    /// never O(columnCount) (ARCH-column-windowing round-2, AC7).
    private func columnFetchRange() -> Range<Int> {
        guard columnCount > 0 else { return 0..<0 }
        guard !columnWindow.isEmpty else {
            return 0..<min(columnCount, GridMetrics.initialColumnFetchCount)
        }
        let target = absoluteColumnWindow()
        let buffer = GridMetrics.columnFetchBuffer
        return max(0, target.lowerBound - buffer) ..< min(columnCount, target.upperBound + buffer)
    }

    /// Rebuilds `cachedLayoutWidths` (render-order `Double` widths) and
    /// `cachedTotalVisibleWidth` (their sum) TOGETHER, in one O(visible
    /// columns) pass — but only when `layoutWidthsStale` is set (see
    /// `markLayoutWidthsStale`); a no-op otherwise. The single shared pass
    /// means a structural refresh (`totalVisibleWidth`) and a scroll-driven
    /// window query (`horizontalViewportChanged`) never each pay their own
    /// separate O(columnCount) traversal for the same underlying data.
    private func refreshLayoutWidthsIfNeeded() {
        guard layoutWidthsStale else { return }
        let cols = visibleColumns
        // Hoisted to a LOCAL once: `columnWidths` is an `@Observable`-tracked
        // property, and re-reading it from inside a 100k-iteration loop pays
        // that tracking overhead 100k times over — measurably significant in
        // a debug build, not merely theoretical (this loop's whole reason for
        // existing is to pay that cost exactly ONCE per width batch).
        let source = columnWidths
        // Hoisted alongside `source` for the SAME reason (see above): an
        // EMPTY manual map (the common case) makes the per-iteration check
        // below one dictionary-is-empty test, not a hash + lookup, 100k times.
        let manual = manualColumnWidths
        var widths = [Double](repeating: 0, count: cols.count)
        var total: CGFloat = 0
        for i in 0..<cols.count {
            let c = cols[i]
            let auto = c < source.count ? source[c] : GridMetrics.minColumnWidth
            // EFFECTIVE width (ARCH-select-copy AC5): a manual override wins,
            // regardless of the auto baseline — this is what keeps
            // `cachedLayoutWidths`/`cachedTotalVisibleWidth` (the column-
            // window geometry + total-width inputs) honest about a resize.
            let w = manual.isEmpty ? auto : (manual[c].map { CGFloat($0) } ?? auto)
            widths[i] = Double(w)
            total += w
        }
        cachedLayoutWidths = widths
        cachedTotalVisibleWidth = total
        layoutWidthsStale = false
    }

    /// Invalidates `cachedLayoutWidths` / `cachedTotalVisibleWidth` — call
    /// after every `columnWidths` or `visibility` change (a width batch: a
    /// fresh open's `measureColumnWidths`, or `growColumnWidthsToFitWindow`'s
    /// monotone grow) so the next read rebuilds from the NEW values instead
    /// of serving a stale cache.
    private func markLayoutWidthsStale() {
        layoutWidthsStale = true
    }

    /// Materializes the row window AND the current horizontal column window
    /// together (ARCH-column-windowing round-2, AC7): `columnFetchRange`
    /// derives the ABSOLUTE column range from `columnWindow` (or the
    /// open-time default before one exists), so this fetches O(visible
    /// columns), never O(columnCount) — see `CoreDocumentSession.setWindow
    /// (firstRow:rowCount:columns:)`. `window.firstColumn`/each row's width
    /// then reflect that range; every consumer below indexes it
    /// column-relative (absolute column `c` at slot `c - window.firstColumn`).
    private func materialize(start: UInt64, count: Int) {
        guard let session else { return }
        desiredStart = start
        desiredCount = count
        let columns = columnFetchRange()
        window = session.setWindow(firstRow: start, rowCount: count, columns: columns)
        refreshWindowLabels(columns: columns)
        growColumnWidthsToFitWindow()
    }

    /// Refreshes only the buffered horizontal label window. The core ABI caps
    /// a call at 1024 IDs, so unusually large viewports are split into bounded
    /// batches while the retained cache remains O(the fetch window).
    private func refreshWindowLabels(columns: Range<Int>) {
        guard let core = session as? CoreDocumentSession else { return }
        var labels: [Int: String] = [:]
        var truncatedLabels: Set<Int> = []
        var metadata: [Int: ColumnMetadata] = [:]
        labels.reserveCapacity(columns.count)
        metadata.reserveCapacity(columns.count)
        var start = columns.lowerBound
        while start < columns.upperBound {
            let end = min(columns.upperBound, start + columnLabelSearchBatchMax)
            let ids = (start..<end).map { UInt32($0) }
            let values = dialect.hasHeader ? core.columnLabels(ids) : Array(repeating: nil, count: ids.count)
            let snapshots = core.columnMetadata(ids)
            for (offset, value) in values.enumerated() {
                guard let value, !value.bytes.isEmpty else { continue }
                labels[start + offset] = String(decoding: value.bytes, as: UTF8.self)
                if value.truncated { truncatedLabels.insert(start + offset) }
            }
            for snapshot in snapshots { metadata[snapshot.column] = snapshot }
            start = end
        }
        windowColumnLabels = labels
        windowTruncatedLabels = truncatedLabels
        windowColumnMetadata = metadata
        gridInferenceIDs = columns.prefix(columnLabelSearchBatchMax).compactMap(UInt32.init(exactly:))
        requestCoordinatedInference(core)
        columnPresentationRevision += 1
    }

    /// Declares the panel's layout-bounded viewport+overscan ID set. Label and
    /// metadata copies happen off-main and replace the prior bounded cache.
    func updatePanelViewport(_ ids: [UInt32]) {
        let bounded = Array(ids.prefix(columnLabelSearchBatchMax))
        guard bounded != panelInferenceIDs else { return }
        panelInferenceIDs = bounded
        let retained = Set(bounded.map(Int.init))
        panelLabels = panelLabels.filter { retained.contains($0.key) }
        panelMetadata = panelMetadata.filter { retained.contains($0.key) }
        panelFetchTask?.cancel()
        guard let core = session as? CoreDocumentSession, !bounded.isEmpty else {
            requestCoordinatedInference(core: session as? CoreDocumentSession)
            columnPanelRevision += 1
            return
        }
        requestCoordinatedInference(core)
        startPolling()
        panelFetchTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                (core.columnLabels(bounded), core.columnMetadata(bounded))
            }.value
            guard let self, !Task.isCancelled, self.panelInferenceIDs == bounded else { return }
            var labels: [Int: PanelColumnLabel] = [:]
            for (offset, id) in bounded.enumerated() {
                guard offset < snapshot.0.count, let value = snapshot.0[offset], !value.bytes.isEmpty else { continue }
                labels[Int(id)] = PanelColumnLabel(text: String(decoding: value.bytes, as: UTF8.self),
                                                   truncated: value.truncated)
            }
            self.panelLabels = labels
            self.panelMetadata = Dictionary(uniqueKeysWithValues: snapshot.1.map { ($0.column, $0) })
            self.columnPanelRevision += 1
        }
    }

    func setPanelSelection(_ column: Int?) {
        panelSelectedColumn = column.flatMap(UInt32.init(exactly:))
        guard let core = session as? CoreDocumentSession else { return }
        requestCoordinatedInference(core)
        startPolling()
    }

    func closeColumnPanel() {
        panelFetchTask?.cancel()
        panelFetchTask = nil
        panelInferenceIDs = []
        panelSelectedColumn = nil
        panelLabels = [:]
        panelMetadata = [:]
        requestCoordinatedInference(core: session as? CoreDocumentSession)
        if !gridInferenceIDs.isEmpty { startPolling() }
    }

    private func coordinatedInferenceIDs() -> [UInt32] {
        // Panel rows are the actively inspected viewport and must never be
        // starved by a very wide grid window consuming the ABI's 1024-ID cap.
        // The selected inspector column is first, then panel viewport, then
        // the grid fills the remaining bounded slots.
        var ids = panelSelectedColumn.map { [$0] } ?? []
        for id in panelInferenceIDs where !ids.contains(id) && ids.count < columnLabelSearchBatchMax {
            ids.append(id)
        }
        for id in gridInferenceIDs where !ids.contains(id) && ids.count < columnLabelSearchBatchMax {
            ids.append(id)
        }
        return ids
    }

    private func requestCoordinatedInference(_ core: CoreDocumentSession) {
        let ids = coordinatedInferenceIDs()
        if !ids.isEmpty { _ = core.requestColumnInference(ids) }
    }

    private func requestCoordinatedInference(core: CoreDocumentSession?) {
        guard let core else { return }
        requestCoordinatedInference(core)
    }

    private var desiredWindow: DesiredWindow {
        DesiredWindow(
            requestedCount: desiredCount,
            returnedCount: window.rows.count,
            moreWithinView: Int(window.firstRow) + window.rows.count < displayRowCount
        )
    }

    /// The DECIDED width behaviour (ARCH-column-windowing "Column-width
    /// behaviour" / AC5b): grow — never shrink — each column CURRENTLY IN THE
    /// HORIZONTAL WINDOW to fit its OWN content over the just-materialized
    /// vertical row window, capped at maxColumnWidth, and merged through
    /// `ColumnLayouting.grown` so the merge is provably independent (one
    /// column's candidate never moves another's width) and monotone (a
    /// horizontal scroll that re-measures an already-established column over
    /// the SAME vertical window always yields the SAME candidate, so it never
    /// churns). Bounded to `columnWindow` — a few tens to a few hundred
    /// columns, NEVER `columnCount` — so this stays cheap however wide the
    /// document is; called on every materialize (vertical scroll/jump) AND
    /// every horizontal-window change (`horizontalViewportChanged`), so a
    /// column gets an accurate body-cell refine when it is revealed either
    /// way. Header contribution is refined only before the first frame: the
    /// initial viewport receives exact header sizing, while an off-window
    /// column keeps its deterministic open-time width when later revealed.
    /// That avoids both an O(all-columns) header preflight on cold-open and a
    /// visible header-driven width jump during horizontal reveal. Explicit
    /// auto-fit/configuration can still intentionally remeasure one column.
    /// A cell the core already clipped — display-TRUNCATED
    /// (`RowWindow.truncated`), or any cell of an OVERSIZED row
    /// (`RowWindow.oversized`, ARCH-huge-row-budget) — is excluded from the
    /// measurement: it isn't the cell's real content, just a cut prefix, so
    /// growing a column to fit it shows no more of the cell (the truncation
    /// mark still shows) while it CAN force a spurious horizontal scroller on
    /// an otherwise normal-width landing (the giant-row case). `window.rows`
    /// is column-RELATIVE to `window.firstColumn` (ARCH-column-windowing
    /// round-2): an in-window absolute column `c` reads slot `c -
    /// window.firstColumn`, guarded — `materialize`'s `columnFetchRange`
    /// always fetches (at least) `columnWindow` first, so that slot is normally
    /// in range; the guard only degrades gracefully mid-transition.
    private func growColumnWidthsToFitWindow() {
        guard columnCount > 0, !window.rows.isEmpty, columnWidths.count == columnCount else { return }
        // Measure only the VISIBLE slice (~a viewport), not the whole buffered
        // window — keeps this off the landing hot path (<100 ms budget); growth
        // keeps up incrementally as further scrolls re-materialize.
        let start = Int(window.firstRow)
        let lo = max(start, firstVisibleRow)
        let hi = min(start + window.rows.count, firstVisibleRow + max(lastVisibleCount, 1))
        guard lo < hi else { return }

        refreshLayoutWidthsIfNeeded()
        let cols = visibleColumns
        guard !cols.isEmpty else { return }
        let inWindow = columnWindow.range.clamped(to: 0..<cols.count)
        guard !inWindow.isEmpty else { return }

        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let refineHeaderWidths = markedGeneration != openGeneration
        // Keyed by VISIBLE POSITION (an index into `cachedLayoutWidths`, the
        // SAME array `horizontalViewportChanged` feeds `ColumnLayouting.
        // window`) rather than absolute column index — `grown` doesn't care
        // which an index means, and this lets the merge below reuse the
        // already-memoized `[Double]` array directly instead of re-converting
        // all of `columnWidths` (O(columnCount), and — measured — genuinely
        // costly in a debug build) just to touch a handful of entries.
        let base = window.firstColumn   // column-relative base, see the doc above
        var candidates: [Int: Double] = [:]
        for pos in inWindow {
            let c = cols[pos]
            guard c < columnWidths.count else { continue }
            // A manually-resized column is FROZEN (ARCH-select-copy AC5:
            // auto-grow never overrides a manual width) — skip measuring it
            // so its auto baseline (and the effective-width cache) stay
            // exactly as the user set them until they clear/auto-fit it.
            guard manualColumnWidths[c] == nil else { continue }
            let rel = c - base
            var w = refineHeaderWidths ? Self.textWidth(columnLabel(c), headFont) : 0
            for r in lo..<hi {
                let idx = r - start
                if idx < window.oversized.count, window.oversized[idx] { continue }
                let row = window.rows[idx]
                guard rel >= 0, rel < row.count else { continue }
                if idx < window.truncated.count, rel < window.truncated[idx].count, window.truncated[idx][rel] { continue }
                w = max(w, Self.textWidth(row[rel], bodyFont))
            }
            let capped = min(w + GridMetrics.cellHPadding * 2, GridMetrics.maxColumnWidth)
            if capped > columnWidths[c] + 0.5 { candidates[pos] = Double(capped) }
        }
        guard !candidates.isEmpty else { return }

        let grownWidths = columnLayout.grown(cachedLayoutWidths, mergingCandidates: candidates)
        var widths = columnWidths
        for pos in candidates.keys {
            let c = cols[pos]
            let newWidth = CGFloat(grownWidths[pos])
            cachedTotalVisibleWidth += newWidth - widths[c]
            widths[c] = newWidth
        }
        columnWidths = widths
        cachedLayoutWidths = grownWidths   // stays in lockstep; no need to mark stale
    }

    /// Cells for a data row, read from the currently materialized window —
    /// COLUMN-RELATIVE to `window.firstColumn` (ARCH-column-windowing
    /// round-2): slot `j` is absolute column `window.firstColumn + j`, NOT
    /// absolute column `j` itself, whenever the window is narrower than
    /// `columnCount`. Rows outside the window return `nil` (the grid renders
    /// empty cells that fill in once the frontier advances and the window
    /// re-materializes). Absolute-column callers go through `cellsAt`, below.
    func cells(forRow row: Int) -> [String]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.rows.count else { return nil }
        return window.rows[idx]
    }

    /// Per-cell display-truncation flags for a data row, PARALLEL to
    /// `cells(forRow:)` (mirrors `RowWindow.truncated`, ARCH req. 13/20) —
    /// same column-RELATIVE shape as `cells(forRow:)`. Rows outside the
    /// window return `nil`, same rule as `cells(forRow:)`.
    func truncated(forRow row: Int) -> [Bool]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.truncated.count else { return nil }
        return window.truncated[idx]
    }

    /// Cells at ABSOLUTE `columns` of data row `row`, mapped through the
    /// CURRENTLY FETCHED column window (`window.firstColumn`): absolute
    /// column `c` reads slot `c - window.firstColumn` of `cells(forRow:)`,
    /// empty-padded for a column outside the fetched range — not yet
    /// materialized, or past the row's width — exactly like a not-yet-loaded
    /// row (ARCH-column-windowing round-2). Shared by the eager, all-visible-
    /// columns dump-grid helpers and the live grid's window-bound helpers
    /// below; they differ only in which absolute columns they ask for.
    private func cellsAt(_ columns: [Int], forRow row: Int) -> [String] {
        guard let full = cells(forRow: row) else { return Array(repeating: "", count: columns.count) }
        let base = window.firstColumn
        return columns.map { c in
            let rel = c - base
            return rel >= 0 && rel < full.count ? full[rel] : ""
        }
    }

    /// Truncation flags at ABSOLUTE `columns` of data row `row` — the
    /// `truncated(forRow:)` analog of `cellsAt`.
    private func truncatedAt(_ columns: [Int], forRow row: Int) -> [Bool] {
        guard let full = truncated(forRow: row) else { return Array(repeating: false, count: columns.count) }
        let base = window.firstColumn
        return columns.map { c in
            let rel = c - base
            return rel >= 0 && rel < full.count ? full[rel] : false
        }
    }

    /// Whether a data row is OVERSIZED (ARCH-huge-row-budget req. 3/7): its
    /// SOURCE extent exceeded the core's per-row window scan cap, so it was
    /// served as a bounded prefix (mirrors `RowWindow.oversized`). `false` for
    /// rows outside the currently materialized window, same rule as
    /// `cells(forRow:)` / `truncated(forRow:)` — the gutter simply shows no
    /// marker until a re-window catches up, exactly like a blank row.
    func rowOversized(forRow row: Int) -> Bool {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.oversized.count else { return false }
        return window.oversized[idx]
    }

    /// Whether a data row's cells are already SERVABLE — the materialized
    /// window has reached it — as opposed to being within the row-count
    /// estimate but past the scan frontier (the case `cells(forRow:)` /
    /// `visibleBodyCells(forRow:)` return `nil` / empty-padded for). The grid
    /// uses this to distinguish "still loading" from a genuinely empty row —
    /// both otherwise render identically empty — and draws a subtle loading
    /// placeholder for the former instead of silently blank cells (PROJECT:
    /// constant feedback, no silent stalls). Same window-membership rule as
    /// `cells(forRow:)`; unrelated to filtering (a filtered window's `cells`
    /// already reflect the filtered view under that same rule).
    func rowLoaded(forRow row: Int) -> Bool {
        cells(forRow: row) != nil
    }

    var displayRowCount: Int {
        Int(min(rowCountInfo.count, UInt64(Int.max)))
    }

    // MARK: - Row-number gutter (fixed leftmost column; 1-based)

    /// Width of the fixed row-number gutter, sized to fit the largest 1-based
    /// row number currently in view (ARCH: "width fits the largest visible
    /// number"). Stable per digit count — it only steps when the visible range
    /// crosses a power-of-ten — and never below a 2-digit floor. Uses tabular
    /// digits so the width is exact.
    func rowNumberColumnWidth() -> CGFloat {
        let maxVisible: Int
        if isFiltered {
            // Original row numbers are non-contiguous under a filter (ARCH
            // criterion 13): size for the largest POSSIBLE original number —
            // the captured document row count — so the gutter width stays
            // stable across a scroll instead of re-deriving it from each
            // visible row's source mapping.
            let documentRows = filterDocumentRows?.count ?? rowCountInfo.count
            maxVisible = Int(min(documentRows, UInt64(Int.max)))
        } else {
            // Clamp to the last data row so scrolling into the overscroll strip
            // (whose filler rows carry no number) never inflates the gutter.
            maxVisible = min(firstVisibleRow + max(lastVisibleCount, 1), max(displayRowCount, 1))
        }
        return Self.rowNumberWidth(digits: Self.rowNumberDigits(forMaxNumber: maxVisible))
    }

    /// The row-number gutter's value for row `row` (ARCH criteria 13/17): the
    /// row's ORIGINAL (unfiltered) data-row number while a filter is active —
    /// forwarded verbatim from the core's `sourceRow`, never recomputed — else
    /// the row's own identity index. `nil` while filtered and the row is not
    /// currently servable (outside the materialized window) — the gutter
    /// leaves such a row blank until a re-window catches up, exactly like its
    /// cells.
    func gutterRow(forRow row: Int) -> UInt64? {
        guard isFiltered else { return UInt64(row) }
        return session?.sourceRow(UInt64(row))
    }

    static func rowNumberDigits(forMaxNumber n: Int) -> Int {
        max(GridMetrics.rowNumberMinDigits, String(max(1, n)).count)
    }

    static func rowNumberWidth(digits: Int) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let sample = String(repeating: "8", count: max(1, digits)) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + GridMetrics.rowNumberHPadding * 2
            + GridMetrics.oversizedMarkerReserve
    }

    // MARK: - Grid view helpers (the EAGER, all-visible-columns dump grid;
    // ARCH-headless-dump / FrameDump. The dump renders small, already-loaded
    // fixtures off the cold-open path, so an O(visible columns) pass here is
    // fine — it is NOT what the live grid draws; see the window-bound
    // counterparts below for that (ARCH-column-windowing).

    /// Frozen widths of the visible columns, in render order — EFFECTIVE
    /// widths (ARCH-select-copy AC5: a manual override wins over the auto
    /// baseline), see `effectiveWidths(for:)`.
    func visibleWidths() -> [CGFloat] {
        effectiveWidths(for: visibleColumns)
    }

    /// Header labels of the visible columns (effective names or generic A/B/C).
    func headerLabels() -> [String] {
        visibleColumns.map { columnLabel($0) }
    }

    /// Visible-column cells for a data row, empty-padded while not yet loaded
    /// (or, on a wide document, not yet in the fetched column range — see
    /// `cellsAt`).
    func visibleBodyCells(forRow row: Int) -> [String] {
        cellsAt(visibleColumns, forRow: row)
    }

    /// Visible-column truncation flags for a data row (ARCH req. 13/20),
    /// false-padded while not yet loaded — same shape as `visibleBodyCells`.
    /// Driven entirely by the core's per-cell flag; never re-measures cells.
    func visibleBodyTruncated(forRow row: Int) -> [Bool] {
        truncatedAt(visibleColumns, forRow: row)
    }

    // MARK: - Horizontal column window (the LIVE grid; ARCH-column-windowing)
    //
    // The window-bound counterparts of the helpers above: every one is O(the
    // horizontal column window), NEVER O(columnCount), so `NativeGridController`
    // can call them on every scroll/materialize tick even on a 100k-column
    // document (the wide_100k_cols cold-open budget, csv-corpus AC5). Each
    // slices `windowColumns()` — itself an O(window) slice of the memoized
    // `visibleColumns` — so none of these ever re-filters `0..<columnCount`.

    /// The current column window's ABSOLUTE column indices, in render order.
    private func windowColumns() -> [Int] {
        let cols = visibleColumns
        guard !cols.isEmpty else { return [] }
        let clamped = columnWindow.range.clamped(to: 0..<cols.count)
        guard !clamped.isEmpty else { return [] }
        return Array(cols[clamped])
    }

    /// Widths of the current column window, in render order — what the live
    /// grid draws (`NativeGridController.widths`); EFFECTIVE widths, see
    /// `effectiveWidths(for:)`.
    func windowWidths() -> [CGFloat] {
        effectiveWidths(for: windowColumns())
    }

    /// `columns`' EFFECTIVE widths (`ColumnSizing.effectiveWidths`, "manual
    /// wins" — ARCH-select-copy AC5): builds a COLUMNS-local `auto`/`manual`
    /// pair so the contract call stays O(columns.count) — a window or the
    /// visible-columns list, never O(columnCount) beyond what the caller
    /// already asked for — then folds them through the contract.
    private func effectiveWidths(for columns: [Int]) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let auto = columns.map { $0 < columnWidths.count ? Double(columnWidths[$0]) : Double(GridMetrics.minColumnWidth) }
        var manual: [Int: Double] = [:]
        if !manualColumnWidths.isEmpty {
            for (i, c) in columns.enumerated() {
                if let w = manualColumnWidths[c] { manual[i] = w }
            }
        }
        return columnSizer.effectiveWidths(auto: auto, manual: manual).map { CGFloat($0) }
    }

    /// Header labels of the current column window, in render order.
    func windowHeaderLabels() -> [String] {
        windowColumns().map { columnLabel($0) }
    }

    /// Header-label truncation flags parallel to `windowHeaderLabels`.
    func windowHeaderTruncated() -> [Bool] {
        windowColumns().map { windowTruncatedLabels.contains($0) }
    }

    /// Absolute column indices of the current column window, in render
    /// order — PARALLEL to `windowWidths()`/`windowHeaderLabels()`: the
    /// click→cell mapping's column half (ARCH-select-copy). Position `i`
    /// here is the SAME absolute column `windowWidths()[i]` is the width of.
    func windowAbsoluteColumns() -> [Int] {
        windowColumns()
    }

    /// Column-window cells for a data row, empty-padded while not yet loaded
    /// — the window-bound analog of `visibleBodyCells`.
    func windowBodyCells(forRow row: Int) -> [String] {
        windowCellPresentations(forRow: row).map(\.text)
    }

    func windowCellPresentations(forRow row: Int) -> [WindowCellPresentation] {
        let columns = windowColumns()
        let raw = cellsAt(columns, forRow: row)
        let truncated = truncatedAt(columns, forRow: row)
        let rowIsOversized = rowOversized(forRow: row)
        let formatter = ColumnDisplayFormatter()
        return columns.enumerated().map { offset, column in
            let source = offset < raw.count ? raw[offset] : ""
            guard !rowIsOversized, !(offset < truncated.count && truncated[offset]),
                  let metadata = windowColumnMetadata[column] else {
                return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
            }
            let settings = userSettings(for: column)
            if let sentinel = settings.nullSentinel, sentinel == Array(source.utf8) {
                return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
            }
            let outcome = formatter.display(raw: source, type: metadata.effective,
                                            options: settings.format, locale: sessionLocale)
            let unavailable: Bool
            if case .formatUnavailable = outcome { unavailable = true } else { unavailable = false }
            return WindowCellPresentation(
                text: outcome.text, formatUnavailable: unavailable,
                conflict: Self.cellConflicts(source, type: metadata.effective, formatter: formatter)
            )
        }
    }

    /// Targeted counterpart used by a direct column-config redraw. It reads
    /// and formats one logical column only, preserving the same raw/truncated/
    /// oversized/null/conflict rules as the vector helper above.
    func windowCellPresentation(forRow row: Int, column: Int) -> WindowCellPresentation {
        let source = cellsAt([column], forRow: row).first ?? ""
        let isTruncated = truncatedAt([column], forRow: row).first ?? false
        guard !rowOversized(forRow: row), !isTruncated,
              let metadata = windowColumnMetadata[column] else {
            return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
        }
        let settings = userSettings(for: column)
        if let sentinel = settings.nullSentinel, sentinel == Array(source.utf8) {
            return WindowCellPresentation(text: source, formatUnavailable: false, conflict: false)
        }
        let formatter = ColumnDisplayFormatter()
        let outcome = formatter.display(raw: source, type: metadata.effective,
                                        options: settings.format, locale: sessionLocale)
        let unavailable: Bool
        if case .formatUnavailable = outcome { unavailable = true } else { unavailable = false }
        return WindowCellPresentation(
            text: outcome.text, formatUnavailable: unavailable,
            conflict: Self.cellConflicts(source, type: metadata.effective, formatter: formatter)
        )
    }

    private static func cellConflicts(_ raw: String, type: ColumnType,
                                      formatter: ColumnDisplayFormatter) -> Bool {
        guard !raw.isEmpty else { return false }
        switch type.kind {
        case .unknown, .unsupported, .text: return false
        case .boolean: return formatter.strictKind(of: raw) != .boolean
        case .integer: return formatter.strictKind(of: raw) != .integer
        case .decimal:
            let kind = formatter.strictKind(of: raw)
            return kind != .integer && kind != .decimal
        case .date: return formatter.strictKind(of: raw) != .date
        case .datetime:
            let expected: ColumnScalarKind = type.datetimeSemantics == .zoned ? .datetimeZoned : .datetimeNaive
            return formatter.strictKind(of: raw) != expected
        }
    }

    func windowColumnAlignments() -> [ColumnTextAlignment] {
        let rules = ColumnAlignmentRules()
        return windowColumns().map { column in
            rules.alignment(for: windowColumnMetadata[column]?.effective.kind ?? .unknown, isConflict: false)
        }
    }

    func columnAlignment(_ column: Int) -> ColumnTextAlignment {
        ColumnAlignmentRules().alignment(
            for: windowColumnMetadata[column]?.effective.kind ?? .unknown,
            isConflict: false
        )
    }

    /// Column-window truncation flags for a data row — the window-bound
    /// analog of `visibleBodyTruncated`.
    func windowBodyTruncated(forRow row: Int) -> [Bool] {
        truncatedAt(windowColumns(), forRow: row)
    }

    /// Sum of every VISIBLE column's width — the document's total horizontal
    /// content extent, independent of the window (drives the live grid's
    /// scrollable table-column width / filler-column count —
    /// `NativeGridController.refreshColumnWidth`). Memoized alongside
    /// `cachedLayoutWidths` (see `refreshLayoutWidthsIfNeeded`); meant to be
    /// read only on a structural change (open, hidden-column toggle, a
    /// width-batch change) via `refreshLayoutMetrics`, never per scroll tick
    /// — though it costs nothing extra even then, once the shared cache is
    /// warm.
    var totalVisibleWidth: CGFloat {
        refreshLayoutWidthsIfNeeded()
        return cachedTotalVisibleWidth
    }

    // MARK: - Selection (ARCH-select-copy AC1) — pure index-space state
    // driven by `Selecting` (`SelectionModel`); the grid's mouse/keyboard/
    // gutter/header event routing (NativeGridController) is the only caller.
    // O(1) in the extent, so Cmd+A on the largest document is free — see
    // `Selecting`'s doc comment.

    /// The document's selectable extent RIGHT NOW: `rowCountInfo.count`
    /// already reports the FILTERED count while a filter is active (the
    /// same domain every other row index in this model uses), so a
    /// selection is naturally scoped to the current view mode with no extra
    /// branching here.
    private func selectionExtent() -> GridExtent {
        GridExtent(rowCount: rowCountInfo.count, columnCount: columnCount)
    }

    /// A plain click.
    func selectCell(row: UInt64, column: Int) {
        selection = selectionModel.select(GridCell(row: row, column: column), in: selectionExtent())
    }

    /// Whether the live selection is exactly this one cell. Kept in the app
    /// layer because the frozen selection algebra intentionally defines only
    /// geometry, while click-again toggling is an input-routing concern.
    func isOnlySelectedCell(_ cell: GridCell) -> Bool {
        selection?.anchor == cell && selection?.active == cell
    }

    func clearSelection() {
        selection = nil
    }

    /// A drag or shift-click: anchor kept, active moves to the clicked cell.
    /// Nothing selected yet: falls back to a plain click (there is no
    /// anchor to extend from).
    func extendSelection(toRow row: UInt64, column: Int) {
        guard let current = selection else { selectCell(row: row, column: column); return }
        selection = selectionModel.extend(current, to: GridCell(row: row, column: column), in: selectionExtent())
    }

    /// Arrow / shift-arrow: `extending` false collapses + steps (arrow);
    /// true keeps the anchor and steps only the active corner (shift-arrow).
    /// A no-op with nothing selected yet — there is no cell to step from.
    func moveSelection(_ direction: SelectionDirection, extending: Bool) {
        guard let current = selection else { return }
        let extent = selectionExtent()
        selection = extending ? selectionModel.extend(current, direction, in: extent)
                               : selectionModel.move(current, direction, in: extent)
    }

    /// A gutter click: the whole (capped) row.
    func selectWholeRow(_ row: UInt64) {
        selection = selectionModel.wholeRow(row, in: selectionExtent())
    }

    /// Plain gutter clicks toggle only an identical whole-row selection.
    func toggleWholeRow(_ row: UInt64) {
        let candidate = selectionModel.wholeRow(row, in: selectionExtent())
        selection = selection == candidate ? nil : candidate
    }

    /// A header click: the whole (capped) column.
    func selectWholeColumn(_ column: Int) {
        selection = selectionModel.wholeColumn(column, in: selectionExtent())
    }

    /// Plain header clicks toggle only an identical whole-column selection.
    func toggleWholeColumn(_ column: Int) {
        let candidate = selectionModel.wholeColumn(column, in: selectionExtent())
        selection = selection == candidate ? nil : candidate
    }

    /// A shift-click on the gutter (ARCH: whole-row EXTEND is "composed by
    /// the frontend from extend(_:to:in:)"): keep the anchor, extend to the
    /// clicked row spanning every column. Nothing selected yet: falls back
    /// to a plain whole-row select.
    func extendSelectionToWholeRow(_ row: UInt64) {
        guard let current = selection else { selectWholeRow(row); return }
        let extent = selectionExtent()
        guard !extent.isEmpty else { return }
        selection = selectionModel.extend(current, to: GridCell(row: row, column: extent.lastColumn), in: extent)
    }

    /// A shift-click on the header — the whole-column analog of
    /// `extendSelectionToWholeRow`.
    func extendSelectionToWholeColumn(_ column: Int) {
        guard let current = selection else { selectWholeColumn(column); return }
        let extent = selectionExtent()
        guard !extent.isEmpty else { return }
        selection = selectionModel.extend(current, to: GridCell(row: extent.lastRow, column: column), in: extent)
    }

    /// Cmd+A: the capped extent from the origin — O(1) for any document size.
    func selectAll() {
        selection = selectionModel.selectAll(in: selectionExtent())
    }

    /// Per-column selection-overlay state for a data row over the current
    /// column WINDOW (ARCH AC1), O(window) — the selection analog of
    /// `windowCellHighlights`; `SheetRowView.draw` reads this directly (no
    /// per-cell model call on the draw path).
    func windowSelectionMarks(forRow row: Int) -> [SelectionMark] {
        guard let rect = selection?.rect else { return [] }
        let cols = windowColumns()
        guard !cols.isEmpty else { return [] }
        let r = UInt64(row)
        return cols.map { column in
            guard rect.contains(GridCell(row: r, column: column)) else { return .none }
            return SelectionMark(isSelected: true, borderTop: r == rect.top, borderBottom: r == rect.bottom,
                                  borderLeft: column == rect.left, borderRight: column == rect.right)
        }
    }

    // MARK: - Copy (ARCH-select-copy AC2-4; round 2 findings 2/3)

    /// ⌘C: snapshot the LIVE selection rect and build the TSV payload OFF
    /// the main thread (`Task.detached` — the builder/budget/rect/fetch
    /// closure are all `Sendable`, AC4) via a fetch closure over
    /// `session.copyCell` (poll/control lane — lock-free, so the UI keeps
    /// scrolling live while a big copy runs), then write the pasteboard and
    /// show a brief notice back on the main actor — the SAME `await
    /// self?...` actor hand-off `startPolling` already uses below, no
    /// explicit `DispatchQueue`/`MainActor.run` needed. A no-op with nothing
    /// selected or no open session. A copy already running is CANCELLED
    /// first (`cancelCopy`) rather than ignored (finding 2): the new
    /// selection snapshot supersedes the old one, so racing two pasteboard
    /// writes would only ever want the LATEST to win — cancelling makes
    /// that the only possible outcome instead of blocking on a stale one.
    ///
    /// Before building, gives the background index a bounded chance to
    /// advance the scan frontier to the selection's bottom row
    /// (`advanceFrontier`, finding 3): without this, a selection made soon
    /// after opening a large file — before AUTO indexing has caught up —
    /// copies only up to the frontier and reports `.stoppedAtFrontier`
    /// (`CopyBuilding.build` rule 6) even though the rest of the rows exist
    /// and would be servable moments later.
    ///
    /// PERFORMANCE NOTE (measured, not a bug): `ls_cell_copy` re-locates its
    /// row from the nearest index checkpoint (every 2048 rows, backend
    /// `checkpoint_interval`) on EVERY call, independently — unlike the
    /// paged `setWindow`/`ls_cell` the scrolling grid uses (which amortizes
    /// that cost across a whole page), so a copy spanning many rows AND
    /// columns can take real, human-noticeable time (a 100k-row x 3-column
    /// selection measured ~80 s off-main). This is why the ARCH calls for
    /// the "Copying…" affordance below rather than assuming near-instant
    /// completion — and why that affordance now carries a Cancel escape
    /// hatch (finding 2) for exactly that long tail; deliberately NOT
    /// "fixed" by routing this through `setWindow` instead — that would
    /// evict/thrash the SAME live window the on-screen grid is scrolling
    /// through, exactly the interference `ls_cell_copy` (window-INDEPENDENT)
    /// exists to avoid (AC4: "the UI keeps scrolling... undisturbed").
    /// Main-thread responsiveness is unaffected either way (verified:
    /// `SelectCopyProbe`'s heartbeat stays under budget for the whole
    /// build) — only wall-clock completion time is.
    func copySelection() {
        guard let session, let rect = selection?.rect else { return }
        cancelCopy()   // supersede any copy already running (see doc above)
        copyInFlight = true
        // ARCH-stream-copy AC8 ("subtle progress after ~500 ms ... with the
        // existing cancel ... gone on completion/cancel; a sub-threshold copy
        // shows nothing"): the SAME shared gate every long op in this model
        // drives (see `progressGate`/`copyProgress`). A real `ContinuousClock`
        // reading taken now is the copy's start; the driver feeds the real
        // elapsed since then into the gate at the threshold tick, so the
        // ~500 ms band is the ONE the whole app shares, not a private magic
        // number (this replaces a prior local 300 ms constant).
        let startedAt = progressClock.now
        copyStartedAt = startedAt
        copyGeneration += 1
        let myGeneration = copyGeneration
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.progressGate.threshold)
            // `copyInFlight` alone is a SHARED flag (true for ANY in-flight
            // copy); the generation check is what tells this stale task
            // apart from a copy that superseded it in the meantime (a rapid
            // ⌘C before this one crossed the threshold) — without it this
            // task would reveal progress for the NEW copy, computed from
            // THIS (older) copy's elapsed.
            guard !Task.isCancelled, self.copyInFlight, self.copyGeneration == myGeneration else { return }
            let elapsed = self.progressClock.now - startedAt
            let indication = self.progressGate.indication(for: .running(elapsed: elapsed, cancellable: true))
            self.copyProgress = indication
            if indication.isVisible { self.copyNotice = "Copying…" }
        }
        let builder = copyBuilder
        let budget = CopyBudget.standard
        let fetch: CopyCellFetch = { row, column in session.copyCell(row: row, column: column, maxBytes: budget.perCellMaxBytes) }
        copyTask = Task.detached { [weak self] in
            await Self.advanceFrontier(session: session, to: rect.bottom)
            guard !Task.isCancelled else { return }
            let report = builder.build(rect, budget: budget, fetch: fetch)
            guard !Task.isCancelled else { return }
            await self?.completeCopy(report)
        }
    }

    /// How long `advanceFrontier` waits for AUTO indexing to reach the
    /// selection's bottom row before giving up and building anyway — bounded
    /// so a copy can never hang on an arbitrarily slow scan. One poll every
    /// `frontierPollInterval`, up to `frontierPollMaxTicks` times.
    private static let frontierPollInterval: Duration = .milliseconds(50)
    private static let frontierPollMaxTicks = 40   // ~2 s total

    /// Pre-advances the core's scan frontier toward `target` (ARCH-select-
    /// copy round 2, finding 3) by reusing the SAME jump-scan primitives a
    /// real Jump-to-row uses (`DocumentSession.startJump`/`jumpStatus`) — but
    /// deliberately bypasses `beginJump`/`jumpFlow`/the viewport: `startJump`
    /// is a plain core call independent of this view-model's OWN jump-
    /// presentation state machine, and `jumpStatus` is a side-effect-free
    /// poll safe to call from any thread (`DocumentSession` is `Sendable`) —
    /// so this is invisible to the user (no jump popup, no scroll) while
    /// still unlocking rows for the copy that follows. Returns as soon as
    /// the target is behind the frontier (`startJump`'s contract: already
    /// `.done` when it returns if so — the common case costs one extra pair
    /// of non-blocking calls and nothing else) or after
    /// `frontierPollMaxTicks` polls, whichever comes first; cancellable
    /// (checked every tick — `cancelCopy` relies on this for a prompt
    /// response while a copy is waiting here, its most likely spot). Shares
    /// the core's single scan slot with a real jump/find — an existing,
    /// accepted trade-off (see `DocumentSession.startJump`'s doc comment).
    private static func advanceFrontier(session: any DocumentSession, to target: UInt64) async {
        session.startJump(to: target)
        if case .done = session.jumpStatus() { return }
        for _ in 0..<frontierPollMaxTicks {
            if Task.isCancelled { return }
            try? await Task.sleep(for: frontierPollInterval)
            if case .done = session.jumpStatus() { return }
        }
    }

    private func completeCopy(_ report: CopyReport) {
        // The build (or its wait) may have run to completion in the
        // background AFTER `cancelCopy` already cleared this copy's state
        // (best-effort cancellation — see that method's doc comment): never
        // let a superseded/cancelled result reach the pasteboard or notice.
        guard !Task.isCancelled else { return }
        copyTask = nil
        copyInFlight = false
        copyProgress = .hidden   // ARCH-stream-copy AC8: gone on completion
        copyStartedAt = nil
        Self.writeToPasteboard(report.text)
        copyNoticeTask?.cancel()
        copyNotice = Self.noticeText(for: report)
        copyNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.copyNotice = nil
        }
    }

    /// Cancels an in-flight copy (Esc, the "Copying…" notice's Cancel
    /// button, or a fresh ⌘C superseding it — ARCH-select-copy round 2,
    /// finding 2). Best-effort over the BUILD itself: `TSVCopyBuilder.build`
    /// is a tight synchronous loop with no cancellation checkpoint of its
    /// own (reviewer-verified-correct pure logic, out of scope for this
    /// round's fixes), so an already-running fetch loop keeps running to
    /// completion in the background rather than stopping mid-cell.
    /// `advanceFrontier`'s wait — the common
    /// place a cancel actually lands, since on a lagging index it dominates
    /// the latency before the build even starts — DOES poll in a cancellable
    /// loop and stops within one tick. Either way, what this method
    /// guarantees unconditionally: the UI-visible state clears immediately
    /// (no perpetual "Copying…"), and any result the orphaned task
    /// eventually produces is silently dropped (`completeCopy` checks
    /// `Task.isCancelled` before touching the pasteboard or the notice).
    func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        copyNoticeTask?.cancel()
        copyNoticeTask = nil
        copyInFlight = false
        copyProgress = .hidden   // ARCH-stream-copy AC8: gone on cancel
        copyStartedAt = nil
        copyNotice = nil
    }

    /// A TSV type + a plain-string type (ARCH AC3: "sets both a TSV type and
    /// a plain-string type on NSPasteboard"); `.tabularText` is the standard
    /// tab-delimited spreadsheet clipboard type Excel/Numbers both read.
    private static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .tabularText)
        pasteboard.setString(text, forType: .string)
    }

    /// The honest "what was copied" notice (ARCH AC2). Sentence case, user
    /// vocabulary — matches `FindCopy.status`'s style.
    private static func noticeText(for report: CopyReport) -> String {
        switch report.outcome {
        case .complete:
            return report.rowCount <= 1 ? "Copied" : "Copied \(report.rowCount) rows"
        case .stoppedAtBudget, .stoppedAtCellCap:
            let mb = max(1, report.byteCount / (1024 * 1024))
            return "Copied the first ~\(mb) MB — \(report.rowCount) rows"
        case .stoppedAtFrontier:
            return "Copied \(report.rowCount) row\(report.rowCount == 1 ? "" : "s") so far — still loading the rest"
        }
    }

    // MARK: - Column resize + auto-fit (ARCH-select-copy AC5)

    /// The width actually drawn for absolute `column`: the manual override
    /// if present, else the auto baseline — `ColumnSizing`'s "manual wins"
    /// rule, O(1) (a single dictionary lookup).
    private func effectiveWidth(_ column: Int) -> CGFloat {
        if let manual = manualColumnWidths[column] { return CGFloat(manual) }
        return column < columnWidths.count ? columnWidths[column] : GridMetrics.minColumnWidth
    }

    /// Drag-resize: `windowIndex` is a position in the CURRENT column window
    /// (`windowWidths()`'s index space — exactly what the grid hit-tests the
    /// trailing hairline against), so resolving the absolute column and its
    /// cache slot is O(1) — no all-visible-columns search ("ride the
    /// column-window offsets"). Sets an explicit manual width (floored at
    /// `minColumnWidth`) that STICKS: `windowWidths()`/`totalVisibleWidth`
    /// return it regardless of what auto-grow measures underneath from here
    /// on (`growColumnWidthsToFitWindow` skips it).
    func resizeWindowColumn(_ windowIndex: Int, toWidth width: Double) {
        let cols = windowColumns()
        guard cols.indices.contains(windowIndex) else { return }
        let column = cols[windowIndex]
        let previous = effectiveWidth(column)
        manualColumnWidths = columnSizer.resized(
            manual: manualColumnWidths, column: column, to: width, minWidth: Double(GridMetrics.minColumnWidth)
        )
        var settings = userSettings(for: column)
        settings.manualWidth = manualColumnWidths[column]
        storeColumnSettings(settings, column: column)
        syncEffectiveWidthCache(column: column, windowIndex: windowIndex, previous: previous)
    }

    /// Double-click auto-fit: clears the manual override AND resets the
    /// column's AUTO baseline to the exact fit over its VISIBLE window
    /// content (O(visible rows), never O(rows)) — so it is back in auto
    /// mode at the fitted width and can grow again as new content scrolls
    /// in (`ColumnSizing.autoFit`'s contract).
    func autoFitWindowColumn(_ windowIndex: Int) {
        let cols = windowColumns()
        guard cols.indices.contains(windowIndex) else { return }
        let column = cols[windowIndex]
        let previous = effectiveWidth(column)
        let fitted = columnSizer.autoFit(
            contentWidths: measuredContentWidths(forColumn: column),
            minWidth: Double(GridMetrics.minColumnWidth), maxWidth: Double(GridMetrics.maxColumnWidth)
        )
        manualColumnWidths = columnSizer.cleared(manual: manualColumnWidths, column: column)
        if column < columnWidths.count { columnWidths[column] = CGFloat(fitted) }
        var settings = userSettings(for: column)
        settings.manualWidth = nil
        storeColumnSettings(settings, column: column)
        syncEffectiveWidthCache(column: column, windowIndex: windowIndex, previous: previous)
    }

    /// O(1) sync of the visible-position caches (`cachedLayoutWidths`/
    /// `cachedTotalVisibleWidth` — otherwise rebuilt only on a STRUCTURAL
    /// change, see `refreshLayoutWidthsIfNeeded`) after ONE column's
    /// effective width changed, so a resize drag never pays that O(visible
    /// columns) rebuild (ARCH AC5: "O(1) per resize... no all-column
    /// relayout"). `windowIndex` maps to visible-position `columnWindow.
    /// first + windowIndex` with no search, by construction of
    /// `windowColumns()`. A no-op while the caches are already stale (a
    /// pending full rebuild picks up the fresh value on its own).
    private func syncEffectiveWidthCache(column: Int, windowIndex: Int, previous: CGFloat) {
        guard !layoutWidthsStale else { return }
        let updated = effectiveWidth(column)
        guard updated != previous else { return }
        let position = columnWindow.first + windowIndex
        if cachedLayoutWidths.indices.contains(position) {
            cachedLayoutWidths[position] = Double(updated)
        }
        cachedTotalVisibleWidth += updated - previous
    }

    /// The measured pixel widths — header + each VISIBLE row's cell,
    /// O(visible rows) — for absolute `column` (`ColumnSizing.autoFit`'s
    /// `contentWidths` input; padding pre-added per the contract doc).
    /// Mirrors `growColumnWidthsToFitWindow`'s own measurement (same fonts/
    /// padding/oversized-row and truncated-cell exclusions) so a double-click
    /// and the passive auto-grow agree on what "fits."
    private func measuredContentWidths(forColumn column: Int) -> [Double] {
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let padding = GridMetrics.cellHPadding * 2
        var widths = [Double(Self.textWidth(columnLabel(column), headFont) + padding)]

        let start = Int(window.firstRow)
        let lo = max(start, firstVisibleRow)
        let hi = min(start + window.rows.count, firstVisibleRow + max(lastVisibleCount, 1))
        guard lo < hi else { return widths }
        let rel = column - window.firstColumn
        guard rel >= 0 else { return widths }
        let visibleOffset = windowColumns().firstIndex(of: column)

        for r in lo..<hi {
            let idx = r - start
            if idx < window.oversized.count, window.oversized[idx] { continue }
            let row = window.rows[idx]
            guard rel < row.count else { continue }
            if idx < window.truncated.count, rel < window.truncated[idx].count, window.truncated[idx][rel] { continue }
            let displayed: String
            if let visibleOffset {
                let presentation = windowCellPresentations(forRow: r)
                displayed = visibleOffset < presentation.count ? presentation[visibleOffset].text : row[rel]
            } else {
                displayed = row[rel]
            }
            widths.append(Double(Self.textWidth(displayed, bodyFont) + padding))
        }
        return widths
    }

    // MARK: - Column visibility (pure model; grid reflows)

    /// The ascending indices of the non-hidden columns, in render order —
    /// `visibilityManager.visibleColumns(visibility)`, memoized (see
    /// `cachedVisibleColumns`). Semantics UNCHANGED (find/filter column
    /// scoping keeps reading exactly this); only the cost of a read changed.
    var visibleColumns: [Int] { cachedVisibleColumns }

    func canHide(_ column: Int) -> Bool { visibilityManager.canHide(visibility, column: column) }

    func toggleColumn(_ column: Int) {
        setVisibility(visibilityManager.toggling(visibility, column: column))
        var settings = columnUserSettings[column] ?? .default
        settings.hidden = visibility.isHidden(column)
        storeColumnSettings(settings, column: column)
    }

    func showAllColumns() {
        setVisibility(visibilityManager.allVisible(columnCount: columnCount))
        for column in Array(columnUserSettings.keys) {
            var settings = columnUserSettings[column] ?? .default
            settings.hidden = false
            storeColumnSettings(settings, column: column)
        }
        columnPresentationRevision += 1
    }

    func beginSettings(selecting target: Int? = nil) {
        let reducer = SettingsLifecycleReducer()
        if !settingsOpen {
            settingsLifecycle = reducer.opened(
                columnCount: columnCount, restoring: settingsLifecycle.selection
            )
            settingsDiscoveryRows = []
        }
        settingsOpen = true
        if let target {
            let targetInCurrentRows = ColumnDiscovery().mode(columnCount: columnCount) == .fullList
                || settingsDiscoveryRows.contains(target)
            settingsLifecycle = reducer.headerAction(
                settingsLifecycle, target: target, columnCount: columnCount,
                targetInCurrentRows: targetInCurrentRows
            )
        }
        setPanelSelection(settingsLifecycle.selection)
    }

    func endSettings() {
        guard settingsOpen else { return }
        settingsLifecycle = SettingsLifecycleReducer().closed(settingsLifecycle)
        settingsDiscoveryRows = []
        settingsOpen = false
        closeColumnPanel()
    }

    func setSettingsQuery(_ query: String) {
        guard settingsLifecycle.query != query else { return }
        settingsLifecycle.query = query
        settingsDiscoveryRows = []
    }

    func selectSettingsColumn(_ column: Int?) {
        settingsLifecycle = SettingsLifecycleReducer().columnSelected(
            settingsLifecycle, column: column
        )
        setPanelSelection(column)
    }

    func setSettingsDisclosure(_ disclosure: SettingsDisclosure, expanded: Bool) {
        settingsLifecycle = SettingsLifecycleReducer().disclosureSet(
            settingsLifecycle, disclosure, expanded: expanded
        )
    }

    func setSettingsDiscoveryRows(_ rows: [Int]) {
        settingsDiscoveryRows = Array(rows.prefix(columnDiscoveryResultMax))
    }

    var settingsRequestIDCount: Int {
        var ids = Set(panelInferenceIDs)
        if let panelSelectedColumn { ids.insert(panelSelectedColumn) }
        return ids.count
    }

    var settingsDiscoveryRowCount: Int { settingsDiscoveryRows.count }

    func columnPanelCore() -> CoreDocumentSession? { session as? CoreDocumentSession }

    func userSettings(for column: Int) -> ColumnUserSettings {
        columnUserSettings[column] ?? .default
    }

    func panelLabel(for column: Int) -> PanelColumnLabel {
        panelLabels[column] ?? PanelColumnLabel(text: columnLabel(column),
                                                truncated: windowTruncatedLabels.contains(column))
    }

    func metadata(for column: Int) -> ColumnMetadata? {
        panelMetadata[column] ?? windowColumnMetadata[column]
    }

    func panelColumnHasFormatUnavailable(_ column: Int) -> Bool {
        let columns = windowColumns()
        guard let offset = columns.firstIndex(of: column) else { return false }
        let start = Int(window.firstRow)
        for row in start..<(start + window.rows.count) {
            let presentations = windowCellPresentations(forRow: row)
            if offset < presentations.count, presentations[offset].formatUnavailable { return true }
        }
        return false
    }

    func columnWidth(_ column: Int) -> Double { Double(effectiveWidth(column)) }

    func setPanelColumnWidth(_ width: Double, column: Int) {
        guard column >= 0, column < columnCount else { return }
        manualColumnWidths[column] = max(width, Double(GridMetrics.minColumnWidth))
        var settings = userSettings(for: column)
        settings.manualWidth = manualColumnWidths[column]
        storeColumnSettings(settings, column: column)
        markLayoutWidthsStale()
        columnWidthRevision += 1
        columnPanelRevision += 1
    }

    func autoFitPanelColumn(_ column: Int) {
        guard column >= 0, column < columnCount else { return }
        let fitted = columnSizer.autoFit(
            contentWidths: measuredContentWidths(forColumn: column),
            minWidth: Double(GridMetrics.minColumnWidth), maxWidth: Double(GridMetrics.maxColumnWidth)
        )
        manualColumnWidths = columnSizer.cleared(manual: manualColumnWidths, column: column)
        columnWidths[column] = CGFloat(fitted)
        var settings = userSettings(for: column)
        settings.manualWidth = nil
        storeColumnSettings(settings, column: column)
        markLayoutWidthsStale()
        columnWidthRevision += 1
        columnPanelRevision += 1
    }

    func setColumnOverride(_ type: ColumnType?, column: Int) {
        guard let id = UInt32(exactly: column), let core = session as? CoreDocumentSession,
              core.setColumnOverride(type, column: id) else { return }
        var settings = userSettings(for: column)
        settings.overrideType = type
        storeColumnSettings(settings, column: column)
        refreshAfterColumnConfiguration(column, remeasure: true)
    }

    func setColumnNullSentinel(_ sentinel: String?, column: Int) {
        let bytes = sentinel.map { Array($0.utf8) }
        guard bytes?.count ?? 0 <= 256, let id = UInt32(exactly: column),
              let core = session as? CoreDocumentSession,
              core.setColumnNullSentinel(bytes, column: id) else { return }
        var settings = userSettings(for: column)
        settings.nullSentinel = bytes
        storeColumnSettings(settings, column: column)
        refreshAfterColumnConfiguration(column, remeasure: true)
    }

    func setColumnFormat(_ format: ColumnFormatOptions, column: Int) {
        var settings = userSettings(for: column)
        settings.format = format
        storeColumnSettings(settings, column: column)
        refreshAfterColumnConfiguration(column, remeasure: true)
    }

    private func refreshAfterColumnConfiguration(_ column: Int, remeasure: Bool) {
        if let id = UInt32(exactly: column), let core = session as? CoreDocumentSession {
            if let metadata = core.columnMetadata([id]).first {
                if windowColumnMetadata[column] != nil { windowColumnMetadata[column] = metadata }
                if panelMetadata[column] != nil { panelMetadata[column] = metadata }
            }
            requestCoordinatedInference(core)
        }
        if remeasure { remeasureConfiguredColumn(column) }
        requestColumnConfigurationRedraw([column])
        startPolling()
    }

    /// Bounded revision log for targeted logical-column redraws. A consumer
    /// that falls more than 32 batches behind receives `nil` and must perform
    /// a conservative global refresh; the normal direct-edit path carries one
    /// column from the inspector to the grid without an all-window revision.
    private func requestColumnConfigurationRedraw(_ columns: Set<Int>) {
        guard !columns.isEmpty else { return }
        columnConfigurationRevision += 1
        columnConfigurationEvents.append(ColumnConfigurationEvent(
            revision: columnConfigurationRevision, columns: columns
        ))
        if columnConfigurationEvents.count > 32 {
            columnConfigurationEvents.removeFirst(columnConfigurationEvents.count - 32)
        }
    }

    func columnConfigurationChanges(after revision: Int) -> (revision: Int, columns: Set<Int>?) {
        guard revision != columnConfigurationRevision else {
            return (columnConfigurationRevision, [])
        }
        guard let first = columnConfigurationEvents.first,
              revision >= first.revision - 1 else {
            return (columnConfigurationRevision, nil)
        }
        var columns = Set<Int>()
        for event in columnConfigurationEvents where event.revision > revision {
            columns.formUnion(event.columns)
        }
        return (columnConfigurationRevision, columns)
    }

    private func remeasureConfiguredColumn(_ column: Int) {
        guard manualColumnWidths[column] == nil, column >= 0, column < columnWidths.count else { return }
        let candidate = measuredContentWidths(forColumn: column).max() ?? Double(columnWidths[column])
        let grown = min(max(CGFloat(candidate), columnWidths[column]), GridMetrics.maxColumnWidth)
        if grown > columnWidths[column] {
            columnWidths[column] = grown
            markLayoutWidthsStale()
            columnWidthRevision += 1
        }
    }

    private func storeColumnSettings(_ settings: ColumnUserSettings, column: Int) {
        if settings.isDefault { columnUserSettings.removeValue(forKey: column) }
        else { columnUserSettings[column] = settings }
    }

    /// Assigns `visibility` and its memoized `visibleColumns` in lockstep —
    /// the ONLY place `visibility` is set, so the cache can never drift from
    /// it (ARCH-column-windowing).
    private func setVisibility(_ newValue: ColumnVisibility) {
        visibility = newValue
        cachedVisibleColumns = visibilityManager.visibleColumns(newValue)
        markLayoutWidthsStale()   // the render-order widths depend on visibleColumns too
    }

    /// The label for a column (effective header name, else generic A/B/C…),
    /// used by the grid header and the Settings checkboxes.
    func columnLabel(_ column: Int) -> String {
        if let label = windowColumnLabels[column], !label.isEmpty { return label }
        if let headerCells, column < headerCells.count, !headerCells[column].isEmpty {
            return headerCells[column]
        }
        return GenericColumnName.name(at: column)
    }

    // MARK: - Jump-to-row

    /// Parse + start a jump from the 1-based field text. Returns false — with a
    /// rejection (field blink + shake, no viewport move) — when the input is not
    /// a valid 1-based row number, OR when the total is already EXACT and the
    /// target is past the last row (upfront validation, no scan). When the total
    /// is still estimated, an out-of-range target can only be discovered by
    /// scanning to EOF; that rejection happens in `foldJump` (ARCH error case,
    /// amended 2026-07-06 — reject, don't clamp).
    @discardableResult
    func submitJump(_ text: String) -> Bool {
        guard let target = jumpControl.parseTarget(text) else {
            rejectJump(restoreTo: nil, scanned: false)   // empty / "0" / non-digit / > UInt64.max
            return false
        }
        // (a) Total exact: valid 0-based rows are 0..<count; anything at/beyond
        // count is rejected immediately, no scan. IDENTITY VIEW ONLY: under a
        // filter `target` is an ORIGINAL row number (ARCH-filtered-views req.
        // 7/12) while `rowCountInfo` reports the filtered m — not the same
        // domain — and the filtered jump never rejects (it clamps to the last
        // match instead), so this upfront check does not apply while filtered.
        if !isFiltered, rowCountInfo.isExact, target >= rowCountInfo.count {
            rejectJump(restoreTo: nil, scanned: false)
            return false
        }
        beginJump(to: target)
        return true
    }

    /// Reject the current jump: keep the field open (re-armed for correction),
    /// restore the viewport to `restoreTo` if a scan had started, and pulse the
    /// rejection nonce so the overlay blinks/shakes the field. The core is left
    /// alone — its frontier gains (from any scan) are kept.
    private func rejectJump(restoreTo: UInt64?, scanned: Bool) {
        setJumpFlow(.idle)
        if let restoreTo { pendingScrollRow = restoreTo }
        jumpFieldActive = true
        jumpRejections += 1
        if JumpProbe.active { JumpProbe.rejected(model: self, scanned: scanned, restoredTo: restoreTo) }
    }

    func beginJump(to target: UInt64) {
        guard let session else { return }
        setJumpFlow(jumpControl.begin(target: target, preJumpFirstRow: UInt64(firstVisibleRow)))
        session.startJump(to: target)
        // Behind-frontier targets complete before startJump returns; fold the
        // immediate status so a tiny/loaded jump lands without a poll tick.
        foldJump(session.jumpStatus())
        startPolling()
    }

    func cancelJump() {
        session?.cancelJump()
        let next = jumpControl.cancelled(jumpFlow)
        if case let .cancelled(restore) = next { pendingScrollRow = restore }
        setJumpFlow(next)
    }

    /// The ONLY place `jumpFlow` is assigned (ARCH-stream-copy AC9 "just
    /// wiring"): starts/clears `jumpScanStartedAt` — the real clock reading
    /// `jumpProgressIndication` measures elapsed from — exactly on the
    /// idle/landed/cancelled <-> scanning transition, so every call site
    /// above gets this for free instead of repeating it.
    private func setJumpFlow(_ next: JumpFlow) {
        if case .scanning = next {
            if case .scanning = jumpFlow {} else { jumpScanStartedAt = progressClock.now }
        } else {
            jumpScanStartedAt = nil
        }
        jumpFlow = next
    }

    /// JUMP-scan's live delayed-progress indication (AC9 "just wiring"): the
    /// SAME gate copy uses (`progressGate`), fed the real elapsed since
    /// scanning began — hidden while idle/landed/cancelled, or still under
    /// the shared threshold; visible WITH cancel once past it (a jump always
    /// carries Task/Esc/Cancel — see `cancelJump`). `JumpControlView` reads
    /// this to decide when its progress bar surfaces (OverlayView.swift).
    var jumpProgressIndication: ProgressIndication {
        guard case .scanning = jumpFlow, let startedAt = jumpScanStartedAt else {
            return progressGate.indication(for: .settled)
        }
        return progressGate.indication(for: .running(elapsed: progressClock.now - startedAt, cancellable: true))
    }

    private func foldJump(_ status: JumpStatus) {
        let previous = jumpFlow
        let next = jumpControl.resolve(jumpFlow, with: status)
        if case let .scanning(_, _, progress) = next, JumpProbe.active {
            JumpProbe.noteProgress(progress)
        }
        if case let .landed(row) = next, previous != next {
            // App-layer interpretation of the core's (frozen) clamp: if the scan
            // ended SHORT of the requested target, the target was past the last
            // row — reject and restore the pre-jump viewport, rather than land on
            // the clamped last row (ARCH error case, amended 2026-07-06). The
            // frozen JumpControl.resolve() is unchanged — it still says .landed;
            // the reject decision lives here, above it. IDENTITY VIEW ONLY:
            // under a filter `row` is a FILTERED index and `target` an
            // ORIGINAL row number (not comparable), and the filtered jump
            // never rejects — it clamps to the last match instead
            // (ARCH-filtered-views criterion 12).
            if !isFiltered, case let .scanning(target, preJumpFirstRow, _) = previous, row < target {
                rejectJump(restoreTo: preJumpFirstRow, scanned: true)   // sets jumpFlow = .idle
                return
            }
            setJumpFlow(next)        // mark landed FIRST so a later poll doesn't re-fire
            landOn(row)
            return
        }
        setJumpFlow(next)
    }

    /// A completed jump lands here: page the core window to the target BEFORE
    /// the viewport scrolls, so the rows are already materialized when it
    /// arrives (the virtual band anchors on the landed row) and a headless
    /// arrival dump shows the target row immediately. Then ask the grid to
    /// scroll the landed row into view.
    private func landOn(_ row: UInt64) {
        landViewport(on: row)
        if JumpProbe.active { JumpProbe.arrived(model: self, landed: row) }
    }

    /// Page the window to `row` and hand the grid the row to scroll into view
    /// — the shared landing mechanics behind a jump landing, a search landing,
    /// and a filter apply/clear (ARCH-filtered-views criterion 13): materialize
    /// a fresh window centered on `row`, then set `pendingScrollRow` (consumed
    /// once by the grid).
    private func landViewport(on row: UInt64) {
        firstVisibleRow = Int(min(row, UInt64(Int.max)))
        materialize(start: row, count: GridMetrics.scrollBufferRows * 2)
        pendingScrollRow = row
        viewportLandingHandler?(row)
    }

    // MARK: - Find (search)

    /// Enter in the Find field: while a filter is active the field edits the
    /// FILTER, so re-apply the (edited) predicate as the filter; otherwise run
    /// a normal search.
    func submitFindField() {
        if isFiltered { applyFindAsFilter() } else { submitFind() }
    }

    /// Submit the current draft (Enter): compose + start the search, then
    /// navigate to the first match in the FILE. A rejected compose (ordering
    /// predicate with a non-numeric value, or an out-of-range column) blinks +
    /// shakes the value field; the empty text query is silently ignored.
    func submitFind() {
        switch findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
        case .ignored:
            break
        case .rejected:
            findRejections += 1
            if FindProbe.active { FindProbe.rejected(model: self) }
        case let .run(request):
            // Enter on the SAME active search advances to the next match (ARCH
            // req. 7: "Enter runs the search … then Enter/⌘G = next"). A changed
            // query/predicate starts a fresh search.
            if findSession.display.request == request {
                stepFind(.forward)
                return
            }
            guard let session, session.startSearch(request) else {
                // The composer already validated; the real core accepts. (The
                // seed core rejects every start, so find stays inert until the
                // core lands — surfaced as a rejection here.)
                findRejections += 1
                if FindProbe.active { FindProbe.rejected(model: self) }
                return
            }
            cancelWrapNav()
            findSession = findControl.began(findSession, running: request)
            searchNavDirection = .forward
            session.navigateSearch(.fromTop)          // "first match in the file"
            foldSearch(session.searchStatus())        // fold the (possibly instant) result
            startPolling()
        }
    }

    /// Drive the real submit path from the verification hook (LESSSHEET_FIND):
    /// open the field, set a Text-mode query, and submit — identical to typing
    /// the query + Enter through the popup.
    func submitFindQuery(_ query: String) {
        openFindField()
        findSession.draft.mode = .text
        findSession.draft.text = query
        submitFind()
    }

    /// ⌘G / ⇧⌘G: navigate to the next / previous match (relative to the current
    /// landing, else the viewport). No-op when no search is active.
    func stepFind(_ direction: SearchDirection) {
        guard let session,
              let nav = findControl.step(findSession, direction, viewportRow: UInt64(firstVisibleRow))
        else { return }
        cancelWrapNav()               // an explicit step supersedes a pending auto-wrap
        searchNavDirection = direction
        session.navigateSearch(nav)
        foldSearch(session.searchStatus())
        startPolling()
    }

    /// The scan-cancel affordance: stop the match-scan, keep what's known so
    /// far, state "Stopped".
    func cancelFind() {
        cancelWrapNav()
        session?.cancelSearch()
        findSession = findControl.stopped(findSession)
    }

    /// Esc / close: clear results + highlights (request nil), retain the typed
    /// query, and cancel the core search.
    func closeFind() {
        cancelWrapNav()
        session?.cancelSearch()
        findSession = findControl.closed(findSession)
        findFieldActive = false
        searchNavDirection = .forward
    }

    /// Fold one search poll into the display; when a wrap notice appears, hold
    /// it on screen for a readable beat and THEN issue the follow-up navigation,
    /// and bring a fresh landing into view like a jump landing.
    private func foldSearch(_ snapshot: SearchSnapshot?) {
        let previous = findSession.display
        findSession = findControl.resolved(findSession, with: snapshot, navDirection: searchNavDirection)

        // A wrap notice ("Wrapped to start/end") appeared. Issuing the follow-up
        // navigation synchronously here would coalesce into this same @Observable
        // turn, giving the notice a zero-frame lifetime; instead latch it for a
        // readable beat, then navigate (see scheduleWrapNav). When the wrap
        // lands, the next fold clears the notice — the pinned self-clear.
        if findControl.wrapNav(findSession) != nil {
            scheduleWrapNav()
        }

        // A new landing scrolls the viewport to it (same mechanics as a jump).
        // The ONLY viewport movement is an exact FOUND landing: a .searching /
        // .exhausted poll leaves `current` unchanged, so nothing scrolls.
        var scrolledTo: UInt64?
        if let current = findSession.display.current, current != previous.current {
            landSearchOn(current.row)
            scrolledTo = current.row
        }
        if FindProbe.active { FindProbe.note(model: self, snapshot: snapshot, scrolledTo: scrolledTo) }
    }

    /// Minimum time a wrap notice stays visible before the follow-up navigation
    /// fires (the notice must be genuinely readable in both directions,
    /// including the single-match case where the landing does not change).
    private static let wrapNoticeLatch: Duration = .milliseconds(900)

    /// Latch the current wrap notice, then issue its navigation on a LATER
    /// main-actor turn (so the notice renders first) and resume polling. Armed
    /// once per notice — polls during the latch keep re-deriving the same notice
    /// but never stack another timer.
    private func scheduleWrapNav() {
        guard wrapNavTask == nil else { return }
        wrapNavTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: DocumentModel.wrapNoticeLatch)
            guard let self, !Task.isCancelled else { return }
            self.wrapNavTask = nil
            guard let session = self.session, let wrap = self.findControl.wrapNav(self.findSession) else { return }
            self.searchNavDirection = wrap.direction
            session.navigateSearch(wrap)
            self.foldSearch(session.searchStatus())   // land the wrap on a fresh turn (clears the notice)
            self.startPolling()
        }
    }

    private func cancelWrapNav() {
        wrapNavTask?.cancel()
        wrapNavTask = nil
    }

    /// Page the window to a search landing and scroll it into view (mirrors the
    /// jump landing, including the EOF overscroll allowance).
    private func landSearchOn(_ row: UInt64) {
        landViewport(on: row)
    }

    /// Per-visible-column highlight state for a data row (O(viewport), zero core
    /// calls — the frontend matcher is pinned byte-identical to the core's). The
    /// current match is strong; every other matching visible cell is subtle;
    /// header cells are never passed here (never matched).
    func cellHighlights(forRow row: Int) -> [SheetCellHighlight] {
        highlights(forRow: row, over: visibleColumns, cells: visibleBodyCells(forRow: row))
    }

    /// The window-bound analog of `cellHighlights` — the live grid's path
    /// (ARCH-column-windowing): O(column window), never O(visible columns).
    func windowCellHighlights(forRow row: Int) -> [SheetCellHighlight] {
        let cols = windowColumns()
        return highlights(forRow: row, over: cols, cells: cellsAt(cols, forRow: row))
    }

    /// Shared highlight derivation over an explicit (absolute-indexed) column
    /// list + its already-fetched cell text, so `cellHighlights` /
    /// `windowCellHighlights` differ only in which columns they cover.
    private func highlights(forRow row: Int, over columns: [Int], cells: [String]) -> [SheetCellHighlight] {
        guard let request = findSession.display.request else {
            return Array(repeating: .none, count: columns.count)
        }
        let current = findSession.display.current
        return columns.enumerated().map { index, column in
            let text = index < cells.count ? cells[index] : ""
            if let current, current.row == UInt64(row), current.column == column {
                return .strong
            }
            return cellMatcher.matches(cell: text, column: column, under: request) ? .subtle : .none
        }
    }

    // MARK: - Filter (filtered-views)

    /// Whether a filter is the active view (ARCH-filtered-views FILTERED
    /// VIEWS) — a nil poll snapshot means the identity view.
    var isFiltered: Bool { filterSnapshot != nil }

    /// The "Filtered — N of M rows" banner, or nil for the identity view (ARCH
    /// req. 11, criterion 16).
    var filterBanner: FilterBanner? {
        filterControl.banner(filterSnapshot, documentRows: filterDocumentRows ?? rowCountInfo)
    }

    /// FILTER-scan's live delayed-progress indication (ARCH-stream-copy AC9
    /// "just wiring"): the SAME gate copy/jump use (`progressGate`), fed the
    /// real elapsed since THIS filter began. Hidden whenever the banner
    /// reports no progress (no filter active, or the scan is `.done`);
    /// visible with NO cancel otherwise — a filter is a persistent view mode,
    /// not a one-shot cancellable operation (ARCH: "Filter's indicator need
    /// not offer cancel"). `FilterBannerView` reads this to decide when its
    /// existing progress-bar + % surfaces (FilterBanner.swift).
    var filterProgressIndication: ProgressIndication {
        guard let banner = filterBanner, banner.progress != nil, let startedAt = filterScanStartedAt else {
            return progressGate.indication(for: .settled)
        }
        return progressGate.indication(for: .running(elapsed: progressClock.now - startedAt, cancellable: false))
    }

    /// The row-count knowledge the JUMP popup hints with: the captured base
    /// document count while filtered — the jump box interprets ORIGINAL row
    /// numbers (ARCH-filtered-views req. 7/12, criterion 17), so its hint must
    /// be scaled to the whole document, not the filtered view — else the
    /// (identity) `rowCountInfo` unchanged.
    var jumpRowCountInfo: RowCountInfo { isFiltered ? (filterDocumentRows ?? rowCountInfo) : rowCountInfo }

    /// Whether the current find draft composes into something filterable — the
    /// filter toggle is enabled to turn ON only when this is true (an empty
    /// draft yields `.ignored`). Pure check; same compose the apply path uses.
    var canApplyFilter: Bool {
        if case .ignored = findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
            return false
        }
        return true
    }

    /// "Apply as filter" (ARCH req. 10): validate the CURRENT find draft
    /// exactly as Find does (`FindControlling.submit` — identical grammar, no
    /// new predicate UI), then route a successful compose to `setFilter`
    /// instead of `startSearch`. Entering (or re-entering) filtered mode
    /// resets any active find app-side (the core resets it too — the
    /// coordinate space changed) and lands the grid on the top of the
    /// filtered view.
    func applyFindAsFilter() {
        switch findControl.submit(findSession, visibleColumns: visibleColumns, columnCount: columnCount) {
        case .ignored:
            break
        case .rejected:
            findRejections += 1
            if FindProbe.active { FindProbe.rejected(model: self) }
        case let .run(request):
            guard let session else { return }
            // M is captured from the IDENTITY view once, the moment filtering
            // begins; while already filtered (re-running / replacing the
            // active filter) the base document count is no longer knowable
            // through the session, so the earlier capture is kept.
            let capturedDocumentRows = isFiltered ? filterDocumentRows : rowCountInfo
            guard session.setFilter(request) else {
                // The composer already validated; a real rejection here would
                // mean the core disagrees (shouldn't happen — same rules as
                // Find). Surface it exactly like a Find rejection.
                findRejections += 1
                if FindProbe.active { FindProbe.rejected(model: self) }
                return
            }
            filterDocumentRows = capturedDocumentRows
            cancelWrapNav()
            findSession = findControl.invalidated(findSession)
            searchNavDirection = .forward
            setJumpFlow(.idle)
            selection = nil   // the coordinate space just changed (ARCH-select-copy)
            filterSnapshot = session.filterStatus()
            // ARCH-stream-copy AC9 ("just wiring"): this filter's real start,
            // fed to `filterProgressIndication` — set unconditionally (even a
            // filter that resolves instantly on a tiny file is still "started
            // now"; the indication itself stays hidden whenever the banner
            // reports no progress, i.e. already `.done`).
            filterScanStartedAt = progressClock.now
            rowCountInfo = session.rowCount()
            landViewport(on: 0)
            startPolling()
        }
    }

    /// Clear the active filter (the banner's ✕, or the Find popup's "Clear
    /// filter"), restoring the identity view. Re-anchors on the source row of
    /// the top visible filtered row (ARCH criterion 13) via the same
    /// materialize-then-scroll landing mechanics as a jump/find/header-toggle
    /// re-anchor. No-op when no filter is active.
    func clearFilter() {
        guard let session, isFiltered else { return }
        // Capture the re-anchor row BEFORE clearing (the coordinate space is
        // about to change): make sure the top visible row is servable, then
        // read its original row number.
        _ = session.setWindow(firstRow: UInt64(firstVisibleRow), rowCount: 1)
        let anchor = session.sourceRow(UInt64(firstVisibleRow)) ?? 0
        session.clearFilter()
        filterSnapshot = nil
        filterDocumentRows = nil
        filterScanStartedAt = nil
        rowCountInfo = session.rowCount()
        cancelWrapNav()
        findSession = findControl.invalidated(findSession)
        searchNavDirection = .forward
        setJumpFlow(.idle)
        selection = nil   // the coordinate space just changed (ARCH-select-copy)
        landViewport(on: anchor)
        startPolling()
    }

    // MARK: - Overlay reveal / fade

    /// Whether the overlay is currently pinned open (interaction in progress):
    /// a dialect popup is expanded, the jump or find field is active, a scan is
    /// running, or the Settings window is open.
    var overlayPinned: Bool {
        if expandedPill != nil || jumpFieldActive || findFieldActive || settingsOpen { return true }
        if case .scanning = jumpFlow { return true }
        return false
    }

    /// The find match-scan is running (progress % showing) — its popup stays
    /// reachable (cancel affordance) independent of the click-away scrim.
    var findScanning: Bool { findSession.display.progress != nil }

    // MARK: - Overlay popups (single active popup; Esc / click-away dismiss)

    /// A dialect popup, the jump field, or the find field is open — drives the
    /// click-away scrim. A running scan keeps its popup up independently, so a
    /// scanning find field is excluded (like a running jump scan).
    var anyPopupOpen: Bool {
        expandedPill != nil || jumpFieldActive || (findFieldActive && !findScanning)
    }

    /// Dismiss the open dialect popup / jump field / find field (Esc or
    /// click-away). Closing the find popup clears its highlights (retaining the
    /// query). A running jump scan is left alone: its popup stays reachable.
    func dismissPopups() {
        expandedPill = nil
        jumpFieldActive = false
        if findFieldActive { closeFind() }
    }

    /// Open (or re-close) a dialect popup, closing the other popups so at most
    /// one is ever open at a time.
    func toggleExpandedPill(_ kind: PillKind) {
        expandedPill = (expandedPill == kind) ? nil : kind
        jumpFieldActive = false
        if findFieldActive { closeFind() }
    }

    /// Open the jump field, closing any dialect popup / the find field.
    func openJumpField() {
        jumpFieldActive = true
        expandedPill = nil
        if findFieldActive { closeFind() }
    }

    /// Open the find field, closing any dialect popup / the jump field.
    func openFindField() {
        findFieldActive = true
        expandedPill = nil
        jumpFieldActive = false
    }

    func revealOverlay() {
        overlayRevealed = true
        scheduleFade()
    }

    /// Keyboard reveal (⌘J): reveal the overlay and ask the jump field to open.
    func requestJumpFocus() {
        jumpFocusRequests += 1
        revealOverlay()
    }

    /// Keyboard reveal (⌘F): reveal the overlay and ask the find field to open.
    func requestFindFocus() {
        findFocusRequests += 1
        revealOverlay()
    }

    func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.overlayPinned {
                self.scheduleFade()          // stay open while interacting
            } else {
                self.overlayRevealed = false
            }
        }
    }

    // MARK: - Timing marker

    /// Emits the cold-start marker for the first data-bearing frame of an open,
    /// exactly once per open generation. Error / empty frames never call this.
    func markFirstRowsVisible() {
        guard markedGeneration != openGeneration else { return }
        markedGeneration = openGeneration
        LaunchTiming.markFirstRowsVisible()
    }

    // MARK: - Dump snapshot (headless rendering of overlay/pill/progress states)

    /// A detached, session-less model carrying this document's facts + current
    /// window plus forced overlay state, for the `LESSSHEET_DUMP_FRAME` hook to
    /// render specific presentation states off-screen. It never opens or pages
    /// (no core session), so rendering it is side-effect-free.
    static func dumpSnapshot(
        from live: DocumentModel,
        revealed: Bool,
        expandedPill: PillKind?,
        jumpFlow: JumpFlow,
        jumpFieldActive: Bool = false,
        findSession: FindSession = FindControl().initial(),
        findFieldActive: Bool = false
    ) -> DocumentModel {
        let snapshot = DocumentModel(opener: live.opener)
        snapshot.path = live.path
        snapshot.columnCount = live.columnCount
        snapshot.headerCells = live.headerCells
        snapshot.windowColumnLabels = live.windowColumnLabels
        snapshot.windowColumnMetadata = live.windowColumnMetadata
        snapshot.dialect = live.dialect
        snapshot.columnWidths = live.columnWidths
        snapshot.window = live.window
        snapshot.rowCountInfo = live.rowCountInfo
        snapshot.indexProgress = live.indexProgress
        snapshot.setVisibility(live.visibility)
        snapshot.phase = .document
        snapshot.overlayRevealed = revealed
        snapshot.expandedPill = expandedPill
        snapshot.jumpFlow = jumpFlow
        snapshot.jumpFieldActive = jumpFieldActive
        snapshot.findSession = findSession
        snapshot.findFieldActive = findFieldActive
        return snapshot
    }

    /// Verification-only: page the live window to `startRow` before a headless
    /// dump so a grid dump can exhibit larger row numbers / the widened gutter
    /// (mirrors the `LESSSHEET_HIDE_COLS` pre-hide hook). Inert in normal use.
    func dumpMaterialize(startRow: UInt64) {
        firstVisibleRow = Int(min(startRow, UInt64(Int.max)))
        lastVisibleCount = 40
        materialize(start: startRow, count: 120)
    }

    // MARK: - Polling (off the main actor; stops when idle)

    private func startPolling() {
        guard let session else { return }
        // Hand the new task the old one and let it cancel + join before polling,
        // so two poll loops never fold snapshots concurrently (the join happens
        // off the main actor; the prior task exits within one poll interval).
        let previous = pollTask
        pollTask = Task.detached(priority: .utility) { [weak self, session] in
            previous?.cancel()
            _ = await previous?.value
            while !Task.isCancelled {
                let rc = session.rowCount()
                let ip = session.indexProgress()
                let js = session.jumpStatus()
                let ss = session.searchStatus()
                let fs = session.filterStatus()
                let columns = (session as? CoreDocumentSession)?.columnInferenceState()
                let columnProgress = (session as? CoreDocumentSession)?.columnInferenceProgress()
                let keepGoing = await self?.applyPoll(rowCount: rc, progress: ip, jump: js, search: ss,
                                                       filter: fs, columns: columns,
                                                       columnProgress: columnProgress) ?? false
                if !keepGoing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Fold one poll snapshot into state; returns whether polling should
    /// continue (stops once the desired window is resolved and neither the
    /// index, a jump, a search, nor a filter-scan is active, so idle documents
    /// cost nothing).
    private func applyPoll(
        rowCount: RowCountInfo, progress: ScanProgress, jump: JumpStatus, search: SearchSnapshot?, filter: FilterSnapshot?,
        columns: (active: Bool, generation: UInt64)?, columnProgress: Double?
    ) -> Bool {
        rowCountInfo = rowCount
        indexProgress = progress
        filterSnapshot = filter
        columnInferenceProgress = columnProgress
        foldJump(jump)
        foldSearch(search)
        if let columns, columns.generation != columnMetadataGeneration,
           let core = session as? CoreDocumentSession {
            columnMetadataGeneration = columns.generation
            var changedColumns = Set<Int>()
            for metadata in core.columnMetadata(coordinatedInferenceIDs()) {
                if gridInferenceIDs.contains(UInt32(metadata.column)) {
                    if windowColumnMetadata[metadata.column] != metadata {
                        changedColumns.insert(metadata.column)
                    }
                    windowColumnMetadata[metadata.column] = metadata
                }
                if panelInferenceIDs.contains(UInt32(metadata.column)) || panelSelectedColumn == UInt32(metadata.column) {
                    if panelMetadata[metadata.column] != metadata {
                        changedColumns.insert(metadata.column)
                    }
                    panelMetadata[metadata.column] = metadata
                }
            }
            requestColumnConfigurationRedraw(changedColumns)
        }

        let filterOngoing = filter.map { !$0.totalIsFinal } ?? false
        let jumpScanning: Bool = { if case .scanning = jumpFlow { return true } else { return false } }()
        let decision = windowPoll.decide(WindowPollInputs(
            window: desiredWindow,
            indexComplete: progress.isComplete,
            jumpScanning: jumpScanning,
            searchActive: Self.searchActive(search),
            filterOngoing: filterOngoing
        ))
        if decision.reissueWindow {
            materialize(start: desiredStart, count: desiredCount)
        }

        return decision.continuePolling || (columns?.active ?? false)
    }

    /// A search still needs polling while its match-scan runs or a navigation
    /// is being served (counts grow / a landing is pending).
    private static func searchActive(_ snapshot: SearchSnapshot?) -> Bool {
        guard let snapshot else { return false }
        if case .scanning = snapshot.phase { return true }
        if case .searching = snapshot.nav { return true }
        return false
    }

    private func stopPolling() async {
        pollTask?.cancel()
        await pollTask?.value      // ensure no poll runs concurrently with ls_close
        pollTask = nil
    }

    // MARK: - Column width measurement (head sample; O(head) arithmetic, no
    // per-cell text layout — ARCH-column-windowing)

    /// Establishes EVERY column's width from the head sample in O(head) —
    /// cheap character-count arithmetic, NEVER a `.size(withAttributes:)` call
    /// per cell (100k text-layout calls across 100k columns is exactly what
    /// made a wide document's cold-open take 3+ s; ARCH-column-windowing). The
    /// data font is monospaced (`SheetRowView.font`, `== bodyFont` here), so
    /// for ordinary text a column's pixel width is (its widest display-cell
    /// count over the head sample, header included) times the font's own
    /// advance width — arithmetic, not layout — plus padding, capped exactly
    /// as before. This gives every column a REAL, independent width up front
    /// (never a placeholder that pops in later) but is an ESTIMATE for exotic
    /// glyphs (emoji/CJK/combining, whose rendered advance can differ from a
    /// plain scalar's): `growColumnWidthsToFitWindow` gives every column an
    /// ACCURATE `.size()` correction (its header included) the moment it
    /// first enters the horizontal column window, monotone, so a
    /// viewport-fitting file — every column in the window from the very first
    /// layout — refines immediately to the exact widths an unwindowed
    /// measurement would have given it (ARCH AC4); only a wide document's
    /// off-screen columns keep the estimate until scrolled into view.
    static func measureColumnWidths(header: [String]?, sample: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }
        let bodyFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // One O(1) measurement (not per-column, not per-cell) gives the exact
        // per-character advance of the monospaced data font.
        let advance = max(textWidth("0", bodyFont), 1)
        let minW = GridMetrics.minColumnWidth
        let maxW = GridMetrics.maxColumnWidth
        let padding = GridMetrics.cellHPadding * 2
        // Hoisted out of the loop: `header` is unwrapped ONCE (not per
        // column), and `sample`'s row count is read once — this loop runs
        // `columnCount` times (up to 100k on a wide document) so anything
        // paid per-iteration, however small, is worth hoisting.
        let headerCells = header ?? []
        let headerCount = headerCells.count
        let sampleCount = sample.count

        var widths = [CGFloat](repeating: minW, count: columnCount)
        // `.utf8.count` (a stored length on a native Swift String, O(1)) is a
        // cheaper display-cell proxy than `.count` (grapheme-cluster
        // segmentation) for this cheap pass; both are estimates for the SAME
        // exotic-glyph cases (ARCH), and both are superseded by the accurate
        // `.size()` refine the moment a column enters the horizontal window.
        widths.withUnsafeMutableBufferPointer { buf in
            for c in 0..<columnCount {
                let label = (c < headerCount && !headerCells[c].isEmpty) ? headerCells[c] : GenericColumnName.name(at: c)
                var cells = label.utf8.count
                var r = 0
                while r < sampleCount {
                    let row = sample[r]
                    if c < row.count {
                        let n = row[c].utf8.count
                        if n > cells { cells = n }
                    }
                    r += 1
                }
                let estimate = CGFloat(cells) * advance + padding
                buf[c] = min(max(estimate, minW), maxW)
            }
        }
        return widths
    }

    private static func textWidth(_ string: String, _ font: NSFont) -> CGFloat {
        // A single measured line; ceil to a whole point for crisp grid lines.
        let size = (string as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
}

/// Which guess-pill a control refers to (also the overlay's expansion key).
enum PillKind: Equatable, Hashable {
    case header
    case separator
    case quote
}
