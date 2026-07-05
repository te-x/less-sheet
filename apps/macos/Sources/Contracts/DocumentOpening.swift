/// Opens a document through the core's C ABI and returns an immutable head
/// snapshot. This is the ONLY way the app obtains document data; all three
/// user-facing entries (File > Open…, launch-with-file, CLI argument) funnel
/// into one call of this.
///
/// Contract:
/// - `async` and safe to call from any actor, INCLUDING the main actor: the
///   implementation must never block the main thread (core work runs off it;
///   with head-only reads it is near-instant regardless).
/// - Copies all cell text out of the core (see `HeadSnapshot`) and closes the
///   core handle before returning — no core resources remain held afterwards.
/// - An empty file is NOT an error: it returns `HeadSnapshot.empty`.
/// - Failures throw the distinct `DocumentOpenError` mapped from the ABI code.
public protocol DocumentOpening: Sendable {
    func openHead(path: String) async throws(DocumentOpenError) -> HeadSnapshot
}
