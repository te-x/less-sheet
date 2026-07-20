import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — windowed paging (O(viewport)): the row + horizontal column
// window materialization, the memoized layout-width cache, and the panel /
// coordinated-inference plumbing. Pure code motion out of ViewerModel.swift.

extension DocumentModel {
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
        let visibleStart = self.firstVisibleRow
        let visibleCount = self.lastVisibleCount

        let coversLeft = wStart == 0 || visibleStart >= wStart + guardRows
        let coversRight = (visibleStart + visibleCount <= wStart + wLen - guardRows)
            || (wStart + wLen >= displayRowCount)
        if wLen > 0 && coversLeft && coversRight { return }

        let newStart = max(0, visibleStart - buffer)
        let newCount = visibleCount + buffer * 2
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
        let coversLeft = target.isEmpty || window.firstColumn == 0
            || target.lowerBound >= window.firstColumn + guardCols
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
    func refreshLayoutWidthsIfNeeded() {
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
        for index in 0..<cols.count {
            let column = cols[index]
            let auto = column < source.count ? source[column] : GridMetrics.minColumnWidth
            // EFFECTIVE width (ARCH-select-copy AC5): a manual override wins,
            // regardless of the auto baseline — this is what keeps
            // `cachedLayoutWidths`/`cachedTotalVisibleWidth` (the column-
            // window geometry + total-width inputs) honest about a resize.
            let width = manual.isEmpty ? auto : (manual[column].map { CGFloat($0) } ?? auto)
            widths[index] = Double(width)
            total += width
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
    func markLayoutWidthsStale() {
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
    func materialize(start: UInt64, count: Int) {
        guard let session else { return }
        desiredStart = start
        desiredCount = count
        let columns = columnFetchRange()
        window = session.setWindow(firstRow: start, rowCount: count, columns: columns)
        // A fresh window materialization: the visible bytes just changed (even
        // when the geometry happens to match the previous window — e.g. a
        // same-dims document re-open lands here at firstRow 0). Bump the mask's
        // content epoch so the next highlight refetches (AC5: one fetch per
        // materialize), never serving the previous window's mask.
        invalidateMatchFlags()
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
                labels[start + offset] = String(bytes: value.bytes, encoding: .utf8) ?? ""
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
                labels[Int(id)] = PanelColumnLabel(text: String(bytes: value.bytes, encoding: .utf8) ?? "",
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

    func coordinatedInferenceIDs() -> [UInt32] {
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

    func requestCoordinatedInference(_ core: CoreDocumentSession) {
        let ids = coordinatedInferenceIDs()
        if !ids.isEmpty { _ = core.requestColumnInference(ids) }
    }

    func requestCoordinatedInference(core: CoreDocumentSession?) {
        guard let core else { return }
        requestCoordinatedInference(core)
    }

    var desiredWindow: DesiredWindow {
        DesiredWindow(
            requestedCount: desiredCount,
            returnedCount: window.rows.count,
            moreWithinView: Int(window.firstRow) + window.rows.count < displayRowCount
        )
    }
}
