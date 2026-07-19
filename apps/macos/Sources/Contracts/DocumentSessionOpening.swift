// Document-open entry points, extracted from `DocumentSession.swift` (which
// owns the live windowed-session surface) to keep each file within the
// file-length budget. Same module, so the split is source-only — every type
// referenced here (`DialectOverride`, `DocumentOpenError`, `NetworkOpenError`,
// `DocumentSession`) lives alongside it in `Contracts`.

/// Opens document sessions through the core's C ABI. This is the ONLY entry
/// to document data; all user-facing opens (panel, launch-with-file, CLI,
/// drag & drop, dialect re-open) funnel into one call of this.
///
/// Contract:
/// - `async` and safe to call from any actor, INCLUDING the main actor: the
///   implementation never blocks the main thread (the core's O(head) open
///   runs off it).
/// - The session's background index runs in AUTO mode (starts at open).
/// - An empty file is NOT an error: it yields a session with 0 columns and
///   an exact row count of 0.
/// - Failures throw the distinct `DocumentOpenError` mapped from the ABI
///   code (including `.invalidArgument` for an out-of-domain override).
/// - A dialect change is a RE-OPEN: open the same path again with the
///   composed override and close the old session (ARCH req. 10 — the index
///   restarts; hidden-column state is handled per `ColumnVisibilityManaging`,
///   and find state per `FindControlling.invalidated` — results clear, the
///   typed query survives).
public protocol DocumentSessionOpening: Sendable {
    func open(path: String, forcing override: DialectOverride) async throws(DocumentOpenError) -> any DocumentSession

    /// Open a CSV / .csv.gz served over HTTP(S) (ARCH-network-source req 7) —
    /// ADDITIVE to `open(path:forcing:)`, never replacing it. `url` is the
    /// http:// or https:// URL as typed; `override` is the SAME parse-profile
    /// override `open` takes (a network document supports every dialect/encoding
    /// override). Unlike a local open this is never instant: the implementation
    /// drives the core's async open-job (`ls_open_url_start` -> poll
    /// `ls_net_open_poll` -> `ls_net_open_release`), publishing progress to the
    /// always-visible affordance (`NetworkOpenProgress`) and honoring Task
    /// cancellation (which cancels the fetch and throws `.cancelled`). Returns
    /// the live session once the open is DONE.
    ///
    /// Contract:
    /// - `async` and safe from any actor incl. the main actor (never blocks it).
    /// - The URL is shown as-is by the caller; no recents entry, no cold-start
    ///   marker (see `TimingMarker.emitsFirstRowsMarker(for:)` — AC10).
    /// - Failures throw the distinct `NetworkOpenError` mapped 1:1 from the ABI
    ///   `ls_net_status` (incl. `.invalidArgument` for a non-http/https scheme,
    ///   rejected synchronously with no network, and `.httpStatus(_)` carrying
    ///   the numeric server status). Re-opening the same URL always re-fetches.
    func openURL(_ url: String, forcing override: DialectOverride) async throws(NetworkOpenError) -> any DocumentSession
}

public extension DocumentSessionOpening {
    /// DEFAULT (RED seed) for the network URL open: throws `.unreachable` so
    /// NOTHING opens through it. Keeps existing conformers compiling before the
    /// URL-open bridge lands — `openURL` is a PROTOCOL REQUIREMENT (declared in
    /// the body above, not only here), so a real override is dispatched through
    /// `any DocumentSessionOpening` via the witness table. A conformer wires it
    /// to the core by OVERRIDING this to start `ls_open_url_start`, poll
    /// `ls_net_open_poll` to DONE (mapping `ls_net_status` -> `NetworkOpenError`
    /// on failure), and release the job — which flips the URL-open tests from RED
    /// (this default: throws `.unreachable`, and a disallowed scheme does NOT map
    /// to `.invalidArgument`) to GREEN (the real open, incl. synchronous scheme
    /// rejection through the core).
    func openURL(
        _ url: String,
        forcing override: DialectOverride
    ) async throws(NetworkOpenError) -> any DocumentSession {
        throw NetworkOpenError.unreachable
    }
}
