/// Swift value model for column-config metadata (ARCH-column-config) — the
/// Swift mirror of the additive `api/lesssheet.h` COLUMN METADATA EXTENSION.
/// These are ordinary Swift value types (NOT extern C layout): the
/// `CoreDocumentSession` bridge maps each fixed-layout C snapshot
/// (`ls_column_metadata`, `ls_column_type`, `ls_column_inference_status`) into
/// these, and the display model (`ColumnDisplayFormatting`, `ColumnAligning`,
/// the panel) consumes them. Raw values match the C enum values EXACTLY so the
/// bridge is a direct `rawValue` map; UNSPECIFIED sentinels become `nil`.
///
/// PURE presentation layer over immutable source (PROJECT.md slice 9): the core
/// owns inference/typing; the frontend transforms. Nothing here parses cells or
/// calls the core.

/// Base type kind — mirrors `ls_column_type_kind`. Null is orthogonal (see
/// `ColumnNullPolicy`), never a base kind.
public enum ColumnKind: Int, Sendable, CaseIterable {
    case unknown = 0
    case unsupported = 1
    case text = 2
    case boolean = 3
    case integer = 4
    case decimal = 5
    case date = 6
    case datetime = 7
}

/// Which slot resolved the effective type — mirrors `ls_column_type_source`.
public enum ColumnTypeSource: Int, Sendable {
    case none = 0
    case declared = 1
    case inferred = 2
    case override = 3
}

/// Datetime wall-clock vs zoned semantics — mirrors `ls_column_datetime_semantics`.
public enum ColumnDatetimeSemantics: Int, Sendable {
    case none = 0
    case naive = 1
    case zoned = 2
}

/// Per-column inference lifecycle — mirrors `ls_column_inference_state`.
public enum ColumnInferenceState: Int, Sendable {
    case unrequested = 0
    case queued = 1
    case sampling = 2
    case provisional = 3
    case published = 4
}

/// Confidence in the published inferred type — mirrors `ls_column_confidence`.
public enum ColumnConfidence: Int, Sendable {
    case none = 0
    case low = 1
    case bounded = 2
    case exhaustive = 3
}

/// Null policy — mirrors `ls_column_null_policy_kind`.
public enum ColumnNullPolicy: Int, Sendable {
    case none = 0
    case sentinel = 1
}

/// Conflict / proposal state — mirrors `ls_column_conflict_state`.
public enum ColumnConflictState: Int, Sendable {
    case none = 0
    case observed = 1
    case proposed = 2
}

/// One type descriptor — mirrors `ls_column_type`. The metadata-only parameters
/// are `nil` when the C value is the UNSPECIFIED sentinel. `datetimeSemantics`
/// is `.none` outside a datetime kind.
public struct ColumnType: Equatable, Sendable {
    public let kind: ColumnKind
    /// Decimal coefficient digits after exact base-10 normalization (nil off decimal).
    public let decimalPrecision: UInt64?
    /// Decimal fractional places (may be negative for powers of ten; nil off decimal).
    public let decimalScale: Int64?
    public let datetimeSemantics: ColumnDatetimeSemantics
    /// Max observed 0…9 fractional-second digits (nil off datetime).
    public let datetimeFractionDigits: UInt32?

    public init(kind: ColumnKind,
                decimalPrecision: UInt64? = nil,
                decimalScale: Int64? = nil,
                datetimeSemantics: ColumnDatetimeSemantics = .none,
                datetimeFractionDigits: UInt32? = nil) {
        self.kind = kind
        self.decimalPrecision = decimalPrecision
        self.decimalScale = decimalScale
        self.datetimeSemantics = datetimeSemantics
        self.datetimeFractionDigits = datetimeFractionDigits
    }

    /// The canonical UNKNOWN descriptor (an absent slot).
    public static let unknown = ColumnType(kind: .unknown)
}

