/// The Swift-side progress/poll surface for a network open (ARCH-network-source
/// req 10), mirroring the core's `ls_net_open_status` poll snapshot. The model
/// polls the core's async open-job (`ls_net_open_poll`) and publishes THIS to
/// the always-visible progress affordance (no 500 ms delay gate — network
/// latency is unpredictable). C-free like the rest of Contracts: the Kit maps
/// the ABI struct into these using the raw-Int32 initializers below.

/// The async open-job state, mirroring `ls_net_open_state` 1:1. The mapping is
/// pinned by a frozen test against the C module (`LS_NET_OPEN_*`).
public enum NetworkOpenState: Sendable, Equatable {
    /// LS_NET_OPEN_PENDING (0): probing range support (the initial request is in
    /// flight).
    case pending
    /// LS_NET_OPEN_FETCHING (1): head bytes are being fetched (range mode) or the
    /// resource is being downloaded sequentially (fallback mode).
    case fetching
    /// LS_NET_OPEN_DONE (2): the document is open. Terminal.
    case done
    /// LS_NET_OPEN_FAILED (3): the open failed (see the error). Terminal.
    case failed
    /// LS_NET_OPEN_CANCELLED (4): the open was cancelled. Terminal.
    case cancelled

    /// Maps a raw `ls_net_open_state` value; nil for an unknown code.
    public init?(abiState: Int32) {
        switch abiState {
        case 0: self = .pending
        case 1: self = .fetching
        case 2: self = .done
        case 3: self = .failed
        case 4: self = .cancelled
        default: return nil
        }
    }

    /// True for DONE / FAILED / CANCELLED (polling can stop).
    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        case .pending, .fetching: return false
        }
    }
}

/// One network-open progress snapshot (mirrors `ls_net_open_status`, minus the
/// core-owned `doc` pointer the Kit consumes internally).
public struct NetworkOpenProgress: Sendable, Equatable {
    public let state: NetworkOpenState
    /// The head-fetch fraction in [0, 1] when the total length is known, or nil
    /// when it is not (`LS_NET_PROGRESS_UNKNOWN` / -1.0 from the ABI) — the UI
    /// then shows an indeterminate spinner plus the live byte counter.
    public let fraction: Double?
    /// Bytes fetched so far (monotone within one open).
    public let bytesFetched: UInt64
    /// Total resource length in bytes, or 0 when unknown.
    public let bytesTotal: UInt64
    /// The failure, valid only when `state == .failed`.
    public let error: NetworkOpenError?

    public init(
        state: NetworkOpenState,
        fraction: Double?,
        bytesFetched: UInt64,
        bytesTotal: UInt64,
        error: NetworkOpenError?
    ) {
        self.state = state
        self.fraction = fraction
        self.bytesFetched = bytesFetched
        self.bytesTotal = bytesTotal
        self.error = error
    }

    /// Maps the raw ABI poll fields into a snapshot. `progress` is the ABI's
    /// double (`LS_NET_PROGRESS_UNKNOWN` == -1.0 becomes `fraction == nil`).
    public init(
        abiState: Int32,
        progress: Double,
        bytesFetched: UInt64,
        bytesTotal: UInt64,
        abiError: Int32,
        httpStatus: Int32
    ) {
        self.state = NetworkOpenState(abiState: abiState) ?? .failed
        self.fraction = progress < 0 ? nil : progress
        self.bytesFetched = bytesFetched
        self.bytesTotal = bytesTotal
        self.error = NetworkOpenError(abiCode: abiError, httpStatus: httpStatus)
    }
}

/// Which kind of open produced a document — the axis the cold-start timing
/// marker policy keys on (ARCH-network-source req 12 / AC10).
public enum DocumentOpenKind: Sendable, Equatable {
    case local
    case network
}

public extension TimingMarker {
    /// AC10: the cold-start `first_rows_visible_ms` marker is emitted ONLY for a
    /// LOCAL open. A NETWORK open explicitly skips it — the <500 ms cold-start
    /// budget does not apply (network latency is unbounded), so emitting an
    /// unmeasured, unbudgeted marker would be dead instrumentation; the network
    /// open's own always-visible progress affordance is its "we're working"
    /// signal instead. The app MUST route its marker emission through this
    /// policy so a network open never fires the marker while local opens still
    /// do (regression-guarded by the frozen local cold-start tests).
    static func emitsFirstRowsMarker(for kind: DocumentOpenKind) -> Bool {
        switch kind {
        case .local: return true
        case .network: return false
        }
    }
}
