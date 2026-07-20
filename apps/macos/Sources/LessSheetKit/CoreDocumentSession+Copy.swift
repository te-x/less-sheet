import CLessSheet
import Contracts
import Foundation

// MARK: - Copy bridge (select-copy; ARCH-select-copy AC3) — ls_cell_copy.
// Poll/control lane (api/lesssheet.h THREADING): safe from ANY thread at
// any time, concurrently with the window lane's `lock` — it neither reads
// nor evicts the materialized window. UNLIKE setWindow/sourceRow, this
// deliberately does NOT take `lock`: that is exactly what lets a background
// copy worker fill a `CopyBudget`-bounded selection while the UI keeps
// scrolling (ls_window_set / ls_cell) undisturbed (AC4).
//
// Split out of CoreDocumentSession.swift as a same-module extension (pure
// code motion) so the primary type body stays within budget; it reaches the
// session's `internal` doc/copyBufferLock/isClosed/copyBuffer members.
extension CoreDocumentSession {
    /// OVERRIDES the RED default (`DocumentSession`'s `.noCell`-for-everything
    /// extension): fills a `maxBytes` buffer via `ls_cell_copy` and maps
    /// `ls_copy_result` to `CopiedCell` — `.served` with the decoded UTF-8 text
    /// (and the core's `truncated` flag), `.pending` past the scan frontier,
    /// `.noCell` for an out-of-range column/row. `maxBytes <= 0` (or a column
    /// outside `UInt32`'s domain, never a valid column) copies nothing rather
    /// than allocate/convert — the core itself would report exactly this for
    /// an out-of-range column, so this is a graceful shortcut, not new
    /// behavior.
    public func copyCell(row: UInt64, column: Int, maxBytes: Int) -> CopiedCell {
        guard let col = UInt32(exactly: column) else {
            return CopiedCell(status: .noCell, text: "", truncated: false)
        }
        let capacity = max(maxBytes, 0)
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        // RACE GUARD (round-4: fixes a confirmed use-after-free). `close()`
        // takes this SAME lock around `isClosed = true; ls_close(doc)`, so
        // this check and the `ls_cell_copy` call below can never interleave
        // with a concurrent/prior close — an orphaned copy build (its
        // synchronous loop has no cancellation checkpoint of its own; see
        // `cancelCopy`'s doc in ViewerModel) can no longer touch a freed
        // `doc`, satisfying the ABI rule "ls_cell_copy ... NOT concurrently
        // with ls_open/ls_close". Deliberately NOT the window-lane `lock`:
        // that would serialize copy against setWindow/sourceRow too, which
        // would regress AC4 (copy runs concurrently with scrolling).
        guard !isClosed else {
            return CopiedCell(status: .noCell, text: "", truncated: false)
        }
        // Grow-only reuse (see the property doc): a call with a SMALLER cap
        // than the buffer's current size must still pass ITS OWN `capacity`
        // as `buf_len` below (never the buffer's larger true size), so a
        // per-cell cap change between calls still truncates correctly.
        if copyBuffer.count < capacity {
            copyBuffer = [UInt8](repeating: 0, count: capacity)
        }
        var outLen = 0
        var outTruncated = false
        let result = copyBuffer.withUnsafeMutableBufferPointer { buf in
            ls_cell_copy(doc, row, col, buf.baseAddress, capacity, &outLen, &outTruncated)
        }
        switch result.rawValue {
        case ls_copy_result.RawValue(LS_COPY_OK.rawValue):
            let text = outLen > 0 ? (String(bytes: copyBuffer[0..<outLen], encoding: .utf8) ?? "") : ""
            return CopiedCell(status: .served, text: text, truncated: outTruncated)
        case ls_copy_result.RawValue(LS_COPY_PENDING.rawValue):
            return CopiedCell(status: .pending, text: "", truncated: false)
        default:   // LS_COPY_NO_CELL
            return CopiedCell(status: .noCell, text: "", truncated: false)
        }
    }

    // MARK: - Streaming copy bridge (ARCH-thin-frontend-shared-core Phase 2) —
    // ls_copy_open / ls_copy_next / ls_copy_close. The CORE frames the TSV
    // (TAB/LF, spreadsheet quoting, single-cell raw, lossless cells), so this
    // replaces the O(document) per-cell ls_cell_copy loop the deleted
    // TSVCopyBuilder drove: no per-cell FFI, no main-thread stall (the sweep
    // rides the in-core O(1) forward copy cursor). Same poll/control-lane +
    // copyBufferLock discipline as copyCell above.

