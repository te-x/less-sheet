import AppKit
import Contracts
import Foundation

// Headless verification of the sort slice (ARCH-sort-by-column AC-s14), in the
// family of JumpProbe / FilterRepaintProbe: it drives the REAL model entry
// points — the same `cycleSort` a header click runs and the same
// `cycleSortAtCursor` ⇧⌘S runs — with no synthetic input events, and prints what
// a human would otherwise have to watch for. Inert (zero cost) unless
// LESSSHEET_SORT is set.
//
//   LESSSHEET_SORT=<column>   Sort that column (default 0) after first paint.
//   LESSSHEET_SORT_CANCEL=1   Cancel the build immediately after applying it,
//                             and report the restored pre-sort order.
//   LESSSHEET_SORT_FIND=<t>   Submit a find WHILE the pass builds (the only way
//                             to park it: the find takes the single scan slot),
//                             then report per tick whether it parks, whether it
//                             resumes, and what becomes of the find.
//   LESSSHEET_SORT_SCROLL=<r> After the cycle, sort again and scroll to row <r>
//                             three times, reporting each window's cost and
//                             whether the loading state engaged.
//   LESSSHEET_SORT_FILTER=<t> After the cycle, sort again and then filter to <t>,
//                             which must REBUILD the pass and keep the view in
//                             sorted coordinates throughout (§9 rebuilds).
//
// What each line proves:
//   .immediate  — the FIRST synchronous read after the cycle is already in
//                 SORTED coordinates (the converging prefix), the phase is
//                 honest about the pass, and the controller applied the change
//                 in the same turn (the repaint poke — no scroll happened).
//   .tick       — the prefix REFINES and the grid repaints while BUILDING:
//                 the served top row and the controller's apply tick per poll.
//   .settled    — the terminal phase, the wall-clock to it, how many repaints it
//                 took, and the top of the landed sorted view.
//   .cycle      — the three-state cycle end to end through ⇧⌘S: ascending →
//                 descending (instant flip) → off (file order restored).
//   .cancel     — clearSort during a build puts the view back in file order.
@MainActor
enum SortProbe {
    private static let env = ProcessInfo.processInfo.environment
    static let active = env["LESSSHEET_SORT"] != nil

    private static var column: Int { Int(env["LESSSHEET_SORT"] ?? "") ?? 0 }
    private static var cancels: Bool { env["LESSSHEET_SORT_CANCEL"] != nil }
    /// `LESSSHEET_SORT_FILTER=<text>` adds the rebuild leg: filter to <text>
    /// while sorted, which must re-run the pass and keep serving sorted rows.
    private static var filterQuery: String { env["LESSSHEET_SORT_FILTER"] ?? "" }

    private static var started = false
    private static var startTime = DispatchTime.now()

