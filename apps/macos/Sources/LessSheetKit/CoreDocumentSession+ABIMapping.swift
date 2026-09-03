import CLessSheet
import Contracts
import Foundation

// Stateless value mappers between the Contracts types and the C ABI structs.
extension CoreDocumentSession {
    static func abiSeparator(_ separator: SeparatorOverride) -> Int32 {
        switch separator {
        case .sniff: Int32(LS_SNIFF)
        case let .forced(byte): Int32(byte)
        }
    }

    static func abiQuote(_ quote: QuoteOverride) -> Int32 {
        switch quote {
        case .sniff: Int32(LS_SNIFF)
        case .none: Int32(LS_QUOTE_NONE)
        case let .forced(byte): Int32(byte)
        }
    }

    static func abiHeader(_ header: HeaderOverride) -> Int32 {
        switch header {
        case .sniff: Int32(LS_SNIFF)
        case .forcedOn: Int32(LS_HEADER_ON)
        case .forcedOff: Int32(LS_HEADER_OFF)
        }
    }

    static func abiEncodingOption(_ encoding: EncodingOverride) -> Int32 {
        switch encoding {
        case .automatic: Int32(LS_ENCODING_AUTO)
        case .utf8: Int32(LS_ENCODING_UTF8)
        case .utf16LE: Int32(LS_ENCODING_UTF16LE)
        case .utf16BE: Int32(LS_ENCODING_UTF16BE)
        case .latin1: Int32(LS_ENCODING_LATIN1)
        case .windows1252: Int32(LS_ENCODING_WINDOWS1252)
        }
    }

    /// The RESOLVED encoding the core reports — always a concrete value, never
    /// LS_ENCODING_AUTO.
    static func abiEncoding(_ raw: UInt8) -> TextEncoding {
        TextEncoding(rawValue: raw) ?? .utf8
    }

    static func abiOp(_ comparison: SearchOperator) -> ls_search_op {
        switch comparison {
        case .equals: LS_SEARCH_OP_EQ
        case .notEquals: LS_SEARCH_OP_NE
        case .lessThan: LS_SEARCH_OP_LT
        case .greaterThan: LS_SEARCH_OP_GT
        case .lessOrEqual: LS_SEARCH_OP_LE
        case .greaterOrEqual: LS_SEARCH_OP_GE
        }
    }

    static func abiDir(_ dir: SearchDirection) -> ls_search_dir {
        switch dir {
        case .forward: LS_SEARCH_FORWARD
        case .backward: LS_SEARCH_BACKWARD
        }
    }

    static func swiftColumnType(_ value: ls_column_type) -> ColumnType {
        ColumnType(
            kind: ColumnKind(rawValue: Int(value.kind)) ?? .unknown,
            decimalPrecision: value.decimal_precision == UInt64.max
                ? nil : value.decimal_precision,
            decimalScale: value.decimal_scale == Int64.min
                ? nil : value.decimal_scale,
            datetimeSemantics: ColumnDatetimeSemantics(rawValue: Int(value.datetime_semantics)) ?? .none,
            datetimeFractionDigits: value.datetime_fraction_digits == UInt32.max
                ? nil : value.datetime_fraction_digits
        )
    }

    static func swiftMetadata(_ value: ls_column_metadata) -> ColumnMetadata {
        let flags = value.presence_flags
        return ColumnMetadata(
            column: Int(value.column), generation: value.generation,
            declared: swiftColumnType(value.declared), inferred: swiftColumnType(value.inferred),
            overrideType: swiftColumnType(value.override), effective: swiftColumnType(value.effective),
            proposal: swiftColumnType(value.proposal),
            effectiveSource: ColumnTypeSource(rawValue: Int(value.effective_source)) ?? .none,
            inferenceState: ColumnInferenceState(rawValue: Int(value.inference_state)) ?? .unrequested,
            confidence: ColumnConfidence(rawValue: Int(value.confidence)) ?? .none,
            nullPolicy: ColumnNullPolicy(rawValue: Int(value.null_policy)) ?? .none,
            conflictState: ColumnConflictState(rawValue: Int(value.conflict_state)) ?? .none,
            nullSentinelBytes: flags & UInt32(LS_COLUMN_HAS_NULL_SENTINEL) != 0 ? Int(value.null_sentinel_bytes) : nil,
            evidenceCount: value.evidence_count, sampledRowCount: value.sampled_row_count,
            sampledDecodedBytes: value.sampled_decoded_bytes, emptyCount: value.empty_count,
            nullCount: value.null_count, conflictCount: value.conflict_count,
            conflictSourceRow: value.conflict_source_row == UInt64(LS_NO_ROW) ? nil : value.conflict_source_row,
            hasProposal: flags & UInt32(LS_COLUMN_HAS_PROPOSAL) != 0
        )
    }

    static func abiColumnType(_ type: ColumnType) -> ls_column_type {
        var value = ls_column_type()
        value.struct_size = UInt32(MemoryLayout<ls_column_type>.size)
        value.abi_version = UInt32(LS_COLUMN_METADATA_ABI_VERSION)
        value.kind = UInt32(type.kind.rawValue)
        value.flags = 0
        value.decimal_precision = UInt64.max
        value.decimal_scale = Int64.min
        value.datetime_semantics = UInt32(type.datetimeSemantics.rawValue)
        value.datetime_fraction_digits = UInt32.max
        value.reserved = 0
        return value
    }

    /// Copies borrowed core bytes into an owned String — see `String(lossyUTF8:)`
    /// for why the decode is lossy rather than failable.
    static func copyCell(_ str: ls_str) -> String {
        guard str.len > 0, let ptr = str.ptr else { return "" }
        return String(lossyUTF8: UnsafeBufferPointer(start: ptr, count: str.len))
    }
}
