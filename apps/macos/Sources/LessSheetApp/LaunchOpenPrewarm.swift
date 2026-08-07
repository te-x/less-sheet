import Contracts
import Foundation
import LessSheetKit
import Synchronization

/// The LAUNCH document's core open — started the instant its path is known, run
/// off the main thread, and handed to the model without ever blocking it.
///
/// Why this exists: `AppDelegate.route` used to enqueue
/// `Task { await DocumentModel.shared.open(...) }`. Whether that task got to
/// start before the main actor was consumed by AppKit / SwiftUI bring-up was
/// RUN-DEPENDENT (measured starting both at 67 ms and at 134 ms across runs of
/// the same launch), so the core open — file I/O plus the O(head) parse — often
/// landed on the TAIL of launch instead of overlapping it, and the window then
/// had to render the launch state before re-rendering the grid. Starting it here
/// makes the overlap deterministic and removes that extra render pass.
///
/// It is LAUNCH-ONLY and one-shot. Every later open — a drag onto the running
/// app, ⌘O, ⌘⇧O, a dialect re-open — keeps going through the normal
/// `DocumentModel.open` / `openURL` funnel, completely unchanged.
///
/// Concurrency: all mutable state lives in one `Synchronization.Mutex`, which is
/// a genuinely `Sendable` construct (no `@unchecked Sendable`, no
/// `nonisolated(unsafe)`); the deployment target is macOS 26 so it is always
/// available. `adoptIfReady()` is main-actor-only and NEVER waits on the open.
enum LaunchOpenPrewarm {
    /// Everything the box owns. `path` doubles as the "started" flag: it is set
    /// under the lock by the one call that wins the race to start.
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

    /// Starts the launch open for `path` on a background thread. IDEMPOTENT —
    /// the first call wins and later ones are silently ignored.
    ///
    /// Returns true when `path` is the document this box owns (it just started
    /// it, or an identical earlier call did). False means a DIFFERENT path was
    /// prewarmed first: the stale prewarm is discarded so it can never be
    /// adopted, and the caller must open `path` through the normal funnel.
    @discardableResult
    static func start(path: String, forcing override: DialectOverride) -> Bool {
        // A verification run keeps EXACTLY today's launch: no prewarm at all, so
        // the caller falls through to `DocumentModel.open`'s async funnel — see
        // `LaunchTuning`, which also explains what does and does NOT cover the
        // shipping ordering. Do not read the frozen corpus cold-open tests as
        // that cover: they assert a marker line under 500 ms, with retries, and
        // would pass a blank grid.
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
        // `CoreSessionOpener.open` dispatches the blocking `ls_open` onto its own
        // `less-sheet.core-open` queue, so the file I/O never runs on a
        // cooperative-pool thread and NOTHING here touches the main actor until
        // the open has already finished. `ls_open` reads exactly what it reads
        // today (O(head)); only WHEN it runs changes.
        Task.detached(priority: .userInitiated) {
            let outcome: Result<any DocumentSession, DocumentOpenError>
            do {
                outcome = .success(try await CoreSessionOpener().open(path: path, forcing: override))
            } catch let error as DocumentOpenError {
                outcome = .failure(error)
            } catch {
                // Unreachable: `CoreSessionOpener.open` is a typed throw.
                outcome = .failure(.ioFailure)
            }
            let stored = state.withLock { state -> Bool in
                guard !state.consumed else { return false }
                state.outcome = outcome
                return true
            }
            guard stored else {
                // Superseded while the open was in flight: own the handle we
                // just created and close it rather than leaking it.
                if case let .success(session) = outcome { session.close() }
                return
            }
            // The window content may already have been built (the claim above
            // would then have found nothing), so offer the result once more from
            // the main actor. Exactly one of the two attempts can win.
            await MainActor.run { adoptIfReady() }
        }
        return true
    }

    // MARK: - Launch routing

    /// True once the launch route has been taken, so only the FIRST routed path
    /// can ever use the prewarm.
    @MainActor private static var launchRouteTaken = false

    /// Routes the LAUNCH document through the prewarm: starts it (idempotent —
    /// an argv launch already started it at `main_entry`) and adopts it if it
    /// has already landed. Returns false when the caller must use the normal
    /// `DocumentModel.open` funnel instead — either because the launch route is
    /// already spent (a drag onto the running app, a second launch URL) or
    /// because a different path owns the prewarm.
    @MainActor
    static func handleLaunchRoute(_ path: String, forcing override: DialectOverride) -> Bool {
        guard !launchRouteTaken else { return false }
        launchRouteTaken = true
        guard start(path: path, forcing: override) else { return false }
        adoptIfReady()
        return true
    }

    // MARK: - Adopting

    /// Hands the prewarmed outcome to the model — NON-BLOCKING, and exactly once.
    ///
    /// If the open is still running this returns immediately having done
    /// nothing; the prewarm's own completion calls this again from the main
    /// actor. It never waits on the open, so a slow disk or a pathological head
    /// read can never delay the window: the worst case is today's behavior, in
    /// which the window comes up on the launch state and the document lands a
    /// moment later.
    @MainActor
    static func adoptIfReady() {
        guard let claimed = claim() else { return }
        DocumentModel.shared.adoptLaunchOpen(claimed.outcome, path: claimed.path)
    }

    /// Atomic consume: `nil` while the open is still running, and `nil` forever
    /// after the outcome has been taken.
    private static func claim() -> Claim? {
        state.withLock { state -> Claim? in
            guard !state.consumed, let path = state.path, let outcome = state.outcome else { return nil }
            state.consumed = true
            state.outcome = nil
            return Claim(path: path, outcome: outcome)
        }
    }

    /// Retires the box without adopting: a session that already landed is closed
    /// here, and one that lands later is closed by the completion in `start`.
    /// Used when a different launch path supersedes the prewarmed one.
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
