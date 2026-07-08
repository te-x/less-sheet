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
    private(set) var dialect = DialectReport(
        separator: 0x2C, quote: 0x22, hasHeader: false,
        separatorForced: false, quoteForced: false, headerForced: false
    )
    private(set) var columnWidths: [CGFloat] = []      // per ORIGINAL column index

    // Windowed data + progress knowledge.
    private(set) var window = RowWindow(firstRow: 0, rows: [])
    private(set) var rowCountInfo = RowCountInfo(count: 0, isExact: true)
    private(set) var indexProgress = ScanProgress(bytesScanned: 0, bytesTotal: 0, isComplete: true)

    // Hidden-column + jump view-model state.
    private(set) var visibility = ColumnVisibility(columnCount: 0, hiddenColumns: [])
    private(set) var jumpFlow: JumpFlow = .idle

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

    // Overlay presentation state.
    var overlayRevealed = false
    var expandedPill: PillKind?
    var jumpFieldActive = false
    var findFieldActive = false
    var settingsOpen = false
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
    private let jumpControl = JumpControl()
    private let composer = DialectComposer()
    private let findControl = FindControl()
    private let filterControl = FilterControl()
    private let cellMatcher = CellMatcher()
    /// The direction of the outstanding search navigation (drives the wrap
    /// notice's start/end choice when a poll reports exhaustion).
    private var searchNavDirection: SearchDirection = .forward

    private var session: (any DocumentSession)?
    private var markedGeneration = -1
    private var firstVisibleRow = 0
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

    init(opener: any DocumentSessionOpening = CoreSessionOpener()) {
        self.opener = opener
    }

    // MARK: - Opening (single funnel)

    /// The one open path shared by panel / launch / CLI / drag. `forcing`
    /// defaults to sniff-all (a fresh open); dialect re-opens pass a composed
    /// override and carry the caller's prior column visibility.
    func open(path: String, forcing override: DialectOverride = .sniffAll, carrying previous: ColumnVisibility? = nil) async {
        await stopPolling()
        session?.close()
        session = nil

        do {
            let session = try await opener.open(path: path, forcing: override)
            self.session = session
            self.path = path
            self.columnCount = session.columnCount
            self.headerCells = session.headerCells
            self.dialect = session.dialect
            self.rowCountInfo = session.rowCount()
            self.indexProgress = session.indexProgress()

            // Hidden-column state: carry across a re-open when the column count
            // is unchanged, else reset to all-visible (ARCH req. 10).
            if let previous {
                self.visibility = visibilityManager.carriedOver(previous, toColumnCount: session.columnCount)
            } else {
                self.visibility = visibilityManager.allVisible(columnCount: session.columnCount)
                self.pendingHeaderShift = nil   // a fresh open never re-anchors to a prior toggle
            }

            // Verification-only: pre-hide columns (comma-separated indices) so a
            // headless dump can show hidden-column reflow. Absent in normal use.
            if previous == nil, let raw = ProcessInfo.processInfo.environment["LESSSHEET_HIDE_COLS"] {
                for token in raw.split(separator: ",") {
                    if let column = Int(token.trimmingCharacters(in: .whitespaces)) {
                        self.visibility = visibilityManager.toggling(self.visibility, column: column)
                    }
                }
            }

            // First window from the top; frozen column widths from that head
            // sample (O(head), measured once for the session).
            self.firstVisibleRow = 0
            self.lastVisibleCount = 40   // sensible default until the first geometry callback
            materialize(start: 0, count: GridMetrics.scrollBufferRows)
            self.columnWidths = Self.measureColumnWidths(
                header: session.headerCells,
                sample: window.rows,
                columnCount: session.columnCount
            )
            self.jumpFlow = .idle
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
            self.pendingScrollRow = nil
            self.phase = .document
            startPolling()
        } catch {
            self.phase = .failure(error, path: path)
        }
        openGeneration += 1
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
        Task { await stopPolling(); session?.close(); session = nil }
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
    }

    private func materialize(start: UInt64, count: Int) {
        guard let session else { return }
        desiredStart = start
        desiredCount = count
        window = session.setWindow(firstRow: start, rowCount: count)
    }

    /// Cells for a data row, read from the currently materialized window.
    /// Rows outside the window return `nil` (the grid renders empty cells that
    /// fill in once the frontier advances and the window re-materializes).
    func cells(forRow row: Int) -> [String]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.rows.count else { return nil }
        return window.rows[idx]
    }

    /// Per-cell display-truncation flags for a data row, PARALLEL to
    /// `cells(forRow:)` (mirrors `RowWindow.truncated`, ARCH req. 13/20). Rows
    /// outside the window return `nil`, same rule as `cells(forRow:)`.
    func truncated(forRow row: Int) -> [Bool]? {
        let start = Int(window.firstRow)
        let idx = row - start
        guard idx >= 0, idx < window.truncated.count else { return nil }
        return window.truncated[idx]
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
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let sample = String(repeating: "8", count: max(1, digits)) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + GridMetrics.rowNumberHPadding * 2
    }

    // MARK: - Grid view helpers (shared by the live grid and the dump grid)

    /// Frozen widths of the visible columns, in render order.
    func visibleWidths() -> [CGFloat] {
        visibleColumns.map { $0 < columnWidths.count ? columnWidths[$0] : GridMetrics.minColumnWidth }
    }

    /// Header labels of the visible columns (effective names or generic A/B/C).
    func headerLabels() -> [String] {
        visibleColumns.map { columnLabel($0) }
    }

    /// Visible-column cells for a data row, empty-padded while not yet loaded.
    func visibleBodyCells(forRow row: Int) -> [String] {
        guard let full = cells(forRow: row) else {
            return Array(repeating: "", count: visibleColumns.count)
        }
        return visibleColumns.map { $0 < full.count ? full[$0] : "" }
    }

    /// Visible-column truncation flags for a data row (ARCH req. 13/20),
    /// false-padded while not yet loaded — same shape as `visibleBodyCells`.
    /// Driven entirely by the core's per-cell flag; never re-measures cells.
    func visibleBodyTruncated(forRow row: Int) -> [Bool] {
        guard let full = truncated(forRow: row) else {
            return Array(repeating: false, count: visibleColumns.count)
        }
        return visibleColumns.map { $0 < full.count ? full[$0] : false }
    }

    // MARK: - Column visibility (pure model; grid reflows)

    var visibleColumns: [Int] { visibilityManager.visibleColumns(visibility) }

    func canHide(_ column: Int) -> Bool { visibilityManager.canHide(visibility, column: column) }

    func toggleColumn(_ column: Int) {
        visibility = visibilityManager.toggling(visibility, column: column)
    }

    /// The label for a column (effective header name, else generic A/B/C…),
    /// used by the grid header and the Settings checkboxes.
    func columnLabel(_ column: Int) -> String {
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
        jumpFlow = .idle
        if let restoreTo { pendingScrollRow = restoreTo }
        jumpFieldActive = true
        jumpRejections += 1
        if JumpProbe.active { JumpProbe.rejected(model: self, scanned: scanned, restoredTo: restoreTo) }
    }

    func beginJump(to target: UInt64) {
        guard let session else { return }
        jumpFlow = jumpControl.begin(target: target, preJumpFirstRow: UInt64(firstVisibleRow))
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
        jumpFlow = next
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
            jumpFlow = next          // mark landed FIRST so a later poll doesn't re-fire
            landOn(row)
            return
        }
        jumpFlow = next
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
    }

    // MARK: - Find (search)

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
        guard let request = findSession.display.request else {
            return Array(repeating: .none, count: visibleColumns.count)
        }
        let cells = visibleBodyCells(forRow: row)
        let current = findSession.display.current
        return visibleColumns.enumerated().map { index, column in
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

    /// The row-count knowledge the JUMP popup hints with: the captured base
    /// document count while filtered — the jump box interprets ORIGINAL row
    /// numbers (ARCH-filtered-views req. 7/12, criterion 17), so its hint must
    /// be scaled to the whole document, not the filtered view — else the
    /// (identity) `rowCountInfo` unchanged.
    var jumpRowCountInfo: RowCountInfo { isFiltered ? (filterDocumentRows ?? rowCountInfo) : rowCountInfo }

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
            jumpFlow = .idle
            filterSnapshot = session.filterStatus()
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
        rowCountInfo = session.rowCount()
        cancelWrapNav()
        findSession = findControl.invalidated(findSession)
        searchNavDirection = .forward
        jumpFlow = .idle
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
        snapshot.dialect = live.dialect
        snapshot.columnWidths = live.columnWidths
        snapshot.window = live.window
        snapshot.rowCountInfo = live.rowCountInfo
        snapshot.indexProgress = live.indexProgress
        snapshot.visibility = live.visibility
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
                let keepGoing = await self?.applyPoll(rowCount: rc, progress: ip, jump: js, search: ss, filter: fs) ?? false
                if !keepGoing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Fold one poll snapshot into state; returns whether polling should
    /// continue (stops once the index is complete and neither a jump, a
    /// search, nor an unfinished filter-scan is active, so idle documents
    /// cost nothing).
    private func applyPoll(
        rowCount: RowCountInfo, progress: ScanProgress, jump: JumpStatus, search: SearchSnapshot?, filter: FilterSnapshot?
    ) -> Bool {
        rowCountInfo = rowCount
        indexProgress = progress
        filterSnapshot = filter
        foldJump(jump)
        foldSearch(search)

        // Under a filter, rows beyond its discovered-match frontier become
        // servable as the filter-scan (or a jump/find sharing its slot)
        // advances (ARCH-filtered-views req. 5) — re-materialize on the same
        // short-window signal already used for the base index. A CANCELLED
        // filter-scan still counts as "ongoing": under LS_INDEX_AUTO it
        // resumes to completion on its own (api/lesssheet.h FILTERED VIEWS),
        // so polling must keep watching it rather than going silent.
        let filterOngoing = filter.map { !$0.totalIsFinal } ?? false
        if (!progress.isComplete || filterOngoing), window.rows.count < desiredCount,
           Int(window.firstRow) + window.rows.count < displayRowCount {
            materialize(start: desiredStart, count: desiredCount)
        }

        let jumpScanning: Bool = { if case .scanning = jumpFlow { return true } else { return false } }()
        return !progress.isComplete || jumpScanning || Self.searchActive(search) || filterOngoing
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

    // MARK: - Column width measurement (head sample; frozen for the session)

    static func measureColumnWidths(header: [String]?, sample: [[String]], columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }
        let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let headFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        var widths = [CGFloat](repeating: GridMetrics.minColumnWidth, count: columnCount)
        for c in 0..<columnCount {
            let label = (header != nil && c < header!.count && !header![c].isEmpty)
                ? header![c] : GenericColumnName.name(at: c)
            var w = textWidth(label, headFont)
            for row in sample where c < row.count {
                w = max(w, textWidth(row[c], bodyFont))
            }
            widths[c] = min(max(w + GridMetrics.cellHPadding * 2, GridMetrics.minColumnWidth), GridMetrics.maxColumnWidth)
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
