import Contracts

/// Pure view-model derivation: (snapshot, header override) -> DisplayTable.
///
/// SEED STATE: unimplemented stub — conforms (conformance green) and fails
/// every behavior test (suite red). Implement the pinned semantics documented
/// on TableDisplayDeriving (header application, toggle re-derivation, generic
/// A…Z/AA/AB column names, rectangularity).
public struct TableDisplayDeriver: TableDisplayDeriving {
    public init() {}

    public func derive(from snapshot: HeadSnapshot, firstRowIsHeader: Bool) -> DisplayTable {
        _ = snapshot
        _ = firstRowIsHeader
        return .empty // stub: unimplemented
    }
}
