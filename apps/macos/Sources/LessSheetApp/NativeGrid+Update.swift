// The model -> AppKit funnel (apply) + column-window/metric sync.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {
    // MARK: Model -> AppKit

    /// The STRUCTURAL geometry: the gutter width and the total content width.
    /// Only on a structural change — build, open, hidden-column reflow, filter
    /// toggle, width batch — never per scroll tick. `refreshColumnWindow` is the
    /// O(window) counterpart that is safe on every tick.
    func refreshLayoutMetrics() {
        gutterWidth = model.rowNumberColumnWidth()
        totalDataWidth = model.totalVisibleWidth
    }

    /// Re-derives the horizontal column window from the current scroll clip and
    /// pulls the window-bound widths and labels the row and header views draw.
    /// Cheap arithmetic, and a no-op once the window settles, so it is safe on
    /// every layout pass and scroll tick.
    func refreshColumnWindow() {
        let clip = scroll.contentView.bounds
        model.horizontalViewportChanged(viewportX: clip.origin.x, viewportWidth: clip.width)
        widths = model.windowWidths()
        headerLabels = model.windowHeaderLabels()
        headerTruncated = model.windowHeaderTruncated()
        columnAlignments = model.windowColumnAlignments()
        absoluteColumns = model.windowAbsoluteColumns()
        columnFirstX = CGFloat(model.columnWindow.firstX)
        let truncatedColumns = zip(absoluteColumns, headerTruncated).compactMap { column, truncated in
            truncated ? "column \(column + 1) label truncated" : nil
        }
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.group)
        header.setAccessibilityLabel(truncatedColumns.isEmpty
            ? "Column headers"
            : "Column headers, \(truncatedColumns.joined(separator: ", "))")
        // The header's resize hit-zones sit at fixed offsets from this same
        // geometry, and AppKit re-derives cursor rects only on a frame change or
        // an explicit invalidate — never on a content-offset change.
        container.window?.invalidateCursorRects(for: header)
    }

    /// The single funnel for model-driven grid updates: detect what changed and
    /// do the minimum AppKit work. Idempotent, and every branch is O(viewport).
    func apply() {
        guard built, container.window != nil else { return }
        applyTick &+= 1

        if model.openGeneration != lastOpenGeneration {
            applyReopen()
            return
        }
        if applyConfigurationChanges() { return }
        applyPresentationChanges()
        applyStructuralColumnChanges()
        applyFilterToggle()

        syncRowCountEstimate()
        refreshVisibleRows()
        // The landing runs LAST, so it wins over the two origin-preserving
        // branches above.
        applyPendingLanding()
        flushGridDisplay()
    }

    /// A re-open resets columns and widths and reloads from the top — except
    /// across a header toggle, which keeps its place by DATA-ROW INDEX.
    private func applyReopen() {
        // Capture the exact top data row from the pre-reload scroll, before
        // anything resets it. The anchor is at or near the scanned frontier, so
        // re-landing on it costs no scan.
        let headerShift = model.consumePendingHeaderShift()
        let preToggleTop = headerShift != nil ? currentTopDataRow() : 0

        lastOpenGeneration = model.openGeneration
        // The previous document's fit identity is meaningless here: a matching
        // row/x/width must not suppress the new document's first fit.
        lastFitViewport = nil
        refreshLayoutMetrics()
        lastVisibleColumns = model.visibleColumns
        lastColumnWidths = model.columnWidths
        lastColumnPresentationRevision = model.columnPresentationRevision
        lastColumnWidthRevision = model.columnWidthRevision
        lastColumnConfigurationRevision = model.columnConfigurationRevision
        layoutContainer()
        table.reloadData()
        lastRowCount = numberOfRows(in: table)
        if let shift = headerShift {
            // Keep the same top data-row INDEX, not the same file record: at the
            // top this reveals the former header row (or absorbs data row 0),
            // and when scrolled only the header labels change.
            let target = preToggleTop
            let landed = min(target, max(0, dataRowCount - 1))
            scrollToTopLeft()        // reset the horizontal offset + baseline
            landOn(row: landed)      // re-anchor vertically to the same data row
            HeaderToggleProbe.toggled(oldTop: preToggleTop, newTop: landed,
                                      newHasHeader: model.dialect.hasHeader, shift: shift)
        } else if model.pendingScrollRow == nil {
            scrollToTopLeft()
        }
        refreshVisibleRows()
        applyPendingLanding()
        flushGridDisplay()
    }

    /// Returns true when the targeted repaint path fully handled the change, so
    /// the caller stops.
    private func applyConfigurationChanges() -> Bool {
        let configurationChanges = model.columnConfigurationChanges(after: lastColumnConfigurationRevision)
        guard configurationChanges.revision != lastColumnConfigurationRevision else { return false }
        lastColumnConfigurationRevision = configurationChanges.revision
        if canTargetConfiguration(hasColumns: configurationChanges.columns != nil),
           let columns = configurationChanges.columns {
            if model.columnWidthRevision != lastColumnWidthRevision {
                lastColumnWidthRevision = model.columnWidthRevision
                refreshConfiguredColumnWidths(columns)
                lastColumnWidths = model.columnWidths
            } else {
                refreshConfiguredColumns(columns)
            }
            flushGridDisplay()
            return true
        }
        refreshColumnWindow()
        header.needsDisplay = true
        return false
    }

    /// Whether the targeted repaint path applies — i.e. no structural, filter,
    /// row-count or scroll change is pending as well.
    private func canTargetConfiguration(hasColumns: Bool) -> Bool {
        hasColumns
            && model.columnPresentationRevision == lastColumnPresentationRevision
            && model.visibleColumns == lastVisibleColumns
            && model.isFiltered == lastIsFiltered
            && numberOfRows(in: table) == lastRowCount
            && model.pendingScrollRow == nil
    }

    /// A type, format or metadata change alters displayed text and alignment
    /// without touching the structural arrays, so only the bounded window is
    /// re-pulled.
    private func applyPresentationChanges() {
        if model.columnWidthRevision != lastColumnWidthRevision {
            lastColumnWidthRevision = model.columnWidthRevision
            lastColumnPresentationRevision = model.columnPresentationRevision
            refreshAfterWidthChange()
            lastColumnWidths = model.columnWidths
        } else if model.columnPresentationRevision != lastColumnPresentationRevision {
            lastColumnPresentationRevision = model.columnPresentationRevision
            refreshColumnWindow()
            header.needsDisplay = true
        }
    }

    /// A hidden-column reflow or width change needs a full reload. The clip
    /// origin is preserved across it: `layoutContainer` resets the scroll frame
    /// and `reloadData` can clamp the clip, which would desync the visual scroll
    /// from the model window mid-scroll.
    private func applyStructuralColumnChanges() {
        guard model.visibleColumns != lastVisibleColumns
            || model.columnWidths != lastColumnWidths else { return }
        lastVisibleColumns = model.visibleColumns
        lastColumnWidths = model.columnWidths
        let origin = scroll.contentView.bounds.origin
        refreshLayoutMetrics()
        layoutContainer()
        table.reloadData()
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        lastRowCount = numberOfRows(in: table)
    }

    /// Entering or clearing a filter switches the gutter between identity and
    /// original row numbers, which can change its width — so refresh now rather
    /// than at the next scroll.
    private func applyFilterToggle() {
        guard model.isFiltered != lastIsFiltered else { return }
        lastIsFiltered = model.isFiltered
        refreshLayoutMetrics()
        layoutContainer()
    }

    /// Schedules an apply OUTSIDE the model's mutation turn — the direct half of
    /// the landing bridge, guaranteeing one even if SwiftUI coalesces the
    /// representable update or the request arrived before window attachment.
    func scheduleLandingApply() {
        guard !landingApplyScheduled else { return }
        landingApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.landingApplyScheduled = false
            self.apply()
        }
    }

    func applyPendingLanding() {
        guard let target = model.pendingScrollRow else { return }
        model.pendingScrollRow = nil
        let row = Int(min(target, UInt64(Int.max)))
        landOn(row: row)
        ViewportLandingProbe.note(
            requestedRow: row,
            visibleRows: table.rows(in: table.visibleRect),
            offsetY: scroll.contentView.bounds.origin.y
        )
    }

}
