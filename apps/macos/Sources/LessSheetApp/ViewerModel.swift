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

    // A row the grid should bring into view (jump landing / cancel restore),
    // consumed and cleared by the grid once applied.
    var pendingScrollRow: UInt64?

    // Overlay presentation state.
    var overlayRevealed = false
    var expandedPill: PillKind?
    var jumpFieldActive = false
    var settingsOpen = false
    /// Bumped by the ⌘J command to ask the overlay to reveal + focus the jump
    /// field (the keyboard reveal path).
    private(set) var jumpFocusRequests = 0
    /// Bumped whenever a jump is REJECTED (target past the last row, or invalid
    /// input): the jump field re-arms and the overlay blinks/shakes it (item 4).
    private(set) var jumpRejections = 0

    // MARK: Collaborators (pure view-model logic; pinned by frozen tests)

    private let opener: any DocumentSessionOpening
    private let visibilityManager = ColumnVisibilityManager()
    private let jumpControl = JumpControl()
    private let composer = DialectComposer()

    private var session: (any DocumentSession)?
    private var markedGeneration = -1
    private var firstVisibleRow = 0
    private var lastVisibleCount = 1
    private var desiredStart: UInt64 = 0
    private var desiredCount = 0
    private var pollTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?

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
        Task { await self.open(path: path, forcing: override, carrying: carried) }
        return true
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
        // Clamp to the last data row so scrolling into the overscroll strip
        // (whose filler rows carry no number) never inflates the gutter.
        let maxVisible = min(firstVisibleRow + max(lastVisibleCount, 1), max(displayRowCount, 1))
        return Self.rowNumberWidth(digits: Self.rowNumberDigits(forMaxNumber: maxVisible))
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
        // count is rejected immediately, no scan.
        if rowCountInfo.isExact && target >= rowCountInfo.count {
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
            // the reject decision lives here, above it.
            if case let .scanning(target, preJumpFirstRow, _) = previous, row < target {
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
        firstVisibleRow = Int(min(row, UInt64(Int.max)))
        materialize(start: row, count: GridMetrics.scrollBufferRows * 2)
        pendingScrollRow = row
        if JumpProbe.active { JumpProbe.arrived(model: self, landed: row) }
    }

    // MARK: - Overlay reveal / fade

    /// Whether the overlay is currently pinned open (interaction in progress):
    /// a dialect popup is expanded, the jump field is active, a scan is
    /// running, or the Settings window is open.
    var overlayPinned: Bool {
        if expandedPill != nil || jumpFieldActive || settingsOpen { return true }
        if case .scanning = jumpFlow { return true }
        return false
    }

    // MARK: - Overlay popups (single active popup; Esc / click-away dismiss)

    /// A dialect popup or the jump field is open — drives the click-away scrim
    /// (a running scan keeps its popup up independently, so it is excluded).
    var anyPopupOpen: Bool { expandedPill != nil || jumpFieldActive }

    /// Dismiss the open dialect popup / jump field (Esc or click-away). A
    /// running jump scan is left alone: its popup stays reachable (cancel)
    /// until the scan ends or the user cancels it.
    func dismissPopups() {
        expandedPill = nil
        jumpFieldActive = false
    }

    /// Open (or re-close) a dialect popup, closing the jump field so at most
    /// one popup is ever open at a time.
    func toggleExpandedPill(_ kind: PillKind) {
        expandedPill = (expandedPill == kind) ? nil : kind
        jumpFieldActive = false
    }

    /// Open the jump field, closing any dialect popup.
    func openJumpField() {
        jumpFieldActive = true
        expandedPill = nil
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
        jumpFieldActive: Bool = false
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
        pollTask?.cancel()
        pollTask = Task.detached(priority: .utility) { [weak self, session] in
            while !Task.isCancelled {
                let rc = session.rowCount()
                let ip = session.indexProgress()
                let js = session.jumpStatus()
                let keepGoing = await self?.applyPoll(rowCount: rc, progress: ip, jump: js) ?? false
                if !keepGoing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Fold one poll snapshot into state; returns whether polling should
    /// continue (stops once the index is complete and no scan is running, so
    /// idle documents cost nothing).
    private func applyPoll(rowCount: RowCountInfo, progress: ScanProgress, jump: JumpStatus) -> Bool {
        rowCountInfo = rowCount
        indexProgress = progress
        foldJump(jump)

        // If the current window came up short of what the viewport wants and
        // the frontier is still advancing, re-materialize to pick up new rows.
        if !progress.isComplete, window.rows.count < desiredCount,
           Int(window.firstRow) + window.rows.count < displayRowCount {
            materialize(start: desiredStart, count: desiredCount)
        }

        let scanning: Bool = { if case .scanning = jumpFlow { return true } else { return false } }()
        return !progress.isComplete || scanning
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
