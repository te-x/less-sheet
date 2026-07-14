/// Distinct network-open failures, mirroring the core ABI's `ls_net_status`
/// codes (workspace-frozen `api/lesssheet.h`, NETWORK SOURCE EXTENSION) 1:1 —
/// exactly as `DocumentOpenError` mirrors `ls_status`. Network failures are a
/// materially different taxonomy from local-file failures, so they are a
/// SEPARATE type (never collapsed into `DocumentOpenError`). One Swift case per
/// ABI code; the mapping below is pinned by a frozen test against the C module
/// (`LS_NET_*`). See `DocumentSessionOpening.openURL`.
public enum NetworkOpenError: Error, Equatable, Sendable {
    /// LS_NET_ERROR_INVALID_ARGUMENT (1): the URL scheme is not http/https, the
    /// URL is malformed, or an open option is out of its domain. Rejected
    /// synchronously by the core; no network is touched.
    case invalidArgument
    /// LS_NET_ERROR_UNREACHABLE (2): DNS resolution or TCP/TLS connection
    /// failure — the host could not be reached.
    case unreachable
    /// LS_NET_ERROR_TIMEOUT (3): no forward progress within the connect/read
    /// timeout.
    case timeout
    /// LS_NET_ERROR_HTTP_STATUS (4): the server returned a non-2xx status after
    /// following redirects; the numeric status is carried here (e.g. 404, and
    /// 401/403 for a URL requiring authentication — there is no credential UI).
    case httpStatus(Int)
    /// LS_NET_ERROR_TOO_MANY_REDIRECTS (5): the redirect chain exceeded the
    /// fixed cap.
    case tooManyRedirects
    /// LS_NET_ERROR_IO (6): local spool-file creation/write failure.
    case io
    /// LS_NET_ERROR_CANCELLED (7): the open was cancelled before completing.
    case cancelled

    /// Maps a raw ABI status code (`ls_net_status`) — plus the companion
    /// `ls_net_open_status.http_status` for the LS_NET_ERROR_HTTP_STATUS case —
    /// to the Swift error. Returns nil for LS_NET_OK (0) and for unknown codes.
    public init?(abiCode: Int32, httpStatus: Int32 = 0) {
        switch abiCode {
        case 1: self = .invalidArgument
        case 2: self = .unreachable
        case 3: self = .timeout
        case 4: self = .httpStatus(Int(httpStatus))
        case 5: self = .tooManyRedirects
        case 6: self = .io
        case 7: self = .cancelled
        default: return nil
        }
    }
}
