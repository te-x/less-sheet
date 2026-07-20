import CLessSheet
import Contracts
import Foundation

/// Swift bridge over the core C ABI (`api/lesssheet.h` via CLessSheet):
/// opens live windowed sessions, maps the option/report/progress/jump/search
/// types, and copies every borrowed cell out of the core before returning
/// (respecting the eviction-safe borrow rule; invalid UTF-8 becomes U+FFFD).
///
/// Threading: the C contract makes the poll/control lane internally
/// synchronized; the window lane (ls_window_set + cell reads) must be
/// serialized by the caller — `CoreDocumentSession` owns a lock around it
/// (and around close), which is what makes the class honestly Sendable.
public struct CoreSessionOpener: DocumentSessionOpening {
    public init() {}

    /// A dedicated background queue for the core's O(head) open. Keeps the
    /// blocking `ls_open` (up to LS_OPEN_HEAD_MAX_BYTES of file I/O) off the
    /// calling actor so a main-actor caller's run loop is never blocked during
    /// cold start — structurally, not by relying on a nonisolated-async
    /// executor default that a future language mode could change.
    private static let openQueue = DispatchQueue(label: "less-sheet.core-open", qos: .userInitiated)

    /// The concrete continuation both open overloads resume; named so the
    /// `withCheckedThrowingContinuation` closure parameter stays on one line.
    private typealias SessionContinuation = CheckedContinuation<CoreDocumentSession, any Error>

