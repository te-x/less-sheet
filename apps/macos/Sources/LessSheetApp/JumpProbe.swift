import AppKit
import Foundation

// Verification-only instrumentation for the jump-to-row path — INERT unless the
// matching environment variable is set, so it costs nothing in normal use and
// can never touch the < 500 ms cold-start measurement (it starts only after the
// first data-bearing frame).
//
//   LESSSHEET_JUMP=<row>[,<row>…]  Drive the REAL UI jump path (identical to
//     typing the row + Enter in the popup) once per target, in sequence, right
//     after first paint. For each target it logs submit / scanning-shown /
//     progress, and its terminal state — LANDED (exact) or REJECTED (target
//     past the last row, or invalid). A 250 ms MAIN-ACTOR heartbeat logs its
//     inter-tick gap every tick (any gap > 500 ms = the main thread stalled).
//     After a REJECT it advances to the next target (proving the UI still works
//     — a follow-up jump lands); the LAST target's terminal state is dumped
//     (arrival grid, or the red rejected field) and, under LESSSHEET_DUMP_EXIT,
//     the headless instance quits.
//
//   LESSSHEET_LOG_OFFSET           Log the grid's scroll content offset / top
//     content inset when they change (proves (0,0) open + row-1-below-titlebar).

@MainActor
enum JumpProbe {
    private static let env = ProcessInfo.processInfo.environment
    private static let targets: [String] =
        (env["LESSSHEET_JUMP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

    /// True when the hook is armed with at least one target.
    static let active: Bool = !targets.isEmpty

    private static var index = 0
    private static var model: DocumentModel?
    private static var startTime = DispatchTime.now()
    private static var lastTick = DispatchTime.now()
    private static var heartbeat: Task<Void, Never>?
    private static var scanningLogged = false
    private static var lastPct = -1
    private static var maxGapMs = 0

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    /// Called from the first data-bearing frame's task (after the cold-start
    /// marker): start the heartbeat and submit the first target.
    static func run(model: DocumentModel) {
        guard active else { return }
        self.model = model
        startTime = DispatchTime.now()
        lastTick = startTime
        index = 0
        maxGapMs = 0
        startHeartbeat()
        submitCurrent()
    }

    private static func submitCurrent() {
        guard let model, index < targets.count else { return }
        scanningLogged = false
        lastPct = -1
        log("lesssheet.jump.submit seq=\(index) target_1based=\(targets[index]) at_ms=\(elapsedMs())"
            + " known_total=\(model.rowCountInfo.count) exact=\(model.rowCountInfo.isExact)")
        _ = model.submitJump(targets[index])   // identical to typing <target> + Enter
    }

    private static func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                let now = DispatchTime.now()
                let gap = Int((now.uptimeNanoseconds &- lastTick.uptimeNanoseconds) / 1_000_000)
                lastTick = now
                maxGapMs = max(maxGapMs, gap)
                log("lesssheet.heartbeat.gap_ms=\(gap) at_ms=\(elapsedMs())\(gap > 500 ? " STALL" : "")")
                if elapsedMs() > 90_000 {   // never leave a headless run hanging
                    log("lesssheet.jump.timeout_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
                    quit(); return
                }
            }
        }
    }

    /// Folded scan progress (0…1); logged only when the integer percent changes.
    static func noteProgress(_ progress: Double) {
        guard active else { return }
        let pct = Int((max(0, min(1, progress)) * 100).rounded())
        guard pct != lastPct else { return }
        lastPct = pct
        log("lesssheet.jump.progress=\(pct) at_ms=\(elapsedMs())")
    }

    /// The scanning popup state reached the view layer (main-actor render proof).
    static func noteScanningShown() {
        guard active, !scanningLogged else { return }
        scanningLogged = true
        log("lesssheet.jump.scanning_shown_ms=\(elapsedMs())")
    }

    /// The rejected field rendered (main-actor render proof).
    static func noteRejectionShown() {
        guard active else { return }
        log("lesssheet.jump.rejected_shown_ms=\(elapsedMs())")
    }