    private static func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000)
    }

    static func run(model: DocumentModel) {
        guard active, !started else { return }
        started = true
        startTime = DispatchTime.now()
        guard model.columnCount > column else {
            log("lesssheet.sort.skip reason=no_such_column count=\(model.columnCount)")
            finish()
            return
        }
        logMenuItem()
        performWhenReady(model: model, triesLeft: 300)
    }

    /// Proves the ONE `SortCommand` declaration reached AppKit: the View menu's
    /// item, its key equivalent and its modifier mask, read back off the live
    /// main menu (so a hand-typed second copy would show up here).
    private static func logMenuItem() {
        let view = NSApp.mainMenu?.items.first { $0.submenu?.title == SortCommand.menuSection }
        guard let item = view?.submenu?.items.first(where: { $0.title == SortCommand.menuTitle }) else {
            log("lesssheet.sort.menu missing=\(SortCommand.menuSection)>\(SortCommand.menuTitle)")
            return
        }
        let mask = item.keyEquivalentModifierMask
        log("lesssheet.sort.menu title=\(item.title) key=\(item.keyEquivalent)"
            + " command=\(mask.contains(.command)) shift=\(mask.contains(.shift))"
            + " option=\(mask.contains(.option)) enabled=\(item.isEnabled)")
    }

    private static func performWhenReady(model: DocumentModel, triesLeft: Int) {
        guard NativeGridController.live?.container.window != nil || triesLeft <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                performWhenReady(model: model, triesLeft: triesLeft - 1)
            }
            return
        }
        let before = topSourceRows(model, 4)
        let tickBefore = NativeGridController.live?.applyTick ?? 0
        startTime = DispatchTime.now()

        // The real header-click path.
        model.cycleSort(column: column)

        // SAME synchronous turn: no await, no dispatch hop — so nothing but the
        // model's own poke can have repainted the grid.
        log("lesssheet.sort.immediate at_ms=\(elapsedMs()) phase=\(phase(model))"
            + " pre_sort_top=\(before) top=\(topSourceRows(model, 4))"
            + " rows_served=\(model.window.rows.count)"
            + " repaints=\((NativeGridController.live?.applyTick ?? 0) - tickBefore)"
            + " banner=\(model.sortBannerText ?? "-")")

        if let term = env["LESSSHEET_SORT_FIND"], !term.isEmpty {
            findDuringBuild(model: model, term: term, remaining: findLegTicks)
            return
        }
        if cancels {
            model.cancelSort()
            log("lesssheet.sort.cancel at_ms=\(elapsedMs()) phase=\(phase(model))"
                + " top=\(topSourceRows(model, 4)) banner=\(model.sortBannerText ?? "-")")
            finish()
            return
        }
        converge(model: model, tickBefore: tickBefore, ticks: 0)
    }

    /// One 50 ms sample per turn while the pass runs, so the log shows the prefix
    /// converging and the repaints that carried it.
    private static func converge(model: DocumentModel, tickBefore: Int, ticks: Int,
                                 then next: (() -> Void)? = nil) {
        guard model.sortIsWorking, elapsedMs() < 120_000 else {
            log("lesssheet.sort.settled at_ms=\(elapsedMs()) phase=\(phase(model))"
                + " top=\(topSourceRows(model, 4)) samples=\(ticks)"
                + " repaints=\((NativeGridController.live?.applyTick ?? 0) - tickBefore)"
                + " banner=\(model.sortBannerText ?? "-")")
            if let next { next() } else { cycleThroughDirections(model: model) }
            return
        }
        log("lesssheet.sort.tick at_ms=\(elapsedMs()) phase=\(phase(model))"
            + " progress=\(model.sortProgress.map { String(format: "%.3f", $0) } ?? "-")"
            + " top=\(topSourceRows(model, 4))"
            + " repaints=\((NativeGridController.live?.applyTick ?? 0) - tickBefore)"
            + " fetches=\(model.windowFetches) rows=\(model.window.rows.count)"
            + " beyond_prefix_rows=\(rowsServed(model, at: beyondPrefixRow))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            converge(model: model, tickBefore: tickBefore, ticks: ticks + 1, then: next)
        }
    }

    /// FR9/§9 rebuild: changing the row SET under an active sort re-runs the pass
    /// automatically, and the view must present the REBUILD's prefix at once
    /// rather than falling back to file order. Drives the real "Filter to
    /// matches" entry point and reads the sort in the SAME synchronous turn.
    private static func rebuildUnderFilter(model: DocumentModel) {
        model.openFindField()
        model.findSession.draft.mode = .text
        model.findSession.draft.text = filterQuery
        model.applyFindAsFilter()
        log("lesssheet.sort.rebuild at_ms=\(elapsedMs()) phase=\(phase(model))"
            + " filtered=\(model.isFiltered) rows=\(model.rowCountInfo.count)"
            + " top=\(topSourceRows(model, 4)) banner=\(model.sortBannerText ?? "-")")
        converge(model: model, tickBefore: NativeGridController.live?.applyTick ?? 0, ticks: 0,
                 then: { finish() })
    }

    /// The sorted-SCROLL leg (`LESSSHEET_SORT_SCROLL=<row>`): land on a far row
    /// twice and report what each window cost and whether the loading state
    /// engaged. On a slow source (a sorted `.csv.gz`) the first landing measures
    /// the cost and the second must show "Loading rows…" instead of freezing
    /// silently; on a fast local file neither does, which is also the point.
    private static func scrollLeg(model: DocumentModel, row: UInt64, remaining: Int) {
        guard remaining > 0 else { finish(); return }
        let target = row + UInt64((3 - remaining) * 1000)
        model.landViewport(on: target)
        log("lesssheet.sort.scroll at_ms=\(elapsedMs()) row=\(target)"
            + " fetch_ms=\(milliseconds(model.lastWindowFetch))"
            + " loading=\(model.windowLoading) rows=\(model.window.rows.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            scrollLeg(model: model, row: row, remaining: remaining - 1)
        }
    }

    /// The FIND-DURING-BUILD leg (`LESSSHEET_SORT_FIND=<term>`), the only way to
    /// reach `LS_SORT_PARKED`: a find takes the single scan slot from a pass that
    /// is not being driven (a network document, or MANUAL indexing), which parks
    /// it. Reports, once per 100 ms: the sort phase, the search phase, whether
    /// the app still shows a find, and how many times the pass has been
    /// re-driven — so "does it park", "does it resume", and "what happens to the
    /// find" are all answered by the same log.
    private static func findDuringBuild(model: DocumentModel, term: String, remaining: Int) {
        if remaining == Self.findLegTicks {
            model.submitFindQuery(term)
            log("lesssheet.sort.find_submitted term=\(term) at_ms=\(elapsedMs()) phase=\(phase(model))")
        }
        let progress: String = model.sortProgress.map { String(format: "%.3f", $0) } ?? "-"
        let matches = String(model.findSession.display.total)
        let findShown: Bool = model.findSession.display.request != nil
        var line = "lesssheet.sort.park_tick at_ms=\(elapsedMs()) sort=\(phase(model))"
        line += " progress=\(progress) search=\(searchPhase(model)) find_shown=\(findShown)"
        line += " matches=\(matches) redrives=\(model.sortRedrives)"
        line += " paused_for_find=\(model.sortIsPausedForFind) banner=\(model.sortBannerText ?? "-")"
        log(line)
        guard remaining > 0, model.sortSnapshot != nil else {
            // Drop the find and give the pass a few ticks to resume on its own.
            if model.findSession.display.request != nil {
                model.closeFind()
                model.findSession = model.findControl.invalidated(model.findSession)
                log("lesssheet.sort.find_dropped at_ms=\(elapsedMs()) sort=\(phase(model))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    findDuringBuild(model: model, term: term, remaining: -1)
                }
                return
            }
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            findDuringBuild(model: model, term: term, remaining: remaining - 1)
        }
    }

    /// How many 100 ms samples the find-during-build leg takes.
    private static let findLegTicks = 60

    private static func searchPhase(_ model: DocumentModel) -> String {
        guard let display = model.findSession.display.request else { return "none" }
        _ = display
        return model.findSession.display.progress != nil ? "scanning" : "settled"
    }

    /// Amendment 3's OTHER trigger: the header context menu. Builds the real
    /// items the header builds (same `sortMenuItems` the `menu(for:)` override
    /// calls) and reports their titles, check marks and enablement, then applies
    /// one entry through the shipping action path.
    private static func logHeaderMenu(model: DocumentModel, note: String) {
        guard let header = NativeGridController.live?.header else { return }
        // The REAL menu, then AppKit's own validation pass — reading the freshly
        // built items instead would report an enablement the user never sees
        // (NSMenu re-enables anything whose target responds, unless the menu
        // says otherwise).
        let menu = header.columnMenu(forColumn: column, offsetX: 0)
        menu.update()
        let described = menu.items.filter { !$0.isSeparatorItem && $0.title != "Configure Column…" }.map {
            "\($0.title)[checked=\($0.state == .on),enabled=\($0.isEnabled)]"
        }
        log("lesssheet.sort.menu_items when=\(note) column=\(column) at_ms=\(elapsedMs()) "
            + described.joined(separator: " | "))
    }

    /// The rest of the three-state cycle, driven through the ⇧⌘S entry point
    /// (the View-menu item calls exactly this), with the cursor parked on the
    /// sorted column so both entry points are proven to share one machine.
    private static func cycleThroughDirections(model: DocumentModel) {
        logHeaderMenu(model: model, note: "sorted_ascending")
        model.selectCell(row: 0, column: column)
        model.cycleSortAtCursor()
        log("lesssheet.sort.cycle step=descending at_ms=\(elapsedMs()) phase=\(phase(model))"
            + " top=\(topSourceRows(model, 4))")
        model.selectCell(row: 0, column: column)
        model.cycleSortAtCursor()
        log("lesssheet.sort.cycle step=off at_ms=\(elapsedMs()) phase=\(phase(model))"
            + " top=\(topSourceRows(model, 4))")
        logHeaderMenu(model: model, note: "cleared")
        // The context menu's own apply path: choose "Sort Descending" directly
        // (a DIRECT intent, not a cycle step) and report what the view did.
        let entries = model.sortMenu(for: column)
        if entries.count == 3 {
            model.applySortIntent(entries[1].intent)
            log("lesssheet.sort.menu_apply entry=\(entries[1].title) at_ms=\(elapsedMs())"
                + " phase=\(phase(model)) top=\(topSourceRows(model, 4))")
            model.applySortIntent(entries[2].intent)
            log("lesssheet.sort.menu_apply entry=\(entries[2].title) at_ms=\(elapsedMs())"
                + " phase=\(phase(model)) top=\(topSourceRows(model, 4))")
        }
        if let raw = env["LESSSHEET_SORT_SCROLL"], let row = UInt64(raw) {
            // Re-sort, then scroll inside the sorted view.
            model.cycleSort(column: column)
            converge(model: model, tickBefore: NativeGridController.live?.applyTick ?? 0, ticks: 0,
                     then: { scrollLeg(model: model, row: row, remaining: 3) })
            return
        }
        guard let query = env["LESSSHEET_SORT_FILTER"], !query.isEmpty else { finish(); return }
        // Re-sort, then change the row set under it.
        model.cycleSort(column: column)
        converge(model: model, tickBefore: NativeGridController.live?.applyTick ?? 0, ticks: 0,
                 then: { rebuildUnderFilter(model: model) })
    }

    /// A row well past the converging prefix's K (`LS_WINDOW_MAX_ROWS`), used to
    /// show that mid-build those rows are NOT servable — the grid's ordinary
    /// beyond-the-frontier presentation, never blank data passed off as content.
    private static let beyondPrefixRow: UInt64 = 8192

    /// How many rows the core serves for a 20-row window at `row` right now. The
    /// model re-issues its own window on the next poll tick, so this read is
    /// self-healing (and the whole probe is opt-in).
    private static func rowsServed(_ model: DocumentModel, at row: UInt64) -> Int {
        guard model.rowCountInfo.count > row else { return -1 }   // document too short to tell
        return model.session?.setWindow(firstRow: row, rowCount: 20).rows.count ?? -1
    }

    /// The gutter's ORIGINAL row numbers for the top `count` view rows — the
    /// cheapest honest witness of which coordinate space the view is in.
    private static func topSourceRows(_ model: DocumentModel, _ count: Int) -> String {
        (0..<count).map { model.gutterRow(forRow: $0).map(String.init) ?? "-" }.joined(separator: ",")
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private static func phase(_ model: DocumentModel) -> String {
        guard let snapshot = model.sortSnapshot else { return "idle" }
        switch snapshot.phase {
        case .building: return "building"
        case .parked: return "parked"
        case .active: return "active"
        case .failed: return "failed"
        }
    }

    private static func finish() {
        log("lesssheet.sort.done at_ms=\(elapsedMs())")
        if env["LESSSHEET_DUMP_EXIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
