import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// Jump-to-row: parse and validate the field, drive the core scan, fold poll
// status into the flow, land the viewport.

extension DocumentModel {
    /// Parses and starts a jump from the 1-based field text. Returns false, with
    /// a rejection, for an invalid row number or — when the total is already
    /// exact — a target past the last row. While the total is only an estimate,
    /// an out-of-range target can be discovered only by scanning to EOF, so that
    /// rejection happens in `foldJump` instead.
    @discardableResult
    func submitJump(_ text: String) -> Bool {
        guard let target = jumpControl.parseTarget(text) else {
            rejectJump(restoreTo: nil, scanned: false)   // empty / "0" / non-digit / > UInt64.max
            return false
        }
        // Identity view only: while filtered, `target` is an ORIGINAL row number
        // and `rowCountInfo` reports the filtered count — different domains — and
        // a filtered jump clamps to the last match rather than rejecting.
        if !isFiltered, rowCountInfo.isExact, target >= rowCountInfo.count {
            rejectJump(restoreTo: nil, scanned: false)
            return false
        }
        beginJump(to: target)
        return true
    }

    /// Keeps the field open for correction, restores the pre-jump viewport if a
    /// scan had started, and pulses the rejection nonce so the field blinks and
    /// shakes. The core is left alone, so any frontier a scan gained is kept.
    private func rejectJump(restoreTo: UInt64?, scanned: Bool) {
        setJumpFlow(.idle)
        if let restoreTo { pendingScrollRow = restoreTo }
        jumpFieldActive = true
        jumpRejections += 1
        if JumpProbe.active { JumpProbe.rejected(model: self, scanned: scanned, restoredTo: restoreTo) }
    }

    func beginJump(to target: UInt64) {
        guard let session else { return }
        setJumpFlow(jumpControl.begin(target: target, preJumpFirstRow: UInt64(firstVisibleRow)))
        session.startJump(to: target)
        // A behind-frontier target completes before `startJump` returns, so fold
        // the immediate status and let it land without waiting for a poll tick.
        foldJump(session.jumpStatus())
        startPolling()
    }

    func cancelJump() {
        session?.cancelJump()
        let next = jumpControl.cancelled(jumpFlow)
        if case let .cancelled(restore) = next { pendingScrollRow = restore }
        setJumpFlow(next)
    }

    /// The ONLY place `jumpFlow` is assigned, so the scan's start instant is set
    /// and cleared on exactly the scanning transition and no call site has to
    /// remember to do it.
    func setJumpFlow(_ next: JumpFlow) {
        if case .scanning = next {
            if case .scanning = jumpFlow {} else { jumpScanStartedAt = progressClock.now }
        } else {
            jumpScanStartedAt = nil
        }
        jumpFlow = next
    }

    /// The jump scan's delayed-progress indication, through the same gate copy
    /// and the filter use. Always offers cancel: a jump is a one-shot operation
    /// with Esc and a Cancel button behind it.
    var jumpProgressIndication: ProgressIndication {
        guard case .scanning = jumpFlow, let startedAt = jumpScanStartedAt else {
            return progressGate.indication(for: .settled)
        }
        return progressGate.indication(for: .running(elapsed: progressClock.now - startedAt, cancellable: true))
    }

    func foldJump(_ status: JumpStatus) {
        let previous = jumpFlow
        let next = jumpControl.resolve(jumpFlow, with: status)
        if case let .scanning(_, _, progress) = next, JumpProbe.active {
            JumpProbe.noteProgress(progress)
        }
        if case let .landed(row) = next, previous != next {
            // The CORE clamps; rejecting is an app-layer reading of that clamp. A
            // scan that ended short of the target means the target was past the
            // last row, so restore the pre-jump viewport instead of landing on the
            // clamped last row. Identity view only: under a filter `row` is a
            // filtered index and `target` an original row number, and a filtered
            // jump clamps to the last match by design.
            if !isFiltered, case let .scanning(target, preJumpFirstRow, _) = previous, row < target {
                rejectJump(restoreTo: preJumpFirstRow, scanned: true)
                return
            }
            setJumpFlow(next)        // land FIRST, so a later poll cannot re-fire it
            landOn(row)
            return
        }
        setJumpFlow(next)
    }

    private func landOn(_ row: UInt64) {
        landViewport(on: row)
        if JumpProbe.active { JumpProbe.arrived(model: self, landed: row) }
    }

    /// The landing mechanics behind a jump, a find landing and a filter
    /// apply/clear alike: materialize a fresh window at `row` BEFORE the viewport
    /// scrolls, so the rows are already there when it arrives, then hand the grid
    /// the row to bring into view.
    func landViewport(on row: UInt64) {
        firstVisibleRow = Int(min(row, UInt64(Int.max)))
        materialize(start: row, count: GridMetrics.scrollBufferRows * 2)
        pendingScrollRow = row
        viewportLandingHandler?(row)
    }
}