    public func open(
        path: String, forcing override: DialectOverride
    ) async throws(DocumentOpenError) -> any DocumentSession {
        do {
            return try await withCheckedThrowingContinuation { (continuation: SessionContinuation) in
                Self.openQueue.async {
                    do {
                        continuation.resume(returning: try CoreDocumentSession(path: path, forcing: override))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as DocumentOpenError {
            throw error
        } catch {
            // Unreachable: CoreDocumentSession.init throws only DocumentOpenError.
            throw DocumentOpenError.ioFailure
        }
    }

    /// OVERRIDES the RED default: drives the core's async open-job
    /// (`ls_open_url_start` -> poll `ls_net_open_poll` -> `ls_net_open_release`),
    /// mapping `ls_net_status` -> `NetworkOpenError` on failure (a non-http/https
    /// scheme is rejected SYNCHRONOUSLY by the core with `.invalidArgument`, no
    /// network). Honors Task cancellation (cancels the fetch, throws
    /// `.cancelled`). Returns the live session once the open is DONE. A thin
    /// wrapper over `openURL(_:forcing:onProgress:cancelToken:)` with a no-op
    /// progress callback and a throwaway token — this is the frozen protocol
    /// requirement `DocumentSessionOpening` pins; callers that want the
    /// always-visible progress affordance + an explicit Cancel button (ARCH
    /// req 10 / AC9) use the tracking overload below instead.
    public func openURL(
        _ url: String, forcing override: DialectOverride
    ) async throws(NetworkOpenError) -> any DocumentSession {
        try await openURL(url, forcing: override, onProgress: { _ in }, cancelToken: NetworkOpenCancelToken())
    }

    /// Tracking variant (LessSheetKit-only; not part of the frozen protocol):
    /// identical open-job drive as above, but invokes `onProgress` with a live
    /// snapshot on every poll tick (not just at start/terminal) — this is what
    /// lets the UI show a real, incrementally-updating percentage/byte counter
    /// (ARCH AC9 / round-2 review finding 1) — and honors `cancelToken`
    /// explicitly (a plain dispatch-queue background op has no ambient Swift
    /// Task to observe `Task.isCancelled` on, so a caller-owned token is the
    /// only reliable cancel signal here).
    public func openURL(
        _ url: String,
        forcing override: DialectOverride,
        onProgress: @escaping @Sendable (NetworkOpenProgress) -> Void,
        cancelToken: NetworkOpenCancelToken
    ) async throws(NetworkOpenError) -> any DocumentSession {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: SessionContinuation) in
                    Self.openQueue.async {
                        do {
                            continuation.resume(returning: try CoreDocumentSession.openURLSync(
                                url, forcing: override, onProgress: onProgress, cancelToken: cancelToken
                            ))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                cancelToken.cancel()
            }
        } catch let error as NetworkOpenError {
            throw error
        } catch {
            throw NetworkOpenError.unreachable
        }
    }
}

/// Explicit, thread-safe cancel signal for an in-flight `openURL` (LessSheetKit
/// / App only — not part of the frozen `Contracts` surface). The tracking
/// `openURL(...)` overload polls `isCancelled` between core polls and, once
/// true, calls `ls_net_open_cancel` on the job — this is the backing state for
/// the UI's explicit Cancel button (round-2 review finding 1); Swift Task
/// cancellation ALSO sets it via `withTaskCancellationHandler`.
public final class NetworkOpenCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// One live core document. See `DocumentSession` for the full contract.
public final class CoreDocumentSession: DocumentSession, @unchecked Sendable {
    // `doc` / `lock` / `isClosed` / `copyBufferLock` / `copyBuffer` are
    // `internal` (not `private`) so the cohesive method groups split into
    // same-module extension files (`+Window`, `+Search`, `+Copy`, `+Columns`,
    // `+ABIMapping`) can reach them; still not part of the public API surface.
    let doc: OpaquePointer
    let lock = NSLock()
    var isClosed = false
    /// A REUSED scratch buffer for `copyCell` (select-copy), grown on demand
    /// and never shrunk — guarded by its OWN lock, distinct from the window
    /// lane's `lock` above (copyCell is poll/control-lane and must stay
    /// independent of it; see `copyCell`'s doc). A large copy calls
    /// `copyCell` per cell (potentially millions of times for a big
    /// selection); allocating + zero-filling a fresh `perCellMaxBytes`
    /// (~1 MiB) buffer on EVERY call would dominate the whole build's cost
    /// for no reason, since the SAME cap is used call after call within one
    /// copy — reusing the backing storage (while still passing THIS call's
    /// own `maxBytes` as the core's `buf_len`, so a smaller cap still
    /// truncates correctly even with a larger buffer sitting behind it)
    /// turns that into a one-time allocation per session.
    ///
    /// ROUND-4/5 UAF FIX: this lock ALSO now serializes every core call an
    /// orphaned copy task can make — `copyCell`, and (round 5) `startJump`/
    /// `jumpStatus` (the `advanceFrontier` pre-pass BEFORE the fetch loop) —
    /// against `close()`'s {set `isClosed`; call `ls_close`}; see each
    /// method's doc comment. `close()` takes this lock too (never the window
    /// lane's `lock` alone), so an orphaned copy build (uncancellable
    /// mid-loop) can no longer race a concurrent or prior `close()` onto a
    /// freed `doc` through ANY of its three core calls. Window ops
    /// (`setWindow`/`sourceRow`, guarded only by `lock`) are untouched by
    /// this, so copy still runs fully concurrent with scrolling (AC4).
    let copyBufferLock = NSLock()
    var copyBuffer: [UInt8] = []

    public let columnCount: Int
    public let dialect: DialectReport
    /// Compatibility view required by the frozen `DocumentSession` contract.
    /// The live app uses `columnLabels(_:)` instead, so opening a wide document
    /// never allocates one Swift String per header. Callers that explicitly ask
    /// for this legacy property receive a caller-owned, batched snapshot.
    public var headerCells: [String]? {
        guard dialect.hasHeader else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [] }
        // This legacy compatibility accessor is intentionally eager only when
        // explicitly invoked (the app never invokes it for a core session).
        // Keep it on the established window-lane primitive so older cores and
        // the frozen pre-column-config bridge tests retain their behavior.
        return (0..<columnCount).map { Self.copyCell(ls_header_cell(doc, UInt32($0))) }
    }

    init(path: String, forcing override: DialectOverride) throws(DocumentOpenError) {
        var options = ls_open_options(
            separator: Self.abiSeparator(override.separator),
            quote: Self.abiQuote(override.quote),
            header: Self.abiHeader(override.header),
            index_mode: Int32(LS_INDEX_AUTO),
            encoding: Self.abiEncodingOption(override.encoding)
        )
        var handle: OpaquePointer?
        let status = path.withCString { ls_open($0, &options, &handle) }
        if let error = DocumentOpenError(abiCode: Int32(status.rawValue)) {
            throw error
        }
        guard let doc = handle else { throw DocumentOpenError.ioFailure }
        self.doc = doc

        columnCount = Int(ls_column_count(doc))
        let rawDialect = ls_dialect_get(doc)
        dialect = DialectReport(
            separator: rawDialect.separator,
            quote: rawDialect.has_quote ? rawDialect.quote : nil,
            hasHeader: rawDialect.header,
            separatorForced: rawDialect.separator_forced,
            quoteForced: rawDialect.quote_forced,
            headerForced: rawDialect.header_forced,
            encoding: Self.abiEncoding(rawDialect.encoding),
            encodingForced: rawDialect.encoding_forced
        )
    }

    /// Adopt an already-open core handle (the DONE doc a network open-job
    /// produced via `ls_open_url_start`). Reads the same fixed-at-open facts as
    /// the path initializer; the doc then follows the normal `ls_close`
    /// lifecycle exactly like a local open.
    private init(adopting doc: OpaquePointer) {
        self.doc = doc
        columnCount = Int(ls_column_count(doc))
        let rawDialect = ls_dialect_get(doc)
        dialect = DialectReport(
            separator: rawDialect.separator,
            quote: rawDialect.has_quote ? rawDialect.quote : nil,
            hasHeader: rawDialect.header,
            separatorForced: rawDialect.separator_forced,
            quoteForced: rawDialect.quote_forced,
            headerForced: rawDialect.header_forced,
            encoding: Self.abiEncoding(rawDialect.encoding),
            encodingForced: rawDialect.encoding_forced
        )
    }

    /// Blocking network open (runs on `CoreSessionOpener.openQueue`): starts the
    /// core job, polls it to a terminal state, and maps the result. A disallowed
    /// scheme / malformed URL fails synchronously as `.invalidArgument`.
    static func openURLSync(
        _ url: String,
        forcing override: DialectOverride,
        onProgress: @escaping @Sendable (NetworkOpenProgress) -> Void,
        cancelToken: NetworkOpenCancelToken
    ) throws(NetworkOpenError) -> CoreDocumentSession {
        var options = ls_open_options(
            separator: abiSeparator(override.separator),
            quote: abiQuote(override.quote),
            header: abiHeader(override.header),
            index_mode: Int32(LS_INDEX_AUTO),
            encoding: abiEncodingOption(override.encoding)
        )
        let job: OpaquePointer? = url.withCString { cptr in
            ls_open_url_start(cptr, url.utf8.count, &options)
        }
        guard let job else { throw NetworkOpenError.ioFailure } // handle-alloc failure
        defer { ls_net_open_release(job) }
        while true {
            if cancelToken.isCancelled {
                ls_net_open_cancel(job)
            }
            let snapshot = ls_net_open_poll(job)
            // ARCH AC9 / round-2 review finding 1: report a LIVE snapshot every
            // tick (not only start/terminal) so the always-visible progress
            // affordance shows real, incrementally-updating bytes/percentage.
            onProgress(NetworkOpenProgress(
                abiState: Int32(snapshot.state.rawValue), progress: snapshot.progress,
                bytesFetched: snapshot.bytes_fetched, bytesTotal: snapshot.bytes_total,
                abiError: Int32(snapshot.error.rawValue), httpStatus: snapshot.http_status
            ))
            switch snapshot.state.rawValue {
            case ls_net_open_state.RawValue(LS_NET_OPEN_DONE.rawValue):
                guard let raw = snapshot.doc else { throw NetworkOpenError.ioFailure }
                return CoreDocumentSession(adopting: raw)
            case ls_net_open_state.RawValue(LS_NET_OPEN_FAILED.rawValue):
                throw NetworkOpenError(abiCode: Int32(snapshot.error.rawValue),
                                       httpStatus: snapshot.http_status) ?? .unreachable
            case ls_net_open_state.RawValue(LS_NET_OPEN_CANCELLED.rawValue):
                throw NetworkOpenError.cancelled
            default:
                Thread.sleep(forTimeInterval: 0.005) // PENDING / FETCHING: poll again
            }
        }
    }

    deinit { close() }

    public func rowCount() -> RowCountInfo {
        let counts = ls_row_count_get(doc)
        return RowCountInfo(count: counts.count, isExact: counts.exact)
    }

    public func indexProgress() -> ScanProgress {
        let poll = ls_index_poll(doc)
        return ScanProgress(bytesScanned: poll.bytes_scanned, bytesTotal: poll.bytes_total, isComplete: poll.complete)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        // ROUND-4 UAF FIX: also take `copyBufferLock` — the SAME lock
        // `copyCell` holds across its own {check isClosed; call
        // ls_cell_copy} — so setting `isClosed` and calling `ls_close` here
        // can never interleave with that. No other method takes both locks,
        // so this fixed acquisition order can't deadlock.
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        ls_close(doc)
    }

}
