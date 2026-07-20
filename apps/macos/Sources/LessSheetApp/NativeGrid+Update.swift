// The model -> AppKit funnel (apply) + column-window/metric sync.
import AppKit
import Contracts
import SwiftUI

extension NativeGridController {
    // MARK: Model -> AppKit

    /// Pull the STRUCTURAL geometry from the model: the row-number gutter
    /// width and the total content width (`model.totalVisibleWidth`, O(visible
    /// columns)). Run only on a structural change — build / open / hidden-
    /// column reflow / filter toggle / a width-batch change — NEVER per
    /// scroll tick (ARCH-column-windowing); see `refreshColumnWindow` for the
    /// O(window) counterpart that IS safe on every tick.
    func refreshLayoutMetrics() {
        gutterWidth = model.rowNumberColumnWidth()
        totalDataWidth = model.totalVisibleWidth
    }

    /// (Re)derives the horizontal column window from the CURRENT scroll clip
    /// (x-offset + viewport width) and pulls the window-bound widths/labels
    /// the row/header views draw — the horizontal analog of `viewportChanged`'s
    /// row window (ARCH-column-windowing). `model.horizontalViewportChanged`
    /// is O(visible columns) of plain arithmetic (never O(columns) of text
    /// layout) and a no-op once the window settles, so this is cheap enough
    /// to call on EVERY layout pass and scroll tick — unlike
    /// `refreshLayoutMetrics`, which stays gated to structural changes.
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
        // The header's resize hit-zones (ARCH-select-copy AC5) sit at fixed
        // OFFSETS from this same geometry — AppKit does not re-derive cursor
        // rects on a mere content-offset/width change (only on a frame change
        // or an explicit invalidate), so poke it here alongside every place
        // that already marks the header for a repaint.
        container.window?.invalidateCursorRects(for: header)
    }

    /// The single funnel for model-driven grid updates (idempotent). Called from
    /// `updateNSView` whenever `GridView.body` re-runs (any tracked model fact
    /// changed). Detects what changed and does the minimum AppKit work — all
    /// O(viewport)/O(1).
    func apply() {
        guard built, container.window != nil else { return }
        applyTick &+= 1

        // Re-open / dialect re-open: columns + widths reset; reload from the top.
        if model.openGeneration != lastOpenGeneration {
            applyReopen()
            return
        }
        if applyConfigurationChanges() { return }
        applyPresentationChanges()
        applyStructuralColumnChanges()
        applyFilterToggle()

        // Row-count estimate refined (grows/shrinks toward exact as the index
        // advances): keep the scrollbar in sync — deferred while the clip is
        // mid an elastic overscroll bounce (see `syncRowCountEstimate` below).
        syncRowCountEstimate()

        // Data filled in (window paged) or highlights changed: redraw visibles.
        refreshVisibleRows()

        // A pending landing (jump / find / wrap / cancel restore): O(viewport).
        applyPendingLanding()

        // Flush any config/visibility-driven repaint to screen NOW (see
        // `flushGridDisplay`): an edit made from the separate, key Settings
        // window otherwise only marks this window's rows/header needsDisplay,
        // and AppKit defers that draw until this window next handles an event
        // (the reported "changes only appear on click").
        flushGridDisplay()
    }

    /// Re-open / dialect re-open: columns + widths reset; reload from the top,
    /// preserving the viewport across a header on/off toggle by DATA-ROW INDEX.
    private func applyReopen() {
        // A header on/off toggle keeps its place instead of flashing to row 0:
        // capture the EXACT top data row from the current (pre-reload) scroll
        // BEFORE anything resets it, then re-land on the SAME data-row index
        // (O(viewport) — the anchor row is at/near the already-scanned frontier,
        // so there is no scan and no stall).
        let headerShift = model.consumePendingHeaderShift()
        let preToggleTop = headerShift != nil ? currentTopDataRow() : 0

        lastOpenGeneration = model.openGeneration
        // New document identity: the previous document's fit-viewport identity
        // is meaningless here (a matching row/x/width must not suppress the new
        // document's first fit), so re-arm it.
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
            // Preserve the viewport by DATA-ROW INDEX (no ±1 record shift): keep
            // the same top data row across the re-open. At the very top this is
            // data row 0 — so a header→data toggle REVEALS the former-header row
            // there, and a data→header toggle shows the new data row 0. When
            // scrolled, the top data-row index is left unchanged and only the
            // header labels re-render (values ↔ A/B/C). Clamp to the (possibly
            // ±1) new data range.
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

    /// React to a column-configuration revision bump. Returns true when it fully
    /// handled the change via the targeted repaint path (caller should stop).
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

    /// Whether a configuration change can take the O(window) targeted repaint
    /// path instead of a full reload (no structural/filter/row-count/scroll
    /// change is also pending).
    private func canTargetConfiguration(hasColumns: Bool) -> Bool {
        hasColumns
            && model.columnPresentationRevision == lastColumnPresentationRevision
            && model.visibleColumns == lastVisibleColumns
            && model.isFiltered == lastIsFiltered
            && numberOfRows(in: table) == lastRowCount
            && model.pendingScrollRow == nil
    }

    /// Type/format/metadata changes can alter displayed text/alignment without
    /// changing structural arrays. Re-pull only the bounded horizontal window. A
    /// panel width edit additionally refreshes the document extent through the
    /// existing targeted width path.
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

    /// Hidden-column reflow / width change: recompute strip + reload. Preserve
    /// the scroll clip origin across it — layoutContainer resets scroll.frame and
    /// reloadData can clamp the clip, which would desync the visual scroll
    /// (gutter) from the model window (cells) mid-scroll, e.g. when columns grow
    /// to fit content while paging. (Same guard the estimate branch uses.)
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

    /// Filter mode toggled (entered/cleared): the gutter switches between
    /// identity and original row numbers and may need to widen/narrow for the
    /// captured document row count (ARCH criterion 13) — refresh its metrics
    /// right away rather than waiting for the next scroll.
    private func applyFilterToggle() {
        guard model.isFiltered != lastIsFiltered else { return }
        lastIsFiltered = model.isFiltered
        refreshLayoutMetrics()
        layoutContainer()
    }

    /// Schedule outside the model mutation turn. This is the direct half of
    /// the landing bridge; the observed `pendingScrollRow` remains a safety
    /// net, while this guarantees an AppKit apply even if SwiftUI coalesces the
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
