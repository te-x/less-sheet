import Contracts
import Foundation
import LessSheetKit
import Synchronization

/// The LAUNCH document's core open, started the instant its path is known, run
/// off the main thread, and handed to the model without ever blocking it.
///
/// Enqueuing the open as an ordinary main-actor task made it RUN-DEPENDENT
/// whether it started before AppKit and SwiftUI bring-up consumed the main
/// actor — measured beginning anywhere from 67 ms to 134 ms across runs of the
/// same launch — so the file I/O and head parse often landed on the tail of
/// launch instead of overlapping it, and the window rendered the launch state
/// before re-rendering the grid. Starting it here makes the overlap
/// deterministic and removes that extra render pass.
///
/// Launch-only and one-shot: every later open goes through the normal funnels,
/// unchanged. `adoptIfReady()` is main-actor-only and never waits on the open.
enum LaunchOpenPrewarm {
    /// `path` doubles as the "started" flag, set under the lock by whichever call
    /// wins the race to start.
    private struct State {
        var path: String?
        var outcome: Result<any DocumentSession, DocumentOpenError>?
        /// Set once the outcome has been handed out (or deliberately dropped).
        /// A late-landing open sees it and closes its own handle.
        var consumed = false
    }

    private static let state = Mutex(State())

    private enum StartDecision {
        /// This call won: it must kick off the open.
        case begin
        /// An earlier call already started this exact path.
        case mine
        /// A DIFFERENT path was prewarmed first.
        case foreign
    }

    /// The prewarmed outcome, handed out exactly once.
    private struct Claim {
        let path: String
        let outcome: Result<any DocumentSession, DocumentOpenError>
    }

    // MARK: - Starting

    /// Starts the launch open on a background thread. Idempotent: the first call
    /// wins, later ones are ignored.
    ///
    /// Returns true when `path` is the document this box owns. False means a
    /// DIFFERENT path was prewarmed first — the stale prewarm is then discarded
    /// so it can never be adopted, and the caller must use the normal funnel.
    @discardableResult
    static func start(path: String, forcing override: DialectOverride) -> Bool {
        guard LaunchTuning.applies else { return false }
        let decision: StartDecision = state.withLock { state in
            guard let owned = state.path else {
                state.path = path
                return .begin
            }
            return owned == path ? .mine : .foreign
        }
        switch decision {
        case .mine: return true
        case .foreign: discard(); return false
        case .begin: break
        }
        // The opener dispatches the blocking core call onto its own queue, so the
        // file I/O never occupies a cooperative-pool thread and nothing here
        // touches the main actor until the open has finished. Only WHEN the open
        // runs changes; what it reads does not.
        Task.detached(priority: .userInitiated) {
            let outcome: Result<any DocumentSession, DocumentOpenError>
            do {
                outcome = .success(try await CoreSessionOpener().open(path: path, forcing: override))
            } catch let error as DocumentOpenError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.ioFailure)   // unreachable: a typed throw
            }
            let stored = state.withLock { state -> Bool in
                guard !state.consumed else { return false }
                state.outcome = outcome
                return true
            }
            guard stored else {
                // Superseded while in flight: close the handle rather than leak it.
                if case let .success(session) = outcome { session.close() }
                return
            }
            // The window content may already have been built and found nothing to
            // claim, so offer the result once more. Exactly one attempt can win.
            await MainActor.run { adoptIfReady() }
        }
        return true
    }

    // MARK: - Launch routing

    /// Only the FIRST routed path can ever use the prewarm.
    @MainActor private static var launchRouteTaken = false

    /// Routes the launch document through the prewarm and adopts it if it has
    /// already landed. Returns false when the caller must use the normal funnel
    /// instead — the launch route is spent, or a different path owns the prewarm.
    @MainActor
    static func handleLaunchRoute(_ path: String, forcing override: DialectOverride) -> Bool {
        guard !launchRouteTaken else { return false }
        launchRouteTaken = true
        guard start(path: path, forcing: override) else { return false }
        adoptIfReady()
        return true
    }

    // MARK: - Adopting

    /// Hands the prewarmed outcome to the model, non-blocking and exactly once.
    /// If the open is still running this does nothing and the prewarm's own
    /// completion calls it again — so a slow disk can never delay the window: the
    /// worst case is the unoptimized behavior, where it comes up on the launch
    /// state and the document lands a moment later.
    @MainActor
    static func adoptIfReady() {
        guard let claimed = claim() else { return }
        DocumentModel.shared.adoptLaunchOpen(claimed.outcome, path: claimed.path)
    }

    /// Atomic consume: nil while the open is still running, and nil forever after
    /// the outcome has been taken.
    private static func claim() -> Claim? {
        state.withLock { state -> Claim? in
            guard !state.consumed, let path = state.path, let outcome = state.outcome else { return nil }
            state.consumed = true
            state.outcome = nil
            return Claim(path: path, outcome: outcome)
        }
    }

    /// Retires the box without adopting. A session that already landed is closed
    /// here; one that lands later is closed by the completion in `start`.
    private static func discard() {
        let landed: Result<any DocumentSession, DocumentOpenError>? = state.withLock { state in
            let outcome = state.outcome
            state.consumed = true
            state.outcome = nil
            return outcome
        }
        if case let .success(session) = landed { session.close() }
    }
}