/// The coherent per-column snapshot — mirrors `ls_column_metadata`. The ABI
/// `override` slot is `overrideType` here (`override` is a Swift keyword).
public struct ColumnMetadata: Equatable, Sendable {
    public let column: Int
    /// This column's committed metadata generation; 0 == untouched.
    public let generation: UInt64
    public let declared: ColumnType
    public let inferred: ColumnType
    public let overrideType: ColumnType
    public let effective: ColumnType
    public let proposal: ColumnType
    public let effectiveSource: ColumnTypeSource
    public let inferenceState: ColumnInferenceState
    public let confidence: ColumnConfidence
    public let nullPolicy: ColumnNullPolicy
    public let conflictState: ColumnConflictState
    /// Length of the null sentinel bytes when a sentinel is set (may be 0).
    public let nullSentinelBytes: Int?
    public let evidenceCount: UInt64
    public let sampledRowCount: UInt64
    public let sampledDecodedBytes: UInt64
    public let emptyCount: UInt64
    public let nullCount: UInt64
    public let conflictCount: UInt64
    /// Representative conflicting source data-row (nil == none / LS_NO_ROW).
    public let conflictSourceRow: UInt64?
    public let hasProposal: Bool

    public init(column: Int, generation: UInt64,
                declared: ColumnType = .unknown, inferred: ColumnType = .unknown,
                overrideType: ColumnType = .unknown, effective: ColumnType = .unknown,
                proposal: ColumnType = .unknown,
                effectiveSource: ColumnTypeSource = .none,
                inferenceState: ColumnInferenceState = .unrequested,
                confidence: ColumnConfidence = .none,
                nullPolicy: ColumnNullPolicy = .none,
                conflictState: ColumnConflictState = .none,
                nullSentinelBytes: Int? = nil,
                evidenceCount: UInt64 = 0, sampledRowCount: UInt64 = 0,
                sampledDecodedBytes: UInt64 = 0, emptyCount: UInt64 = 0,
                nullCount: UInt64 = 0, conflictCount: UInt64 = 0,
                conflictSourceRow: UInt64? = nil, hasProposal: Bool = false) {
        self.column = column
        self.generation = generation
        self.declared = declared
        self.inferred = inferred
        self.overrideType = overrideType
        self.effective = effective
        self.proposal = proposal
        self.effectiveSource = effectiveSource
        self.inferenceState = inferenceState
        self.confidence = confidence
        self.nullPolicy = nullPolicy
        self.conflictState = conflictState
        self.nullSentinelBytes = nullSentinelBytes
        self.evidenceCount = evidenceCount
        self.sampledRowCount = sampledRowCount
        self.sampledDecodedBytes = sampledDecodedBytes
        self.emptyCount = emptyCount
        self.nullCount = nullCount
        self.conflictCount = conflictCount
        self.conflictSourceRow = conflictSourceRow
        self.hasProposal = hasProposal
    }
}

/// Horizontal cell/text alignment (ARCH-column-config "Automatic alignment").
public enum ColumnTextAlignment: Equatable, Sendable {
    case leading   // left
    case center
    case trailing  // right
}

/// The FIXED automatic-alignment rule (ARCH criterion 16). Implemented in
/// `LessSheetKit` and pinned by a frozen conformance test
/// (`let _: any ColumnAligning = ColumnAlignmentRules()`), like the other
/// view-model logic contracts.
///
/// Pinned semantics (no v1 control overrides these):
/// - text / unknown / unsupported → `.leading`;
/// - boolean → `.center`;
/// - integer / decimal / date / datetime → `.trailing`;
/// - a CONFLICT cell keeps its column's alignment (so `isConflict` never changes
///   the result — it is accepted only to make that invariant explicit and
///   testable);
/// - headers are always `.leading` (see `headerAlignment`).
public protocol ColumnAligning: Sendable {
    func alignment(for kind: ColumnKind, isConflict: Bool) -> ColumnTextAlignment
    var headerAlignment: ColumnTextAlignment { get }
}
