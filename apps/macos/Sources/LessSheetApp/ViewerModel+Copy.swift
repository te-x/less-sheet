import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// The streaming TSV copy: snapshot the selection, pre-advance the scan
// frontier, stream core-framed TSV off the main thread, then write the
// pasteboard and the notice.

extension DocumentModel {
    /// ⌘C: snapshots the live selection and streams the payload off the main
    /// thread, then writes the pasteboard back on the main actor. A copy already
    /// running is CANCELLED rather than ignored — the new selection supersedes it.
    ///
    /// The pre-pass gives the background index a bounded chance to reach the
    /// selection's bottom row first; without it, a selection made soon after
    /// opening a large file would stop at the frontier and say so, even though
    /// the rest of the rows are perfectly reachable.
    func copySelection() {
        guard let session, let rect = selection?.rect else { return }
        cancelCopy()
        copyInFlight = true
        let startedAt = progressClock.now
        copyStartedAt = startedAt
        copyGeneration += 1
        let myGeneration = copyGeneration
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.progressGate.threshold)
            // The generation check, not `copyInFlight`, is what tells this task
            // apart from a copy that superseded it (see `copyGeneration`).
            guard !Task.isCancelled, self.copyInFlight, self.copyGeneration == myGeneration else { return }
            let elapsed = self.progressClock.now - startedAt
            let indication = self.progressGate.indication(for: .running(elapsed: elapsed, cancellable: true))
            self.copyProgress = indication
            if indication.isVisible { self.copyNotice = "Copying…" }
        }
        let budget = CopyBudget.standard
        copyTask = Task.detached { [weak self] in
            await Self.advanceFrontier(session: session, to: rect.bottom)
            guard !Task.isCancelled else { return }
            let report = await Self.streamCopy(session: session, rect: rect, budget: budget)
            guard !Task.isCancelled else { return }
            await self?.completeCopy(report)
        }
    }

    /// Per-pull chunk size. The payload total is bounded by the byte budget and
    /// the core's cell cap, never by this.
    nonisolated private static let copyChunkBytes = 1 << 16   // 64 KiB

    /// Streams the core-framed TSV copy of `rect`: pull, append, advance the
    /// frontier on a stall and resume, stop at the frontend byte budget. The core
    /// owns the framing and the cell-count cap, so there is no TSV logic here.
    ///
    /// `nonisolated` so the sweep runs on the caller's detached executor rather
    /// than hopping back to the main actor; `internal` so the outcome probe can
    /// drive it with a fake session.
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
        /// The last row a stall asked the frontier to advance over. Seeing it
        /// again means the jump made no progress.
        var lastStalledRow: UInt64?
        pull: while true {
            if Task.isCancelled { break }
            let step = job.next(maxChunkBytes: copyChunkBytes)
            rowsDone = step.rowsDone
            blob.append(contentsOf: step.bytes)
            switch step.kind {
            case .more:
                // The frontend's byte cap; the core's own ceiling is a cell count,
                // reported on `.done`.
                if blob.count >= budget.maxTotalBytes {
                    outcome = .stoppedAtBudget
                    break pull
                }
            case .stalled:
                // `stalledRow` is a VIEW index, but `startJump` targets an
                // ORIGINAL row while a filter is active, so under a filter the
                // jump cannot advance past the stalled row and returns DONE
                // immediately. Seeing the same row again means exactly that:
                // stop cleanly rather than re-jump it forever. The identity view
                // never trips this, since a real advance always stalls later.
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
        let text = String(lossyUTF8: blob)
        return CopyReport(text: text, byteCount: blob.count, rowCount: rowsDone, outcome: outcome, lossyCells: false)
    }

    /// Advances the scan frontier over a stalled row, ALWAYS sleeping at least
    /// once first so an immediately-done jump cannot let the caller busy-spin.
    /// Returns true once the jump settles, false on a timeout or a cancellation —
    /// the caller separates those with `Task.isCancelled`.
    nonisolated private static func awaitFrontierAdvance(session: any DocumentSession, to row: UInt64) async -> Bool {
        session.startJump(to: row)
        for _ in 0..<frontierPollMaxTicks {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: frontierPollInterval)
            if case .done = session.jumpStatus() { return true }
        }
        return false
    }

    /// How long the frontier waits are allowed to run, bounded so a copy can
    /// never hang on an arbitrarily slow scan.
    nonisolated private static let frontierPollInterval: Duration = .milliseconds(50)
    nonisolated private static let frontierPollMaxTicks = 40   // ~2 s total

    /// Pre-advances the scan frontier toward `target` with the same primitives a
    /// real jump uses, but deliberately bypassing `jumpFlow` and the viewport, so
    /// it is invisible to the user while still unlocking rows for the copy.
    nonisolated private static func advanceFrontier(session: any DocumentSession, to target: UInt64) async {
        // A cancel that lands before the task is first scheduled must stop it
        // here, not one core call later.
        guard !Task.isCancelled else { return }
        // `target` (the selection's bottom) is a VIEW row, but `startJump(to:)`
        // targets an ORIGINAL data row while a filter is active (api/lesssheet.h
        // "JUMP under a filter"), so under a filter the pre-pass cannot advance the
        // right frontier — skip it and let `streamCopy` stop cleanly at the frontier
        // via its no-progress guard. The identity view is unaffected.
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
        // The sweep can run to completion after `cancelCopy` already cleared this
        // copy's state, so a superseded result must never reach the pasteboard.
        guard !Task.isCancelled else { return }
        copyTask = nil
        copyInFlight = false
        copyProgress = .hidden
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

    /// Cancels an in-flight copy (Esc, the notice's Cancel button, or a fresh ⌘C
    /// superseding it). The UI state clears immediately; the sweep itself is
    /// BEST-EFFORT — it checks for cancellation on every pull and in both
    /// frontier waits, closes its job through a `defer`, and drops any result
    /// that lands anyway.
    func cancelCopy() {
        copyTask?.cancel()
        copyTask = nil
        copyNoticeTask?.cancel()
        copyNoticeTask = nil
        copyInFlight = false
        copyProgress = .hidden
        copyStartedAt = nil
        copyNotice = nil
    }

    /// Both a TSV type and a plain string: `.tabularText` is the tab-delimited
    /// spreadsheet type Excel and Numbers read.
    private static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .tabularText)
        pasteboard.setString(text, forType: .string)
    }

    /// The honest "what was copied" notice. Sentence case, user vocabulary.
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
