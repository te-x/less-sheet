/// Distinct document-open failures, mirroring the core ABI's `ls_status`
/// failure codes (workspace-frozen `api/lesssheet.h`). One Swift case per ABI
/// code; the mapping below is pinned by a frozen test against the C module.
public enum DocumentOpenError: Error, Equatable, Sendable {
    /// LS_ERROR_NOT_FOUND (1): the path does not name an existing file.
    case notFound
    /// LS_ERROR_PERMISSION_DENIED (2): the file exists but cannot be read by
    /// this process.
    case permissionDenied
    /// LS_ERROR_IO (3): any other open/read failure, including paths that
    /// exist but cannot be read as a file (e.g. a directory).
    case ioFailure
    /// LS_ERROR_INVALID_ARGUMENT (4): the open options broke the API
    /// contract (a field outside its domain, or forced separator == forced
    /// quote). A correct UI never triggers this — `DialectComposing`
    /// validates selections first — but the mapping is total.
    case invalidArgument

    /// Maps a raw ABI status code to the Swift error.
    /// Returns nil for LS_OK (0) and for unknown codes.
    public init?(abiCode: Int32) {
        switch abiCode {
        case 1: self = .notFound
        case 2: self = .permissionDenied
        case 3: self = .ioFailure
        case 4: self = .invalidArgument
        default: return nil
        }
    }
}
