import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation

// DocumentModel — jump-to-row: parse + validate the field, drive the core scan,
// fold poll status into the jump flow, and land the viewport. Pure code motion
// out of ViewerModel.swift (no behavior change).

extension DocumentModel {
    // MARK: - Jump-to-row

    /// Parse + start a jump from the 1-based field text. Returns false — with a
    /// rejection (field blink + shake, no viewport move) — when the input is not
    /// a valid 1-based row number, OR when the total is already EXACT and the
    /// target is past the last row (upfront validation, no scan). When the total
    /// is still estimated, an out-of-range target can only be discovered by
    /// scanning to EOF; that rejection happens in `foldJump` (ARCH error case,
    /// amended 2026-07-06 — reject, don't clamp).
    @discardableResult
    func submitJump(_ text: String) -> Bool {
        guard let target = jumpControl.parseTarget(text) else {
            rejectJump(restoreTo: nil, scanned: false)   // empty / "0" / non-digit / > UInt64.max
            return false
        }
        // (a) Total exact: valid 0-based rows are 0..<count; anything at/beyond
        // count is rejected immediately, no scan. IDENTITY VIEW ONLY: under a
        // filter `target` is an ORIGINAL row number (ARCH-filtered-views req.
        // 7/12) while `rowCountInfo` reports the filtered m — not the same
        // domain — and the filtered jump never rejects (it clamps to the last
        // match instead), so this upfront check does not apply while filtered.
        if !isFiltered, rowCountInfo.isExact, target >= rowCountInfo.count {
            rejectJump(restoreTo: nil, scanned: false)
            return false
        }
        beginJump(to: target)
        return true
    }

    /// Reject the current jump: keep the field open (re-armed for correction),
    /// restore the viewport to `restoreTo` if a scan had started, and pulse the
    /// rejection nonce so the overlay blinks/shakes the field. The core is left
    /// alone — its frontier gains (from any scan) are kept.
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
        // Behind-frontier targets complete before startJump returns; fold the
        // immediate status so a tiny/loaded jump lands without a poll tick.
        foldJump(session.jumpStatus())
        startPolling()
    }

    func cancelJump() {
        session?.cancelJump()
        let next = jumpControl.cancelled(jumpFlow)
        if case let .cancelled(restore) = next { pendingScrollRow = restore }
        setJumpFlow(next)
    }

    /// The ONLY place `jumpFlow` is assigned (ARCH-stream-copy AC9 "just
    /// wiring"): starts/clears `jumpScanStartedAt` — the real clock reading
    /// `jumpProgressIndication` measures elapsed from — exactly on the
    /// idle/landed/cancelled <-> scanning transition, so every call site
    /// above gets this for free instead of repeating it.
    func setJumpFlow(_ next: JumpFlow) {
        if case .scanning = next {
            if case .scanning = jumpFlow {} else { jumpScanStartedAt = progressClock.now }
        } else {
            jumpScanStartedAt = nil
        }
        jumpFlow = next
    }

    /// JUMP-scan's live delayed-progress indication (AC9 "just wiring"): the
    /// SAME gate copy uses (`progressGate`), fed the real elapsed since
    /// scanning began — hidden while idle/landed/cancelled, or still under
    /// the shared threshold; visible WITH cancel once past it (a jump always
    /// carries Task/Esc/Cancel — see `cancelJump`). `JumpControlView` reads
    /// this to decide when its progress bar surfaces (OverlayView.swift).
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
            // App-layer interpretation of the core's (frozen) clamp: if the scan
            // ended SHORT of the requested target, the target was past the last
            // row — reject and restore the pre-jump viewport, rather than land on
            // the clamped last row (ARCH error case, amended 2026-07-06). The
            // frozen JumpControl.resolve() is unchanged — it still says .landed;
            // the reject decision lives here, above it. IDENTITY VIEW ONLY:
            // under a filter `row` is a FILTERED index and `target` an
            // ORIGINAL row number (not comparable), and the filtered jump
            // never rejects — it clamps to the last match instead
            // (ARCH-filtered-views criterion 12).
            if !isFiltered, case let .scanning(target, preJumpFirstRow, _) = previous, row < target {
                rejectJump(restoreTo: preJumpFirstRow, scanned: true)   // sets jumpFlow = .idle
                return
            }
            setJumpFlow(next)        // mark landed FIRST so a later poll doesn't re-fire
            landOn(row)
            return
        }
        setJumpFlow(next)
    }

    /// A completed jump lands here: page the core window to the target BEFORE
    /// the viewport scrolls, so the rows are already materialized when it
    /// arrives (the virtual band anchors on the landed row) and a headless
    /// arrival dump shows the target row immediately. Then ask the grid to
    /// scroll the landed row into view.
    private func landOn(_ row: UInt64) {
        landViewport(on: row)
        if JumpProbe.active { JumpProbe.arrived(model: self, landed: row) }
    }

    /// Page the window to `row` and hand the grid the row to scroll into view
    /// — the shared landing mechanics behind a jump landing, a search landing,
    /// and a filter apply/clear (ARCH-filtered-views criterion 13): materialize
    /// a fresh window centered on `row`, then set `pendingScrollRow` (consumed
    /// once by the grid).
    func landViewport(on row: UInt64) {
        firstVisibleRow = Int(min(row, UInt64(Int.max)))
        materialize(start: row, count: GridMetrics.scrollBufferRows * 2)
        pendingScrollRow = row
        viewportLandingHandler?(row)
    }
}
