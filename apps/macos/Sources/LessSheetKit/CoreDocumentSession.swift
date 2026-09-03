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

    /// A dedicated queue for the core's O(head) open. Keeps the blocking
    /// `ls_open` off the calling actor STRUCTURALLY, rather than relying on a
    /// nonisolated-async executor default a future language mode could change.
    private static let openQueue = DispatchQueue(label: "less-sheet.core-open", qos: .userInitiated)

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
            throw DocumentOpenError.ioFailure   // unreachable: init is a typed throw
        }
    }

    /// The protocol's plain network open — a thin wrapper over the tracking
    /// overload with a no-op progress callback. Callers that want the live
    /// progress affordance and an explicit Cancel button use that one instead.
    public func openURL(
        _ url: String, forcing override: DialectOverride
    ) async throws(NetworkOpenError) -> any DocumentSession {
        try await openURL(url, forcing: override, onProgress: { _ in }, cancelToken: NetworkOpenCancelToken())
    }

    /// Drives the core's async open-job, reporting a live snapshot on every poll
    /// tick so the UI can show a real, incrementally-updating counter.
    ///
    /// `cancelToken` is explicit because this runs on a dispatch queue with no
    /// ambient Swift Task to observe `Task.isCancelled` on; a caller-owned token
    /// is the only reliable cancel signal here (Task cancellation also fires it).
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

/// Thread-safe cancel signal for an in-flight `openURL`, polled between core
/// polls. Backs the UI's Cancel button; Swift Task cancellation also fires it.
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
    // These are `internal`, not `private`, so the cohesive method groups split
    // into same-module extensions (`+Window`, `+Search`, `+Copy`, `+Columns`,
    // `+ABIMapping`) can reach them. Not public API either way.
    let doc: OpaquePointer
    let lock = NSLock()
    var isClosed = false
    /// Guards every poll/control-lane call an ORPHANED background task can still
    /// make — the copy stream, and the jump primitives its frontier pre-pass
    /// uses — against `close()`'s {set `isClosed`; `ls_close`}, which takes this
    /// same lock. That is what stops a copy the app has merely ASKED to stop
    /// from reaching a freed `doc`. Deliberately NOT the window lane's `lock`,
    /// so a copy still runs fully concurrent with scrolling.
    let copyBufferLock = NSLock()
    /// A scratch buffer for `copyCell`, grown on demand and never shrunk. A large
    /// copy calls it per cell, and allocating plus zero-filling a fresh ~1 MiB
    /// buffer every time would dominate the whole build; the call still passes
    /// ITS OWN `maxBytes` as `buf_len`, so a smaller cap truncates correctly
    /// behind a larger buffer.
    var copyBuffer: [UInt8] = []

    public let columnCount: Int
    public let dialect: DialectReport
    /// Required by the `DocumentSession` contract, but never used by the live
    /// app — it reads `columnLabels(_:)` instead, so opening a wide document
    /// never allocates one Swift String per header.
    public var headerCells: [String]? {
        guard dialect.hasHeader else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return [] }
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

    /// Adopts the already-open handle a network open-job produced. From here the
    /// doc follows the normal `ls_close` lifecycle, exactly like a local open.
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
        // Both lanes, so neither a window op nor an orphaned copy can be inside
        // a core call while `ls_close` runs. This is the ONLY method that takes
        // both locks, so the order cannot deadlock.
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        ls_close(doc)
    }

}
