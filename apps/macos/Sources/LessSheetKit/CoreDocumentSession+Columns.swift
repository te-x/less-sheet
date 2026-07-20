import CLessSheet
import Contracts
import Foundation

// MARK: - Column metadata bridge (labels / inference / overrides).
// Split out of CoreDocumentSession.swift as a same-module extension (pure code
// motion) so the primary type body stays within budget; reaches the session's
// `internal` doc/copyBufferLock/isClosed members and the `internal static` ABI
// mappers in CoreDocumentSession+ABIMapping.swift. All calls stay on the
// poll/control lane under `copyBufferLock`, exactly as before.
extension CoreDocumentSession {
    /// Copies a bounded caller-selected label batch through the additive ABI.
    /// No borrowed core string escapes this method; missing/empty labels are
    /// represented by nil and truncation remains attached to the byte identity.
    public func columnLabels(_ ids: [UInt32]) -> [ColumnHeaderIdentity?] {
        guard ids.count <= Int(LS_COLUMN_BATCH_MAX) else { return [] }
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return [] }

        var spans = [ls_column_label_span](repeating: ls_column_label_span(), count: ids.count)
        func prepareSpans() {
            for index in spans.indices {
                spans[index].struct_size = UInt32(MemoryLayout<ls_column_label_span>.size)
                spans[index].abi_version = UInt32(LS_COLUMN_METADATA_ABI_VERSION)
            }
        }
        prepareSpans()
        var required = 0
        let spanCount = UInt32(spans.count)
        let first = ids.withUnsafeBufferPointer { idBuffer in
            spans.withUnsafeMutableBufferPointer { spanBuffer in
                ls_column_labels_copy_many(doc, idBuffer.baseAddress, UInt32(ids.count),
                                           spanBuffer.baseAddress, spanCount,
                                           nil, 0, &required)
            }
        }
        guard first.rawValue == LS_COLUMN_OK.rawValue else { return [] }

        var arena = [UInt8](repeating: 0, count: required)
        let arenaCount = arena.count
        prepareSpans()
        let second = ids.withUnsafeBufferPointer { idBuffer in
            spans.withUnsafeMutableBufferPointer { spanBuffer in
                arena.withUnsafeMutableBufferPointer { arenaBuffer in
                    ls_column_labels_copy_many(doc, idBuffer.baseAddress, UInt32(ids.count),
                                               spanBuffer.baseAddress, spanCount,
                                               arenaBuffer.baseAddress, arenaCount, &required)
                }
            }
        }
        guard second.rawValue == LS_COLUMN_OK.rawValue else { return [] }

        return spans.map { span in
            guard span.flags & UInt32(LS_COLUMN_LABEL_PRESENT) != 0,
                  let offset = Int(exactly: span.offset), let length = Int(exactly: span.len),
                  offset >= 0, length >= 0, offset <= arena.count, length <= arena.count - offset else { return nil }
            return ColumnHeaderIdentity(
                bytes: Array(arena[offset..<(offset + length)]),
                truncated: span.flags & UInt32(LS_COLUMN_LABEL_TRUNCATED) != 0
            )
        }
    }

    /// Replaces the core's sparse inference set. The caller coordinates grid
    /// and panel IDs before calling, so the worker sees one desired set.
    public func requestColumnInference(_ ids: [UInt32]) -> Bool {
        guard !ids.isEmpty, ids.count <= Int(LS_COLUMN_BATCH_MAX) else { return false }
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return false }
        return ids.withUnsafeBufferPointer {
            ls_column_inference_request(doc, $0.baseAddress, UInt32(ids.count)).rawValue == LS_COLUMN_OK.rawValue
        }
    }

    public func columnInferenceState() -> (active: Bool, generation: UInt64) {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return (false, 0) }
        var status = ls_column_inference_status()
        status.struct_size = UInt32(MemoryLayout<ls_column_inference_status>.size)
        status.abi_version = UInt32(LS_COLUMN_METADATA_ABI_VERSION)
        guard ls_column_metadata_poll(doc, &status).rawValue == LS_COLUMN_OK.rawValue else { return (false, 0) }
        let active = status.state == UInt32(LS_COLUMN_JOB_QUEUED.rawValue)
            || status.state == UInt32(LS_COLUMN_JOB_RUNNING.rawValue)
        return (active, status.metadata_generation)
    }

    /// Current finite inference progress for panel accessibility/presentation;
    /// nil when no inference job is active.
    public func columnInferenceProgress() -> Double? {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return nil }
        var status = ls_column_inference_status()
        status.struct_size = UInt32(MemoryLayout<ls_column_inference_status>.size)
        status.abi_version = UInt32(LS_COLUMN_METADATA_ABI_VERSION)
        guard ls_column_metadata_poll(doc, &status).rawValue == LS_COLUMN_OK.rawValue else { return nil }
        let active = status.state == UInt32(LS_COLUMN_JOB_QUEUED.rawValue)
            || status.state == UInt32(LS_COLUMN_JOB_RUNNING.rawValue)
        return active ? min(max(status.progress, 0), 1) : nil
    }

    /// Coherently snapshots a bounded metadata batch into Swift value types.
    public func columnMetadata(_ ids: [UInt32]) -> [ColumnMetadata] {
        guard ids.count <= Int(LS_COLUMN_BATCH_MAX) else { return [] }
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return [] }
        var items = [ls_column_metadata](repeating: ls_column_metadata(), count: ids.count)
        for index in items.indices {
            items[index].struct_size = UInt32(MemoryLayout<ls_column_metadata>.size)
            items[index].abi_version = UInt32(LS_COLUMN_METADATA_ABI_VERSION)
        }
        var generation: UInt64 = 0
        let itemCount = UInt32(items.count)
        let result = ids.withUnsafeBufferPointer { idBuffer in
            items.withUnsafeMutableBufferPointer { itemBuffer in
                ls_column_metadata_get_many(doc, idBuffer.baseAddress, UInt32(ids.count),
                                            itemBuffer.baseAddress, itemCount, &generation)
            }
        }
        guard result.rawValue == LS_COLUMN_OK.rawValue else { return [] }
        return items.map(Self.swiftMetadata)
    }

    public func setColumnOverride(_ type: ColumnType?, column: UInt32) -> Bool {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return false }
        guard let type else {
            return ls_column_override_clear(doc, column).rawValue == LS_COLUMN_OK.rawValue
        }
        var abi = Self.abiColumnType(type)
        return ls_column_override_set(doc, column, &abi).rawValue == LS_COLUMN_OK.rawValue
    }

    public func setColumnNullSentinel(_ sentinel: [UInt8]?, column: UInt32) -> Bool {
        copyBufferLock.lock()
        defer { copyBufferLock.unlock() }
        guard !isClosed else { return false }
        guard let sentinel else {
            return ls_column_null_sentinel_clear(doc, column).rawValue == LS_COLUMN_OK.rawValue
        }
        return sentinel.withUnsafeBufferPointer {
            ls_column_null_sentinel_set(doc, column, $0.baseAddress, $0.count).rawValue == LS_COLUMN_OK.rawValue
        }
    }
}
