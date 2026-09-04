/// The clipboard COPY builder (ARCH-select-copy AC2/AC3): turns a selection rect
/// into a TSV payload, ROW-MAJOR, BYTE-BOUNDED, and lossless per cell. This is
/// where the whole feature's cost is bounded — selection is unbounded index
/// space (`Selecting`), the copy is what stops. Pure and deterministic: the
/// per-cell read is an INJECTED closure (so tests are hermetic and the builder
/// carries no core dependency), and — being pure value logic with a `@Sendable`
/// closure — it does no main-thread-only work, which is exactly what lets the
/// frontend run a budget-filling copy OFF the main thread (AC4; see the AC4 note
/// in the frozen tests). The real backing closure calls
/// `DocumentSession.copyCell` (this file's additive wrapper over `ls_cell_copy`).

/// The outcome of one cell fetch, mirroring `ls_cell_copy` / `ls_copy_result`
/// (api/lesssheet.h) one-to-one so the frontend closure is a thin bridge.
public enum CopyCellStatus: Sendable, Equatable {
    /// `LS_COPY_OK` — the cell was read; `text` holds its content (empty for an
    /// empty cell), `truncated` says whether the per-cell byte cap cut it.
    case served
    /// `LS_COPY_PENDING` — the row lies at/beyond the scan frontier: not yet
    /// locatable, nothing read. A PER-ROW condition (a locatable row serves every
    /// column). The builder stops at this row boundary (`.stoppedAtFrontier`);
    /// advancing the frontier (a jump over the rect) and retrying is the caller's
    /// affair.
    case pending
    /// `LS_COPY_NO_CELL` — no such cell (column past `columnCount`, or a row past
    /// an EXACT row count). A rect built from a real `GridExtent` should never
    /// yield this; the builder treats it as an empty cell (stays total).
    case noCell
}

/// One cell as read for copy — the closure's return, mirroring `ls_cell_copy`'s
/// out-params. `text` is the cell's COMPLETE content decoded to a Swift string
/// (UTF-8, invalid bytes already → U+FFFD by the bridge), WITHOUT the 4 KiB
/// display cap `ls_cell` applies — up to the per-cell byte cap the closure passed
/// as `buf_len`. `truncated` is true iff the cell's full content exceeded that
/// per-cell cap (the rare > ~1 MiB cell); it is copied to the boundary-cut prefix.
public struct CopiedCell: Sendable, Equatable {
    public let status: CopyCellStatus
    public let text: String
    public let truncated: Bool

    public init(status: CopyCellStatus, text: String, truncated: Bool) {
        self.status = status
        self.text = text
        self.truncated = truncated
    }

    /// An empty, servable cell (`LS_COPY_OK`, no content) — the common padding
    /// result for a short row's trailing columns.
    public static let empty = CopiedCell(status: .served, text: "", truncated: false)
}

/// The copy TUNABLES (ARCH: "a tunable frontend constant"). `.standard` carries
/// the shipping values; the frozen tests NEVER assert the exact numbers — they
/// use tiny budgets to pin the STOPPING behavior (bounded, not a magic size).
///
/// - `maxTotalBytes` — the ~64 MiB byte budget the BUILDER enforces over the
///   accumulated TSV: bytes bound cost (memory / fetch / paste-target load),
///   counts don't. Multi-cell accumulation stops once the next cell would exceed
///   it (a single cell is always emitted whole).
/// - `maxCells` — the cell-count SAFETY cap the builder enforces: bounds the
///   number of per-cell fetches so a pathological all-EMPTY huge selection
///   (≈0 bytes, but 100M+ cells) cannot do O(rows) fetches. Bytes wouldn't stop
///   it; this does.
/// - `perCellMaxBytes` — the ~1 MiB lossless per-cell cap the CALLER passes to
///   the fetch (`copyCell`'s `buf_len`); the builder does not apply it (the
///   closure does), but it lives here so all copy tuning is one value.
public struct CopyBudget: Sendable, Equatable {
    public let maxTotalBytes: Int
    public let maxCells: Int
    public let perCellMaxBytes: Int

    public init(maxTotalBytes: Int, maxCells: Int, perCellMaxBytes: Int) {
        self.maxTotalBytes = maxTotalBytes
        self.maxCells = maxCells
        self.perCellMaxBytes = perCellMaxBytes
    }

    /// The shipping tunables (see the ARCH cap model): ~64 MiB total, a 10M-cell
    /// safety cap, ~1 MiB per cell. TUNABLE — not part of the pinned behavior.
    public static let standard = CopyBudget(
        maxTotalBytes: 64 * 1024 * 1024,
        maxCells: 10_000_000,
        perCellMaxBytes: 1024 * 1024
    )
}

/// Why a build stopped — drives the honest "what was copied" notice (ARCH AC2).
public enum CopyOutcome: Sendable, Equatable {
    /// The whole rect was copied.
    case complete
    /// The ~byte budget (`CopyBudget.maxTotalBytes`) was reached.
    case stoppedAtBudget
    /// The cell-count safety cap (`CopyBudget.maxCells`) was reached.
    case stoppedAtCellCap
    /// A row past the scan frontier (`.pending`) was hit — copied up to it.
    case stoppedAtFrontier
}

/// The result of a build. `text` is the exact clipboard payload (the frontend
/// sets it as BOTH the TSV type and the plain-string type on `NSPasteboard`).
/// `byteCount`/`rowCount`/`outcome`/`lossyCells` feed the notice ("Copied the
/// first ~N MB — M rows").
public struct CopyReport: Sendable, Equatable {
    /// The TSV payload (also the plain-string rep). For a single-cell rect this
    /// is the cell's RAW value (no quoting, no newline).
    public let text: String
    /// UTF-8 byte length of `text` — what the byte budget bounds; drives "~N MB".
    public let byteCount: Int
    /// Rows that contributed at least one emitted cell — drives "M rows". Exact
    /// for `.complete` / `.stoppedAtFrontier` (row-boundary stops); the trailing
    /// row MAY be partial for `.stoppedAtBudget` / `.stoppedAtCellCap`.
    public let rowCount: UInt64
    /// Why the build ended.
    public let outcome: CopyOutcome
    /// True iff at least one EMITTED cell hit the per-cell byte cap (`> ~1 MiB`,
    /// `CopiedCell.truncated`) — the copy is otherwise lossless. Does not stop
    /// the build; surfaced for an honest notice.
    public let lossyCells: Bool

    public init(text: String, byteCount: Int, rowCount: UInt64, outcome: CopyOutcome, lossyCells: Bool) {
        self.text = text
        self.byteCount = byteCount
        self.rowCount = rowCount
        self.outcome = outcome
        self.lossyCells = lossyCells
    }
}
