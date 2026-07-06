/// The live windowed document session — the ONLY way the app reads document
/// data in the viewer-ui slice (supersedes the walking skeleton's
/// copy-and-close head snapshot). A session wraps one open core handle
/// (`ls_doc`) for its whole lifetime; rows are paged through `setWindow` as
/// the user scrolls, and background indexing / jump scans are observed by
/// polling.
///
/// Contract (mirrors api/lesssheet.h; see it for full semantics):
/// - All strings returned by a session OWN their storage: implementations
///   copy the core's borrowed bytes before returning (respecting the
///   eviction-safe borrow rule) and replace invalid UTF-8 with U+FFFD.
/// - `Sendable`: every member is safe to call from any actor/thread;
///   implementations internally serialize the window lane per the C
///   threading rules. Poll methods never block; `setWindow` is the
///   synchronous-fast path (O(window), never scans, never blocks on I/O
///   proportional to file size).
/// - `close()` releases the core handle (cancelling/joining core threads);
///   it is idempotent. No other member may be called after `close()`.
///   Implementations also close on deinit as a safety net.

/// Row-count knowledge (mirrors `ls_row_count`): `count` is exact when
/// `isExact`, otherwise the core's converging estimate (> 0 for any
/// non-empty document from the moment the session exists). The UI marks
/// estimates (e.g. "~12.4M rows, estimating…") until `isExact`.
public struct RowCountInfo: Equatable, Sendable {
    public let count: UInt64
    public let isExact: Bool

    public init(count: UInt64, isExact: Bool) {
        self.count = count
        self.isExact = isExact
    }
}

/// Background-index progress (mirrors `ls_scan_progress`). `bytesScanned` is
/// monotone non-decreasing; `isComplete` iff every record is indexed (the
/// row count is exact from then on).
public struct ScanProgress: Equatable, Sendable {
    public let bytesScanned: UInt64
    public let bytesTotal: UInt64
    public let isComplete: Bool

    public init(bytesScanned: UInt64, bytesTotal: UInt64, isComplete: Bool) {
        self.bytesScanned = bytesScanned
        self.bytesTotal = bytesTotal
        self.isComplete = isComplete
    }

    /// Fraction in [0, 1] for progress UI; 1 for an empty file.
    public var fraction: Double {
        guard bytesTotal > 0 else { return 1 }
        return Double(bytesScanned) / Double(bytesTotal)
    }
}

/// One materialized row window (mirrors the result of `ls_window_set` plus
/// the copied cells): `rows[i]` is data row `firstRow + i`, each exactly
/// `columnCount` cells wide (truncate/pad applied by the core). `rows` may
/// be shorter than requested — or empty — when the requested range extends
/// beyond the scan frontier or the document; the missing rows become
/// available by re-requesting after the frontier advances (poll-driven).
public struct RowWindow: Equatable, Sendable {
    public let firstRow: UInt64
    public let rows: [[String]]

    public init(firstRow: UInt64, rows: [[String]]) {
        self.firstRow = firstRow
        self.rows = rows
    }
}

/// Jump-slot snapshot (mirrors `ls_jump_status`). `progress` is in [0, 1],
/// monotone within one jump; `done.landedRow` is the target clamped to the
/// last data row (0 for an empty document).
public enum JumpStatus: Equatable, Sendable {
    case idle
    case scanning(progress: Double)
    case done(landedRow: UInt64)
}

/// A live windowed document. See the file header for the full contract.
public protocol DocumentSession: AnyObject, Sendable {
    /// Column count (fixed at open; 0 for an empty document).
    var columnCount: Int { get }
    /// The effective dialect report (fixed at open) — feeds the pills.
    var dialect: DialectReport { get }
    /// The effective header record's cells (exactly `columnCount` of them),
    /// or nil when the effective header is off. Fixed at open.
    var headerCells: [String]? { get }

    /// Current row-count knowledge (poll; never blocks).
    func rowCount() -> RowCountInfo
    /// Current index progress (poll; never blocks). The UI polls at
    /// <= 100 ms granularity while progress is displayed.
    func indexProgress() -> ScanProgress

    /// Declare the viewport (+ scroll buffer) and materialize it: returns
    /// the rows of [firstRow, firstRow + rowCount) that are behind the scan
    /// frontier, copied. `rowCount` is clamped to the core's window cap.
    /// Never scans; synchronous-fast.
    func setWindow(firstRow: UInt64, rowCount: Int) -> RowWindow

    /// Start (or retarget) the async jump-scan toward a 0-based data row.
    /// Never blocks; if the target is behind the frontier the jump is
    /// already `.done` when this returns.
    func startJump(to targetRow: UInt64)
    /// Cancel the active jump (no-op otherwise). Frontier gains are kept;
    /// restoring the viewport is the caller's affair (see `JumpControlling`).
    func cancelJump()
    /// Current jump status (poll; never blocks).
    func jumpStatus() -> JumpStatus

    /// Release the core handle. Idempotent; nothing else may be called
    /// afterwards.
    func close()
}

/// Opens document sessions through the core's C ABI. This is the ONLY entry
/// to document data; all user-facing opens (panel, launch-with-file, CLI,
/// drag & drop, dialect re-open) funnel into one call of this.
///
/// Contract:
/// - `async` and safe to call from any actor, INCLUDING the main actor: the
///   implementation never blocks the main thread (the core's O(head) open
///   runs off it).
/// - The session's background index runs in AUTO mode (starts at open).
/// - An empty file is NOT an error: it yields a session with 0 columns and
///   an exact row count of 0.
/// - Failures throw the distinct `DocumentOpenError` mapped from the ABI
///   code (including `.invalidArgument` for an out-of-domain override).
/// - A dialect change is a RE-OPEN: open the same path again with the
///   composed override and close the old session (ARCH req. 10 — the index
///   restarts; hidden-column state is handled per `ColumnVisibilityManaging`).
public protocol DocumentSessionOpening: Sendable {
    func open(path: String, forcing override: DialectOverride) async throws(DocumentOpenError) -> any DocumentSession
}
