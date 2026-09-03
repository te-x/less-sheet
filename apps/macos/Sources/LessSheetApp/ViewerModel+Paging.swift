import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// Windowed paging: the row and horizontal column window materialization, the
// memoized layout-width cache, and the coordinated column-inference plumbing.
// Everything here is O(viewport), never O(file) or O(columnCount).

extension DocumentModel {
    // MARK: - Windowed paging (O(viewport); UI-thread fast path)

    /// The grid reports its visible row range on scroll and resize; the core
    /// window (viewport plus a scroll buffer each way) is re-paged only when that
    /// range leaves a comfort zone inside the current one. `setWindow` never
    /// scans, so this is allowed to stay on the main thread.
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
            // A settled document's poll task has already exited; the short prefix
            // needs it back to retry this request until it fills or hits EOF.
            startPolling()
        }
    }

    /// The horizontal analog of `viewportChanged`: the grid reports its scroll
    /// clip, the column window is re-derived from the MEMOIZED widths, and newly
    /// revealed columns are re-fetched once the last fetch's comfort zone runs
    /// out. A scroll tick therefore costs O(1) setup plus the window scan, and a
    /// re-fetch only O(window) — never O(columnCount) either way. A no-op once
    /// the window settles, so a stable window is never re-touched.
    func horizontalViewportChanged(viewportX: CGFloat, viewportWidth: CGFloat) {
        refreshLayoutWidthsIfNeeded()
        guard !cachedLayoutWidths.isEmpty else { return }
        let win = columnLayout.window(
            widths: cachedLayoutWidths, viewportX: Double(viewportX), viewportWidth: Double(viewportWidth),
            overscan: GridMetrics.columnOverscan
        )
        guard win != columnWindow else { return }
        setColumnWindow(win)

        // Re-materialize only when the new window would spill past the last
        // fetch by more than the comfort margin. `materialize` re-runs the width
        // grow against the refreshed cells itself, which is why that branch does
        // not also call it.
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

    /// The ABSOLUTE column range the current window spans. `setWindow(columns:)`
    /// needs one contiguous range, so a hidden column between two visible
    /// in-window ones is folded in — a cheap superset, never a full scan.
    private func absoluteColumnWindow() -> Range<Int> {
        let cols = windowColumns()
        guard let first = cols.first, let last = cols.last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// The ABSOLUTE column range `materialize` asks the core for: the current
    /// window padded by `columnFetchBuffer` each side, so a horizontal scroll
    /// settles inside an already-fetched range. Before the grid's first geometry
    /// callback it falls back to the leftmost `initialColumnFetchCount` columns
    /// rather than the whole document — the open-time width measurement reads
    /// exactly this fetch, which is what keeps a session's first materialize
    /// O(hundreds) of columns however wide the document is.
    private func columnFetchRange() -> Range<Int> {
        guard columnCount > 0 else { return 0..<0 }
        guard !columnWindow.isEmpty else {
            return 0..<min(columnCount, GridMetrics.initialColumnFetchCount)
        }
        let target = absoluteColumnWindow()
        let buffer = GridMetrics.columnFetchBuffer
        return max(0, target.lowerBound - buffer) ..< min(columnCount, target.upperBound + buffer)
    }

    /// Rebuilds the render-order widths and their sum together, in one pass,
    /// and only when a width batch or the visibility actually changed — so a
    /// structural refresh and a scroll-driven window query never each pay their
    /// own traversal of the same data.
    func refreshLayoutWidthsIfNeeded() {
        guard layoutWidthsStale else { return }
        let cols = visibleColumns
        // Both hoisted to locals once: `columnWidths` is @Observable-tracked, so
        // re-reading it inside a 100k-iteration loop pays that tracking cost
        // 100k times, and an empty manual map makes the check below one
        // is-empty test rather than a hash lookup per column.
        let source = columnWidths
        let manual = manualColumnWidths
        var widths = [Double](repeating: 0, count: cols.count)
        var total: CGFloat = 0
        for index in 0..<cols.count {
            let column = cols[index]
            let auto = column < source.count ? source[column] : GridMetrics.minColumnWidth
            // A manual override wins over the auto baseline, so the geometry and
            // total-width inputs stay honest about a resize.
            let width = manual.isEmpty ? auto : (manual[column].map { CGFloat($0) } ?? auto)
            widths[index] = Double(width)
            total += width
        }
        cachedLayoutWidths = widths
        cachedTotalVisibleWidth = total
        layoutWidthsStale = false
    }

    /// Call after every width-batch or visibility change, so the next read
    /// rebuilds instead of serving a stale cache.
    func markLayoutWidthsStale() {
        layoutWidthsStale = true
    }

    /// Materializes the row window AND the current horizontal column window
    /// together, so the fetch is O(visible columns) rather than O(columnCount).
    /// `window.firstColumn` then carries that range, and every consumer indexes
    /// column-RELATIVE: absolute column `c` sits at slot `c - firstColumn`.
    func materialize(start: UInt64, count: Int) {
        guard let session else { return }
        desiredStart = start
        desiredCount = count
        let columns = columnFetchRange()
        window = session.setWindow(firstRow: start, rowCount: count, columns: columns)
        // The visible bytes just changed, even when the geometry happens to match
        // the previous window, so the highlight mask must refetch.
        invalidateMatchFlags()
        refreshWindowLabels(columns: columns)
        growColumnWidthsToFitWindow()
    }

    /// Refreshes only the buffered horizontal label window. The ABI caps a call
    /// at `columnLabelSearchBatchMax` ids, so a very wide fetch is split into
    /// bounded batches; the retained cache stays O(the fetch window).
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
                labels[start + offset] = String(lossyUTF8: value.bytes)
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

    /// Declares the panel's layout-bounded id set. The label and metadata copies
    /// happen off-main and replace the prior bounded cache.
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
                labels[Int(id)] = PanelColumnLabel(text: String(lossyUTF8: value.bytes),
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

    /// The one desired inference set, in priority order: the inspected column,
    /// then the panel viewport, then the grid fills the remaining slots. Panel
    /// rows are what the user is actively looking at and must never be starved
    /// by a very wide grid window consuming the whole batch cap.
    func coordinatedInferenceIDs() -> [UInt32] {
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
