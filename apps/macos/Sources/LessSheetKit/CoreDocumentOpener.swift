import CLessSheet
import Contracts

/// Swift wrapper over the core C ABI (`api/lesssheet.h` via CLessSheet).
///
/// SEED STATE: unimplemented stub — conforms (conformance green) and fails
/// every behavior test (suite red). Implement per the DocumentOpening
/// contract: call ls_open off the main thread, copy header/dimension/cell
/// data into a HeadSnapshot (String(decoding:as: UTF8.self) replaces invalid
/// bytes with U+FFFD), ls_close before returning, map ls_status failures via
/// DocumentOpenError(abiCode:).
public struct CoreDocumentOpener: DocumentOpening {
    public init() {}

    public func openHead(path: String) async throws(DocumentOpenError) -> HeadSnapshot {
        _ = path
        throw .io // stub: unimplemented
    }
}
