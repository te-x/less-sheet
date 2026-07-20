import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — the streaming TSV copy (ARCH-select-copy AC2-4; ARCH-thin-
// frontend-shared-core Phase 2): snapshot the selection, pre-advance the
// frontier, stream core-framed TSV off-main, write the pasteboard + notice.
// Pure code motion out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    /// ⌘C: snapshot the LIVE selection rect and build the TSV payload OFF
    /// the main thread (`Task.detached`) via the core's streaming copy, then
    /// write the pasteboard and show a brief notice back on the main actor. A
    /// no-op with nothing selected or no open session. A copy already running
    /// is CANCELLED first (`cancelCopy`) rather than ignored (finding 2): the
    /// new selection snapshot supersedes the old one.
    ///
    /// Before streaming, gives the background index a bounded chance to
    /// advance the scan frontier to the selection's bottom row
    /// (`advanceFrontier`, finding 3): without this, a selection made soon
    /// after opening a large file streams only up to the frontier and reports
    /// `.stoppedAtFrontier` even though the rest of the rows exist.
    ///
    /// PERFORMANCE (ARCH-thin-frontend-shared-core Phase 2): the copy STREAMS
    /// core-framed TSV via `openCopy` → `next` (`streamCopy` below) instead of
    /// the deleted `TSVCopyBuilder`'s per-cell `ls_cell_copy` loop, riding the
    /// O(1) forward copy cursor. It stays window-INDEPENDENT (AC4) and off-main.
    /// The "Copying…" affordance + Cancel remain (a huge selection can still
    /// take real time; the stream is cancellable per pull — see `cancelCopy`).
    func copySelection() {
        guard let session, let rect = selection?.rect else { return }
        cancelCopy()   // supersede any copy already running (see doc above)
        copyInFlight = true
        // ARCH-stream-copy AC8 ("subtle progress after ~500 ms ... with the
        // existing cancel ... gone on completion/cancel; a sub-threshold copy
        // shows nothing"): the SAME shared gate every long op in this model
        // drives. A real `ContinuousClock` reading taken now is the copy's
        // start; the driver feeds the real elapsed since then into the gate at
        // the threshold tick, so the ~500 ms band is the ONE the whole app
        // shares, not a private magic number.
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
        let budget = CopyBudget.standard
        copyTask = Task.detached { [weak self] in
            // Pre-advance the scan frontier over the whole selection so the
            // stream below rarely STALLS — and this pre-pass is the common,
            // cancellable spot a cancel lands on a lagging index (finding 3).
            await Self.advanceFrontier(session: session, to: rect.bottom)
            guard !Task.isCancelled else { return }
            let report = await Self.streamCopy(session: session, rect: rect, budget: budget)
            guard !Task.isCancelled else { return }
            await self?.completeCopy(report)
        }
    }

    /// Per-pull chunk size for the streaming copy — a tunable; the payload total
    /// is bounded by the byte budget + the core's cell cap, never by this.
    /// `nonisolated` so the off-main `streamCopy` (also nonisolated) can read it.
    nonisolated private static let copyChunkBytes = 1 << 16   // 64 KiB

    /// Streams the CORE-FRAMED TSV copy of `rect` off the main thread
    /// (ARCH-thin-frontend-shared-core Phase 2): drives `DocumentSession.openCopy`
    /// → `next` / `close`, appending each chunk to a growing blob, advancing the
    /// frontier on `.stalled` then resuming, and stopping at the frontend byte
    /// budget. The core owns the framing AND the cell-count safety cap, so this
    /// holds NO TSV logic. Cancellable: checked each pull, and `close()` runs in
    /// a `defer`. Produces the SAME `CopyReport` shape `completeCopy` consumes.
    ///
    /// `nonisolated` so it runs on the caller's `Task.detached` executor, OFF the
    /// main actor (AC4). `internal` (not `private`) so `StreamCopyOutcomeProbe`
    /// can drive it headlessly with a fake session to gate-lock the outcomes.
    nonisolated static func streamCopy(
        session: any DocumentSession, rect: SelectionRect, budget: CopyBudget
    ) async -> CopyReport {
        guard let job = session.openCopy(rect) else {
            return CopyReport(text: "", byteCount: 0, rowCount: 0, outcome: .complete, lossyCells: false)
        }
        defer { job.close() }
        var blob: [UInt8] = []
        var rowsDone: UInt64 = 0
        var outcome: CopyOutcome = .complete
        // FINDING 1 no-progress guard: the LAST view row we asked startJump to
        // advance the frontier over. A STALLED that reports the SAME row again
        // means the jump made no progress (a filtered mis-target).
        var lastStalledRow: UInt64?
        pull: while true {
            if Task.isCancelled { break }
            let step = job.next(maxChunkBytes: copyChunkBytes)
            rowsDone = step.rowsDone
            blob.append(contentsOf: step.bytes)
            switch step.kind {
            case .more:
                // BYTE BUDGET (frontend cap, ~64 MiB): stop pulling once the blob
                // reaches it — mirrors the deleted builder's `.stoppedAtBudget`
                // (the core's own ceiling is cell-count, reported on `.done`).
                if blob.count >= budget.maxTotalBytes {
                    outcome = .stoppedAtBudget
                    break pull
                }
            case .stalled:
                // FINDING 1 (filtered STALLED): the core's `stalledRow` is a VIEW
                // (filtered) index, but startJump(to:) targets an ORIGINAL data
                // row while a filter is active (api/lesssheet.h "JUMP under a
                // filter"), so under a filter the jump can't advance the frontier
                // over the stalled view row and returns DONE without progress. If
                // the SAME stalledRow recurs after a jump, stop cleanly at the
                // frontier instead of re-jumping it forever. The IDENTITY view
                // never trips this: a real advance makes the next stall a
                // strictly-later row (view row == original row there).
                if step.stalledRow == lastStalledRow {
                    outcome = .stoppedAtFrontier
                    break pull
                }
                lastStalledRow = step.stalledRow
                if await awaitFrontierAdvance(session: session, to: step.stalledRow) { continue }
                if Task.isCancelled { break pull }
                outcome = .stoppedAtFrontier   // frontier could not advance in time
                break pull
            case .done:
                outcome = step.budgetCapped ? .stoppedAtCellCap : .complete
                break pull
            }
        }
        let text = String(bytes: blob, encoding: .utf8) ?? ""
        return CopyReport(text: text, byteCount: blob.count, rowCount: rowsDone, outcome: outcome, lossyCells: false)
    }

    /// Advances the core's scan frontier over the STALLED view row `row` by
    /// reusing `startJump`/`jumpStatus`, ALWAYS yielding at least once FIRST
    /// (the back-off) so an immediately-DONE jump can never let the caller
    /// busy-spin. Returns true once the jump settles `.done`, false on a timeout
    /// OR cancellation (the caller distinguishes the two via `Task.isCancelled`).
    /// Extracted from `streamCopy`'s `.stalled` case to keep it under the
    /// cyclomatic-complexity bar; behavior is identical.
    nonisolated private static func awaitFrontierAdvance(session: any DocumentSession, to row: UInt64) async -> Bool {
        session.startJump(to: row)
        for _ in 0..<frontierPollMaxTicks {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: frontierPollInterval)
            if case .done = session.jumpStatus() { return true }
        }
        return false
    }

    /// How long `advanceFrontier` waits for AUTO indexing to reach the
    /// selection's bottom row before giving up and building anyway — bounded
    /// so a copy can never hang on an arbitrarily slow scan. One poll every
    /// `frontierPollInterval`, up to `frontierPollMaxTicks` times.
    /// `nonisolated` so the off-main `streamCopy` / `advanceFrontier` can read them.
    nonisolated private static let frontierPollInterval: Duration = .milliseconds(50)
    nonisolated private static let frontierPollMaxTicks = 40   // ~2 s total

    /// Pre-advances the core's scan frontier toward `target` (ARCH-select-
    /// copy round 2, finding 3) by reusing the SAME jump-scan primitives a
    /// real Jump-to-row uses (`DocumentSession.startJump`/`jumpStatus`) — but
    /// deliberately bypasses `beginJump`/`jumpFlow`/the viewport, so this is
    /// invisible to the user (no jump popup, no scroll) while still unlocking
    /// rows for the copy that follows. Returns as soon as the target is behind
    /// the frontier or after `frontierPollMaxTicks` polls, whichever comes
    /// first; cancellable (checked every tick).
    nonisolated private static func advanceFrontier(session: any DocumentSession, to target: UInt64) async {
        // FINDING 1: `target` (the selection's bottom) is a VIEW row. Under a
        // FILTER, startJump(to:) targets an ORIGINAL data row (api/lesssheet.h
        // "JUMP under a filter"), so a filtered view index is the wrong target and
        // cannot correctly pre-advance the filter frontier — skip the pre-pass and
        // let `streamCopy` stop cleanly at the frontier if the selection outruns it
        // (its no-progress guard). The IDENTITY view is unaffected (view == original).
        guard session.filterStatus() == nil else { return }
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
    /// finding 2). The streaming drive checks `Task.isCancelled` on EVERY pull
    /// (and in its STALLED frontier-wait), so a cancel stops the stream promptly.
    /// `advanceFrontier`'s pre-pass wait also polls cancellably. Unconditionally:
    /// the UI-visible state clears immediately, the job is `close`d by the drive
    /// task's `defer`, and any orphaned result is dropped (`completeCopy` checks
    /// `Task.isCancelled` before the pasteboard/notice).
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
            let megabytes = max(1, report.byteCount / (1024 * 1024))
            return "Copied the first ~\(megabytes) MB — \(report.rowCount) rows"
        case .stoppedAtFrontier:
            return "Copied \(report.rowCount) row\(report.rowCount == 1 ? "" : "s") so far — still loading the rest"
        }
    }
}