    /// Terminal state: the jump landed exactly on the requested row.
    static func arrived(model: DocumentModel, landed row: UInt64) {
        guard active, index < targets.count else { return }
        log("lesssheet.jump.landed seq=\(index) landed_row_0based=\(row) gutter_1based=\(row &+ 1)"
            + " at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        advance(finalDump: .arrival)
    }

    /// Terminal state: the jump was rejected (past the last row, or invalid).
    static func rejected(model: DocumentModel, scanned: Bool, restoredTo: UInt64?) {
        guard active, index < targets.count else { return }
        let restore = restoredTo.map { String($0) } ?? "unchanged"
        log("lesssheet.jump.rejected seq=\(index) scanned=\(scanned) viewport_restored_to_firstRow=\(restore)"
            + " exact_total=\(model.rowCountInfo.count) exact=\(model.rowCountInfo.isExact)"
            + " at_ms=\(elapsedMs()) max_gap_ms=\(maxGapMs)")
        advance(finalDump: .reject)
    }

    private enum FinalDump { case arrival, reject }

    private static func advance(finalDump: FinalDump) {
        index += 1
        if index < targets.count {
            // Prove the UI is still functional after a reject/land: submit the
            // next target on a later tick (lets the current update settle).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { submitCurrent() }
            return
        }
        if let model {
            switch finalDump {
            case .arrival: FrameDump.dumpArrival(for: model)
            case .reject: FrameDump.dumpReject(for: model)
            }
        }
        heartbeat?.cancel(); heartbeat = nil
        if env["LESSSHEET_DUMP_EXIT"] != nil { quit() }
    }

    private static func quit() {
        // Let stderr / the PNG flush before terminating the headless instance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

// Diagnostic: report the grid's scroll content offset when it changes. Inert
// unless LESSSHEET_LOG_OFFSET is set. Used to verify the grid opens at (0,0)
// (item 2) without any screen capture.
@MainActor
enum ScrollProbe {
    static let enabled = ProcessInfo.processInfo.environment["LESSSHEET_LOG_OFFSET"] != nil
    /// Live window-space frame logging for the pinned header / row 1 / scroll
    /// view (item 1 overlap diagnosis). Inert unless LESSSHEET_LOG_LAYOUT is set.
    static let layoutEnabled = ProcessInfo.processInfo.environment["LESSSHEET_LOG_LAYOUT"] != nil
    private static var last: CGPoint?
    private static let start = DispatchTime.now()

    static func noteFrame(_ label: String, _ rect: CGRect) {
        guard layoutEnabled else { return }
        let milliseconds = Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
        FileHandle.standardError.write(Data(String(
            format: "lesssheet.layout.\(label) minY=%.1f maxY=%.1f minX=%.1f height=%.1f at_ms=%d\n",
            rect.minY, rect.maxY, rect.minX, rect.height, milliseconds).utf8))
    }

    static func note(_ offset: CGPoint) {
        guard enabled else { return }
        if let previous = last, abs(previous.x - offset.x) < 0.5, abs(previous.y - offset.y) < 0.5 { return }
        last = offset
        FileHandle.standardError.write(
            Data(String(format: "lesssheet.scroll.offset x=%.1f y=%.1f\n", offset.x, offset.y).utf8)
        )
    }

    static func noteInsets(top: CGFloat, label: String) {
        guard enabled else { return }
        FileHandle.standardError.write(
            Data(String(format: "lesssheet.\(label).top=%.1f\n", top).utf8)
        )
    }
}

/// Viewport-level landing evidence for headless native-grid probes. Unlike the
/// existing jump/find logs (which prove the model resolved a target), this is
/// emitted only after the shipping NSClipView has been scrolled. Inert unless
/// a jump, find, or landing-stall probe is armed.
@MainActor
enum ViewportLandingProbe {
    static func note(requestedRow: Int, visibleRows: NSRange, offsetY: CGFloat) {
        guard JumpProbe.active || FindProbe.active || LandingStallProbe.active else { return }
        let visible = visibleRows.length > 0
            && requestedRow >= visibleRows.location
            && requestedRow < visibleRows.location + visibleRows.length
        FileHandle.standardError.write(Data(String(
            format: "lesssheet.viewport.landed requested_row_0based=%d visible_first=%d visible_count=%d"
                + " offset_y=%.1f target_visible=\(visible)\n",
            requestedRow, visibleRows.location, visibleRows.length, offsetY
        ).utf8))
    }
}

// Diagnostic: report the grid's column-width geometry — the visible data
// columns' summed width, the clip/viewport width, the scroll view's own frame
// width, the NSTableView documentView's frame width, the single table
// column's width, the synthetic filler-column count, and whether the LIVE
// horizontal scroller widget is actually hidden right now — so "does the data
// fit without a horizontal scroller" is a MEASUREMENT (total/docwidth/colwidth
// <= viewport, AND hscroller_hidden=true) rather than an eyeball, whether the
// cause is a giant-row cell that must not have pushed a column past the
// viewport, or a STALE width read (e.g. `scroll.contentView.bounds` not yet
// settled to a just-set `scroll.frame`, or `documentView`/`column.width`
// disagreeing with the clip) that left AppKit's OWN scroller-needed
// determination stuck showing one even after the widths agree again.
// `site` distinguishes WHERE in the layout/scroll cycle the reading was taken
// (e.g. "layout" — inside `layoutContainer`'s `refreshColumnWidth`, right
// after `scroll.frame` is (re)set — vs "scroll" — from a live
// `clipBoundsChanged`, once AppKit has actually settled the clip/scroller
// geometry): the two can legitimately differ for one tick if a width read is
// stale (this is exactly how the giant-file "spurious horizontal scroller
// on short columns" bug was pinned down: a "layout" reading whose `viewport`
// hadn't yet accounted for a vertical scroller about to insert itself, vs the
// next "scroll" reading with the settled, narrower one). Inert unless
// LESSSHEET_LOG_COLWIDTH is set.
@MainActor
enum ColWidthProbe {
    static let enabled = ProcessInfo.processInfo.environment["LESSSHEET_LOG_COLWIDTH"] != nil

    /// One column-width layout sample, bundled so `log` stays within the
    /// parameter-count budget (the fields are unchanged).
    struct Sample {
        let site: String
        let total: CGFloat
        let viewport: CGFloat
        let scrollFrame: CGFloat
        let documentWidth: CGFloat
        let columnWidth: CGFloat
        let filler: Int
        let hScrollerHidden: Bool
    }

    static func log(_ sample: Sample) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(String(
            format: "lesssheet.colwidth site=\(sample.site) total=%.1f viewport=%.1f scrollframe=%.1f"
                + " docwidth=%.1f colwidth=%.1f filler=%d hscroller_hidden=\(sample.hScrollerHidden)\n",
            sample.total, sample.viewport, sample.scrollFrame,
            sample.documentWidth, sample.columnWidth, sample.filler
        ).utf8))
    }
}

// Verification-only: prove the header toggle PRESERVES the viewport position
// (keeps the same physical/file record at the data-area top across the on/off
// re-derivation, NOT scrolling to row 0 and NOT drifting by the ±1 header
// shift). INERT unless the env var is set — starts only after first paint, so it
// never touches the cold-start measurement.
//
//   LESSSHEET_HEADER_TOGGLE=<row_1based>  Park the viewport at that row (a real
//     jump — genuine scroll), then toggle the header exactly as clicking the H
//     button does, and log the top DATA row + the file record it maps to, both
//     BEFORE and AFTER. Under LESSSHEET_DUMP_EXIT the headless instance quits
//     once the toggle re-anchors.
@MainActor
enum HeaderToggleProbe {
    private static let env = ProcessInfo.processInfo.environment
    /// 1-based row to park the viewport at before toggling.
    static let park: Int? = env["LESSSHEET_HEADER_TOGGLE"].flatMap(Int.init)
    static var active: Bool { park != nil }

