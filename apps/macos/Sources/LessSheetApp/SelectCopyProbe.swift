import AppKit
import Contracts
import Foundation

// Verification-only instrumentation for the select-copy slice (ARCH-select-
// copy) — INERT unless LESSSHEET_SELECT_COPY is set, so it costs nothing in
// normal use and never touches the < 500 ms cold-start measurement (it starts
// only after the first data-bearing frame). Mirrors JumpProbe/FindProbe: drive
// the REAL model entry points a mouse/keyboard event would ultimately call
// (`DocumentModel.selectCell`/`extendSelection`/`selectWholeRow`/
// `selectWholeColumn`/`selectAll`/`copySelection`/`resizeWindowColumn`/
// `autoFitWindowColumn`) DIRECTLY — exactly like JumpProbe drives
// `submitJump` directly rather than synthesizing a click — so this proves the
// SAME model wiring a real interaction would exercise, with NO synthetic
// input events (no TCC prompt risk).
//
//   LESSSHEET_SELECT_COPY=1   Run the sequence below once, right after first
//     paint, then (under LESSSHEET_DUMP_EXIT) quit. Logs every step; a human
//     (or a follow-up automated check) compares the `copy_small` payload
//     against the known fixture content, and `copy_big`'s `max_gap_ms`
//     against the same < 100 ms no-stall bar NativeGridProbeTests pins for
//     landings.
@MainActor
enum SelectCopyProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_SELECT_COPY"] != nil

    private static var model: DocumentModel?
    private static var startTime = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var maxGapMs = 0

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    private static func describe(_ rect: SelectionRect?) -> String {
        guard let rect else { return "nil" }
        return "top=\(rect.top) bottom=\(rect.bottom) left=\(rect.left) right=\(rect.right)"
    }

    /// Called from the first data-bearing frame's task (after the cold-start
    /// marker). Runs the whole sequence synchronously against the model
    /// (each step is instant — index-space selection is O(1)); only the two
    /// copy steps are asynchronous, so those are driven from `Task`s below.
    static func run(model: DocumentModel) {
        guard active else { return }
        self.model = model
        startTime = DispatchTime.now()
        log("lesssheet.selectcopy.start columns=\(model.columnCount) rows=\(model.rowCountInfo.count)"
            + " exact=\(model.rowCountInfo.isExact)")
        guard model.columnCount > 0 else {
            log("lesssheet.selectcopy.skip reason=empty_document")
            finish()
            return
        }

        // AC1 — selection geometry, driven exactly as the mouse/keyboard
        // handlers in NativeGridController would call it.
        model.selectCell(row: 0, column: 0)
        log("lesssheet.selectcopy.select_cell rect=\(describe(model.selection?.rect))")

        let lastCol = model.columnCount - 1
        model.extendSelection(toRow: 2, column: min(2, lastCol))
        log("lesssheet.selectcopy.extend rect=\(describe(model.selection?.rect))")

        model.selectWholeRow(1)
        log("lesssheet.selectcopy.whole_row rect=\(describe(model.selection?.rect))")

        model.selectWholeColumn(0)
        log("lesssheet.selectcopy.whole_column rect=\(describe(model.selection?.rect))")

        model.selectAll()
        log("lesssheet.selectcopy.select_all rect=\(describe(model.selection?.rect))")

        // AC21 live-pass regressions: use the controller's event-free semantic
        // seam (the shipping mouse handlers call the same functions) to pin
        // click-again toggle behavior and prove selection repaint preserves
        // already-loaded row content instead of reconfiguring it as loading.
        selectionInteractionRegressions()

        // AC5 — column resize + auto-fit (O(1)/O(visible rows); no reload).
        let before = model.windowWidths().first ?? 0
        NativeGridController.live?.resizeColumn(windowIndex: 0, toWidth: 250)
        let afterResize = model.windowWidths().first ?? 0
        log("lesssheet.selectcopy.resize before=\(before) after=\(afterResize)")
        NativeGridController.live?.autoFitColumn(windowIndex: 0)
        let afterFit = model.windowWidths().first ?? 0
        log("lesssheet.selectcopy.autofit before=\(afterResize) after=\(afterFit)")

        // ARCH-select-copy round 2, finding 1 regression: a header click must
        // resolve the ABSOLUTE column under the cursor even when the grid is
        // scrolled horizontally — see the function's own comment for the bug.
        headerScrolledSelectRegression()

        // AC2/AC3 — a small, deterministic copy: rows 0-2, the first (up to 3)
        // columns — small enough to complete instantly, so its exact payload
        // (logged in full) is directly comparable against the fixture.
        let smallLastCol = min(2, lastCol)
        model.selectCell(row: 0, column: 0)
        model.extendSelection(toRow: 2, column: smallLastCol)

        // Visual verification (headless, no synthetic input): capture the
        // LIVE grid — same mechanism JumpProbe/HeaderToggleProbe use — with
        // this rect selected, so the accent-fill + range-border overlay
        // (`SheetRowView.draw`/`windowSelectionMarks`) is inspectable in a
        // PNG. Opt-in via the SAME LESSSHEET_DUMP_FRAME the rest of the app
        // uses; a no-op (and thus zero cost) when it is unset.
        if let path = env["LESSSHEET_DUMP_FRAME"] {
            NativeGridController.live?.apply()
            _ = FrameDump.captureLiveGrid(to: path)
            log("lesssheet.selectcopy.dumped path=\(path)")
        }

        runCopy(label: "copy_small") {
            driveBigCopyOrFinish()
        }
    }

    private static func selectionInteractionRegressions() {
        guard let model, let controller = NativeGridController.live else { return }
        let cell = GridCell(row: 0, column: 0)

        model.clearSelection()
        controller.cellMouseDown(cell, shift: false); controller.cellMouseUp(at: cell)
        controller.cellMouseDown(cell, shift: false); controller.cellMouseUp(at: cell)
        log("lesssheet.selectcopy.toggle_cell deselected=\(model.selection == nil)")

        controller.gutterMouseDown(atY: controller.table.rect(ofRow: 0).midY, shift: false)
        controller.gutterMouseDown(atY: controller.table.rect(ofRow: 0).midY, shift: false)
        log("lesssheet.selectcopy.toggle_row deselected=\(model.selection == nil)")

        guard !controller.widths.isEmpty else { return }
        let headerX = controller.columnFirstX + controller.widths[0] / 2
        controller.headerMouseDown(atX: headerX, shift: false)
        controller.headerMouseDown(atX: headerX, shift: false)
        log("lesssheet.selectcopy.toggle_column deselected=\(model.selection == nil)")

        var loadedRow: (row: Int, view: SheetRowView)?
        controller.table.enumerateAvailableRowViews { rowView, row in
            guard loadedRow == nil, row < controller.dataRowCount,
                  let view = rowView as? SheetRowView, !view.pending, !view.cells.isEmpty
            else { return }
            loadedRow = (row, view)
        }
        guard let loadedRow else {
            log("lesssheet.selectcopy.selection_repaint skip=no_loaded_row")
            return
        }
        let cellsBefore = loadedRow.view.cells
        let pendingBefore = loadedRow.view.pending
        let start = GridCell(row: UInt64(loadedRow.row), column: controller.absoluteColumns.first ?? 0)
        controller.cellMouseDown(start, shift: false)
        controller.cellMouseDragged(
            to: GridCell(row: start.row, column: min(start.column + 1, model.columnCount - 1)))
        controller.cellMouseUp(at: start)
        let pass = loadedRow.view.cells == cellsBefore && loadedRow.view.pending == pendingBefore
        log("lesssheet.selectcopy.selection_repaint content_preserved=\(pass)"
            + " pending_before=\(pendingBefore) pending_after=\(loadedRow.view.pending)")
    }

    /// FIX 1 regression guard (ARCH-select-copy round 2, finding 1): a header
    /// click must select the ABSOLUTE column under the cursor even when the
    /// grid is scrolled horizontally. `GridHeaderView.mouseDown` re-bases its
    /// own (descrolled) local click x into the controller's ABSOLUTE space
    /// before dispatching (`+ contentOffsetX`) — a prior version passed the
    /// raw local x straight through, which only ever matched the absolute
    /// space at zero horizontal scroll, so every header click resolved to
    /// the WINDOW'S FIRST column once scrolled. This proves the fix
    /// end-to-end: forces a REAL horizontal scroll (the SAME direct
    /// `clip.scroll(to:)` + `reflectScrolledClipView` technique
    /// `EstimateCollapseProbe` uses — no synthetic input event), then drives
    /// `GridHeaderView.handleClick(atLocalX:doubleClick:shift:)` — the SAME
    /// dispatch `mouseDown(with:)` performs, factored out so it is callable
    /// with a known LOCAL x — and asserts the resulting selection lands on
    /// the column actually under that x, not the window's first column (the
    /// bug's exact symptom). Skips (an honest log line, never a false
    /// failure) when the open document is not wide enough to scroll
    /// horizontally, or its column window never grows past one column — the
    /// regression needs a GENUINELY scrolled header with at least two window
    /// columns to tell the bug apart from the fix. Restores the scroll
    /// position afterward so nothing downstream (the small-copy dump) sees
    /// the grid scrolled away from its expected columns.
    private static func headerScrolledSelectRegression() {
        guard let model, let controller = NativeGridController.live else { return }
        let clip = controller.scroll.contentView
        let maxX = max(0, controller.table.frame.width - clip.bounds.width)
        guard maxX > 1 else {
            log("lesssheet.selectcopy.header_scrolled_select skip=not_wide_enough")
            return
        }
        let restoreX = clip.bounds.origin.x
        clip.scroll(to: NSPoint(x: maxX, y: clip.bounds.origin.y))
        controller.scroll.reflectScrolledClipView(clip)
        defer {
            clip.scroll(to: NSPoint(x: restoreX, y: clip.bounds.origin.y))
            controller.scroll.reflectScrolledClipView(clip)
        }

        guard controller.widths.count > 1, controller.header.contentOffsetX > 0 else {
            log("lesssheet.selectcopy.header_scrolled_select skip=window_too_narrow"
                + " widths=\(controller.widths.count) offset=\(controller.header.contentOffsetX)")
            return
        }

        // The window's LAST column — as far from index 0 as this scroll
        // gets, so the bug (always resolving to index 0) is unmistakable.
        let targetIndex = controller.widths.count - 1
        let columnStartX = controller.columnFirstX + controller.widths[0..<targetIndex].reduce(CGFloat(0), +)
        let midAbsoluteX = columnStartX + controller.widths[targetIndex] / 2
        let localX = midAbsoluteX - controller.header.contentOffsetX
        let expectedColumn = controller.absoluteColumns[targetIndex]

        model.selectCell(row: 0, column: 0)   // known baseline before the click
        controller.header.handleClick(atLocalX: localX, doubleClick: false, shift: false)
        let selectedColumn = model.selection?.rect.left
        let pass = selectedColumn == expectedColumn
        log("lesssheet.selectcopy.header_scrolled_select offset=\(controller.header.contentOffsetX)"
            + " local_x=\(localX) expected_column=\(expectedColumn)"
            + " selected_column=\(selectedColumn.map(String.init) ?? "nil") pass=\(pass)")

        // Shift-click whole-column EXTEND must land on the correct absolute
        // column too — it shares the identical (now-fixed) column
        // resolution, branching on `shift` only AFTER that lookup, but this
        // exercises it explicitly rather than assuming it from the plain
        // click above. Extends from the anchor set above (the window's LAST
        // column) back to the window's FIRST column, and checks the rect
        // spans exactly those two absolute columns.
        let extendColumn = controller.absoluteColumns[0]
        let extendLocalX = controller.columnFirstX + controller.widths[0] / 2 - controller.header.contentOffsetX
        controller.header.handleClick(atLocalX: extendLocalX, doubleClick: false, shift: true)
        let extendedRect = model.selection?.rect
        let expectedLeft = min(expectedColumn, extendColumn)
        let expectedRight = max(expectedColumn, extendColumn)
        let extendPass = extendedRect?.left == expectedLeft && extendedRect?.right == expectedRight
        log("lesssheet.selectcopy.header_scrolled_select_extend local_x=\(extendLocalX) column=\(extendColumn)"
            + " rect=\(describe(extendedRect)) expected_left=\(expectedLeft) expected_right=\(expectedRight)"
            + " pass=\(extendPass)")
    }

    /// AC4 — a copy spanning as much of the document as exists (capped so a
    /// modest fixture still exercises the SAME code path as a budget-filling
    /// one): a fast (16 ms) heartbeat runs alongside it, proving the main
    /// thread stays responsive for the whole build (mirrors LandingStallProbe).
    private static func driveBigCopyOrFinish() {
        guard let model, model.rowCountInfo.count > 3 else { finish(); return }
        let lastRow = min(model.rowCountInfo.count - 1, 4_000_000)
        let lastCol = model.columnCount - 1
        model.selectCell(row: 0, column: 0)
        model.extendSelection(toRow: lastRow, column: lastCol)
        maxGapMs = 0
        lastTick = DispatchTime.now()
        loggedInProgress = false
        startHeartbeat()
        runCopy(label: "copy_big") {
            heartbeat?.cancel(); heartbeat = nil
            log("lesssheet.selectcopy.copy_big_responsive max_gap_ms=\(maxGapMs)\(maxGapMs > 100 ? " OVER" : " OK")")
            finish()
        }
    }

    /// Triggers `copySelection()` (the SAME entry point Cmd+C calls) and
    /// polls `copyInFlight` for THIS copy's completion — not `copyNotice`
    /// alone, which can't tell "this" copy apart from a prior one that left
    /// an identical-looking notice. `copyInFlight` flips true SYNCHRONOUSLY
    /// inside `copySelection()` (before it returns) and back to false only
    /// once the off-main build + pasteboard write finish, so polling it is
    /// race-free with no busy loop on the main actor.
    private static func runCopy(label: String, then next: @escaping () -> Void) {
        guard let model else { next(); return }
        let rectBefore = model.selection?.rect
        model.copySelection()
        guard model.copyInFlight else {
            log("lesssheet.selectcopy.\(label)_not_started")   // guard rejected (no selection/session)
            next()
            return
        }
        pollForCompletion(label: label, rect: rectBefore, triesLeft: 4000, then: next)
    }

    private static var loggedInProgress = false

    private static func pollForCompletion(
        label: String, rect: SelectionRect?, triesLeft: Int, then next: @escaping () -> Void
    ) {
        guard let model else { next(); return }
        if model.copyInFlight, model.copyNotice == "Copying…", !loggedInProgress {
            loggedInProgress = true
            log("lesssheet.selectcopy.\(label)_in_progress notice=\"Copying…\" at_ms=\(elapsedMs())")
        }
        if !model.copyInFlight {
            let pasteboard = NSPasteboard.general
            let tabular = pasteboard.string(forType: .tabularText) ?? "<nil>"
            let plain = pasteboard.string(forType: .string) ?? "<nil>"
            log("lesssheet.selectcopy.\(label) rect=\(describe(rect)) notice=\"\(model.copyNotice ?? "<nil>")\""
                + " tabular_matches_plain=\(tabular == plain) bytes=\(plain.utf8.count) at_ms=\(elapsedMs())")
            log("lesssheet.selectcopy.\(label)_payload text=\"\(escaped(plain))\"")
            next()
            return
        }
        guard triesLeft > 0 else {
            log("lesssheet.selectcopy.\(label)_timeout")
            next()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            pollForCompletion(label: label, rect: rect, triesLeft: triesLeft - 1, then: next)
        }
    }

    private static func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let now = DispatchTime.now()
                let gap = Int((now.uptimeNanoseconds &- lastTick.uptimeNanoseconds) / 1_000_000)
                lastTick = now
                maxGapMs = max(maxGapMs, gap)
            }
        }
    }

    private static func finish() {
        log("lesssheet.selectcopy.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    /// Escapes newlines/tabs/quotes so one payload prints on one log line,
    /// unambiguously (the whole point is a human/diff can read it exactly).
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
