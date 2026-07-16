/// STREAMING TSV COPY binding (ARCH-thin-frontend-shared-core Phase 2) — the
/// Swift mirror of the core's `ls_copy_open` / `ls_copy_next` / `ls_copy_close`
/// job family (api/lesssheet.h "STREAMING COPY EXTENSION"). The CORE frames the
/// TSV (TAB/LF separators, spreadsheet quoting, the single-cell raw special-case,
/// lossless cells), so a frontend copies a rectangular selection with NO per-cell
/// FFI, NO main-thread stall, and NO TSV logic of its own — replacing the O(document)
/// per-cell `ls_cell_copy` loop the deleted `TSVCopyBuilder` drove. The concatenated
/// chunks are BYTE-IDENTICAL to that former builder (pinned by the golden bridge
/// test + the backend `cp*` behavior suite).
///
/// A frontend opens a job with `DocumentSession.openCopy(_:)` and drives it OFF the
/// main thread. See `CopyStreaming` for the loop.

/// One step of a streaming TSV copy — the Swift mirror of `ls_copy_progress` +
/// `ls_copy_step`.
public struct CopyStep: Sendable, Equatable {
    /// Mirrors `ls_copy_step`.
    public enum Kind: Sendable, Equatable {
        /// `LS_COPY_STEP_MORE` — `bytes` were framed; more chunks remain (call
        /// `next` again).
        case more
        /// `LS_COPY_STEP_DONE` — the final `bytes` were framed and the selection is
        /// complete (`budgetCapped` says whether the safety cap cut it short). Do
        /// not call `next` again; `close`.
        case done
        /// `LS_COPY_STEP_STALLED` — the next selection row is at/beyond the scan
        /// frontier; `bytes` is empty. Advance the frontier to `stalledRow`
        /// (`DocumentSession.startJump(to:)`, await the jump) and call `next` again.
        case stalled
    }

    /// Which step this is.
    public let kind: Kind
    /// The TSV bytes framed THIS step (empty on `.stalled`). Concatenating the
    /// `bytes` of every step in call order yields the whole TSV payload —
    /// byte-identical to the deleted `TSVCopyBuilder`. UTF-8; cut at a field/row
    /// boundary, except that a single field longer than the chunk is split across
    /// steps at a code-point boundary (never mid-code-point).
    public let bytes: [UInt8]
    /// Cumulative selection rows fully emitted so far — monotone. Progress is
    /// `Double(rowsDone) / Double(rect row count)`.
    public let rowsDone: UInt64
    /// On `.stalled`: the VIEW row to advance the frontier to before retrying
    /// (`DocumentSession.startJump(to:)`); 0 otherwise.
    public let stalledRow: UInt64
    /// On `.done`: true iff the core's `LS_COPY_MAX_CELLS` safety cap cut the
    /// selection short (mirrors the deleted `TSVCopyBuilder` cap); false otherwise.
    public let budgetCapped: Bool

    public init(kind: Kind, bytes: [UInt8], rowsDone: UInt64, stalledRow: UInt64, budgetCapped: Bool) {
        self.kind = kind
        self.bytes = bytes
        self.rowsDone = rowsDone
        self.stalledRow = stalledRow
        self.budgetCapped = budgetCapped
    }
}

/// A pull-model streaming TSV copy job — the Swift mirror of the
/// `ls_copy_open`/`ls_copy_next`/`ls_copy_close` handle. Vended by
/// `DocumentSession.openCopy(_:)`.
///
/// THE FRONTEND LOOP (off the main thread): call `next(maxChunkBytes:)`; append
/// `step.bytes`; on `.stalled` advance the frontier
/// (`DocumentSession.startJump(to: step.stalledRow)`, await the jump) and call
/// `next` again; report progress from `step.rowsDone`; on `.done` read
/// `step.budgetCapped` for the notice; then `close()` EXACTLY ONCE. CANCEL is
/// "stop calling `next`, then `close()`" (no background thread to join).
/// SINGLE-CONSUMER: do not call `next` concurrently on one job.
public protocol CopyStreaming: AnyObject, Sendable {
    /// Frame the next TSV chunk into a fresh `[UInt8]` (up to `maxChunkBytes`
    /// bytes, cut at a field/row boundary; the core COPIES — no borrow) and return
    /// the step. Mirrors `ls_copy_next`. Do not call after a `.done` step.
    func next(maxChunkBytes: Int) -> CopyStep
    /// Release the job (call EXACTLY ONCE; invalid afterwards). Mirrors
    /// `ls_copy_close`.
    func close()
}