    private static var started = false
    private static var model: DocumentModel?

    /// Called from the first data-bearing frame's task (after the cold-start
    /// marker). Idempotent: the toggle re-opens (bumping the open generation, which
    /// re-fires that task), so re-entry must be a no-op.
    static func run(model: DocumentModel) {
        guard active, !started, let park, park >= 1 else { return }
        started = true
        self.model = model
        // 1) Park the viewport at `park` via the real jump path (a genuine scroll).
        _ = model.submitJump(String(park))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let model = self.model else { return }
            // Headless windows get no implicit updateNSView, so drive the grid the
            // way the jump verification does (FrameDump.captureLiveGrid) — flush the
            // landing so the clip is really parked at `park`.
            NativeGridController.live?.apply()
            log("lesssheet.header_toggle.parked target_1based=\(park) has_header=\(model.dialect.hasHeader)")
            // 2) Toggle the header exactly as clicking the H button does.
            let generation = model.openGeneration
            _ = model.applyDialectChange(.header(!model.dialect.hasHeader))
            // 3) Once the async re-open bumps the generation, drive the grid's
            //    re-anchor (its openGeneration branch reads the still-parked clip and
            //    re-lands on the same file record, logging before/after via toggled()).
            driveReanchor(afterGeneration: generation, triesLeft: 80)
        }
    }

    /// Poll for the header-toggle re-open to complete, then invoke the live grid's
    /// update so its openGeneration branch runs (headless has no implicit one).
    private static func driveReanchor(afterGeneration generation: Int, triesLeft: Int) {
        guard let model else { return }
        if model.openGeneration != generation {
            NativeGridController.live?.apply()
            return
        }
        guard triesLeft > 0 else {
            log("lesssheet.header_toggle.error reopen_not_observed")
            if env["LESSSHEET_DUMP_EXIT"] != nil { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            driveReanchor(afterGeneration: generation, triesLeft: triesLeft - 1)
        }
    }

    /// Logged by the grid once it re-anchors the viewport after the toggle re-open:
    /// the exact top DATA row before/after and the file record each maps to
    /// (file_record = data-row index + 1 when a header is present, else the index).
    /// `same_record=true` + `landed_at_zero=false` is the proof.
    static func toggled(oldTop: Int, newTop: Int, newHasHeader: Bool, shift: Int) {
        guard active else { return }
        let oldHasHeader = shift == 0 ? newHasHeader : (shift > 0)  // +1 = turned OFF; −1 = turned ON
        let recordBefore = oldTop + (oldHasHeader ? 1 : 0)
        let recordAfter = newTop + (newHasHeader ? 1 : 0)
        log("lesssheet.header_toggle.before top_data_0based=\(oldTop) "
            + "file_record=\(recordBefore) has_header=\(oldHasHeader)")
        log("lesssheet.header_toggle.after top_data_0based=\(newTop) "
            + "file_record=\(recordAfter) has_header=\(newHasHeader) "
            + "same_record=\(recordAfter == recordBefore) "
            + "data_index_delta=\(newTop - oldTop) landed_at_zero=\(newTop == 0)")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