    /// OVERRIDES the RED default (`DocumentSession`'s nil): opens a pull-model
    /// streaming TSV copy of `rect`. Converts the INCLUSIVE `SelectionRect` to a
    /// HALF-OPEN `ls_copy_rect` (row_count = bottom-top+1, col_count =
    /// right-left+1; a negative/oversized column clamps and the core then reports
    /// the empty job). Returns a `CoreCopyStream` wrapping the `ls_copy_job`, or
    /// nil only when the handle couldn't be allocated (or the session is closed).
    /// The core validates an empty / out-of-range rect into a job that steps DONE
    /// with 0 bytes, so a degenerate selection is not an error here.
    public func openCopy(_ rect: SelectionRect) -> (any CopyStreaming)? {
        let low = max(rect.left, 0)
        let high = max(rect.right, low)
        var crect = ls_copy_rect(
            first_row: rect.top,
            row_count: rect.rowCount,               // bottom - top + 1 (inclusive -> count)
            first_col: UInt32(clamping: low),
            col_count: UInt32(clamping: high - low + 1)
        )
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return nil }
        guard let job = ls_copy_open(doc, &crect) else { return nil }
        return CoreCopyStream(session: self, job: job)
    }

    /// One `ls_copy_next` pull for a `CoreCopyStream` (poll/control lane; guarded
    /// by `copyBufferLock` + `isClosed`, exactly like `copyCell`, so an orphaned
    /// copy task cannot call into a freed `doc` after `close()`). Allocates a
    /// fresh `maxChunkBytes` buffer, copies out the framed bytes, maps the step.
    /// A closed session yields a `.done` step with no bytes (the drive loop then
    /// stops + closes). `buf` is NULL only when `maxChunkBytes <= 0`.
    func copyStreamNext(_ job: OpaquePointer, maxChunkBytes: Int) -> CopyStep {
        let cap = max(maxChunkBytes, 0)
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else {
            return CopyStep(kind: .done, bytes: [], rowsDone: 0, stalledRow: 0, budgetCapped: false)
        }
        var progress = ls_copy_progress()
        var out: [UInt8] = []
        if cap > 0 {
            var buffer = [UInt8](repeating: 0, count: cap)
            progress = buffer.withUnsafeMutableBufferPointer { buf in
                ls_copy_next(job, buf.baseAddress, cap)
            }
            let written = min(Int(clamping: progress.written), cap)
            if written > 0 { out = Array(buffer[0..<written]) }
        } else {
            progress = ls_copy_next(job, nil, 0)
        }
        let kind: CopyStep.Kind
        switch progress.step.rawValue {
        case ls_copy_step.RawValue(LS_COPY_STEP_MORE.rawValue):
            kind = .more
        case ls_copy_step.RawValue(LS_COPY_STEP_STALLED.rawValue):
            kind = .stalled
        default:   // LS_COPY_STEP_DONE
            kind = .done
        }
        return CopyStep(kind: kind, bytes: out, rowsDone: progress.rows_done,
                        stalledRow: progress.stalled_row, budgetCapped: progress.budget_capped)
    }

    /// Release a `CoreCopyStream`'s job (`ls_copy_close`). Takes `copyBufferLock`
    /// like `copyStreamNext` / `close()`; the job holds no background thread and
    /// its own storage is freed through the process-global core allocator, so
    /// this is safe whether or not the session has been closed. Idempotency is
    /// enforced by `CoreCopyStream` itself (its own once-flag).
    func copyStreamClose(_ job: OpaquePointer) {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        ls_copy_close(job)
    }
}

/// A live streaming TSV copy job (`CopyStreaming`) over the core's `ls_copy_*`
/// handle — vended by `CoreDocumentSession.openCopy(_:)`. Delegates `next` /
/// `close` to the owning session's guarded bridge methods (`copyStreamNext` /
/// `copyStreamClose`), which take the session's `copyBufferLock` and check
/// `isClosed` — the SAME UAF discipline `copyCell` uses — so an orphaned copy
/// task can never call `ls_copy_next` into a freed `doc`.
///
/// Holding a strong reference to the session keeps the core handle alive for the
/// job's lifetime (an explicit `session.close()` still wins: it flips `isClosed`
/// under the lock, after which `next` returns a `.done` step with no bytes and
/// the drive loop stops). SINGLE-CONSUMER: the frontend drives one `next` at a
/// time on its copy task and `close`s once (the `once` flag + `deinit` safety net
/// make `ls_copy_close` exactly-once regardless).
public final class CoreCopyStream: CopyStreaming, @unchecked Sendable {
    private let session: CoreDocumentSession
    private let job: OpaquePointer
    private let lock = NSLock()
    private var closed = false

    init(session: CoreDocumentSession, job: OpaquePointer) {
        self.session = session
        self.job = job
    }

    public func next(maxChunkBytes: Int) -> CopyStep {
        lock.lock()
        let alreadyClosed = closed
        lock.unlock()
        guard !alreadyClosed else {
            return CopyStep(kind: .done, bytes: [], rowsDone: 0, stalledRow: 0, budgetCapped: false)
        }
        return session.copyStreamNext(job, maxChunkBytes: maxChunkBytes)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        session.copyStreamClose(job)
    }

    deinit { close() }
}
