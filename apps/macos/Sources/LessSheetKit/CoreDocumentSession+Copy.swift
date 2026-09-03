import CLessSheet
import Contracts
import Foundation

// The copy bridge. Poll/control lane: it neither reads nor evicts the
// materialized window, so it deliberately does NOT take the window lane's
// `lock` — that is what lets a background copy run while the UI keeps
// scrolling. It takes `copyBufferLock` instead, which is what `close()` also
// holds (see that lock's doc).
extension CoreDocumentSession {
    /// Copies one cell LOSSLESSLY (up to `maxBytes`), not the display-capped
    /// bytes `ls_cell` serves: `.served` with the text and the core's truncation
    /// flag, `.pending` past the scan frontier, `.noCell` out of range.
    public func copyCell(row: UInt64, column: Int, maxBytes: Int) -> CopiedCell {
        guard let col = UInt32(exactly: column) else {
            return CopiedCell(status: .noCell, text: "", truncated: false)
        }
        let capacity = max(maxBytes, 0)
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else {
            return CopiedCell(status: .noCell, text: "", truncated: false)
        }
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
            let text = outLen > 0 ? String(lossyUTF8: copyBuffer[0..<outLen]) : ""
            return CopiedCell(status: .served, text: text, truncated: outTruncated)
        case ls_copy_result.RawValue(LS_COPY_PENDING.rawValue):
            return CopiedCell(status: .pending, text: "", truncated: false)
        default:   // LS_COPY_NO_CELL
            return CopiedCell(status: .noCell, text: "", truncated: false)
        }
    }

    // MARK: - Streaming copy
    //
    // The CORE frames the TSV, so nothing here knows about quoting or
    // separators, and the sweep rides its O(1) forward copy cursor instead of a
    // per-cell FFI loop.

    /// Opens a pull-model streaming TSV copy of `rect`, converting the INCLUSIVE
    /// selection to the ABI's half-open rect. Returns nil only when the handle
    /// could not be allocated or the session is closed — the core turns an empty
    /// or out-of-range rect into a job that steps DONE with 0 bytes, so a
    /// degenerate selection is not an error.
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

    /// One `ls_copy_next` pull. A closed session yields a `.done` step with no
    /// bytes, which stops the drive loop.
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

    /// Releases a `CoreCopyStream`'s job. The job holds no background thread and
    /// its storage is freed through the process-global core allocator, so this is
    /// safe whether or not the session is closed; `CoreCopyStream` makes it
    /// exactly-once.
    func copyStreamClose(_ job: OpaquePointer) {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        ls_copy_close(job)
    }
}

/// A live streaming TSV copy job, vended by `CoreDocumentSession.openCopy(_:)`.
/// Single-consumer: one `next` at a time, closed once.
///
/// The strong session reference keeps the core handle alive for the job's
/// lifetime; an explicit `session.close()` still wins, after which `next`
/// returns a `.done` step with no bytes and the drive loop stops.
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
