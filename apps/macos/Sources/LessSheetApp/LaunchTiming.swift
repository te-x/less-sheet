import Foundation
import Contracts

/// Emits the cold-start timing marker (ARCH-walking-skeleton functional req. 7):
/// one `lesssheet.first_rows_visible_ms=<int>` line to stderr per document open
/// that reaches a data-bearing table. Error and empty states emit nothing.
///
/// `begin()` is called as the very first statement of `main.swift` — the closest
/// approximation to process start available to app code.
enum LaunchTiming {
    private nonisolated(unsafe) static var startNanos: UInt64 = DispatchTime.now().uptimeNanoseconds

    static func begin() {
        startNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Emits the marker for the first frame that shows document data.
    static func markFirstRowsVisible() {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
        let milliseconds = Int(elapsed / 1_000_000)
        FileHandle.standardError.write(Data((TimingMarker.line(milliseconds: milliseconds) + "\n").utf8))
    }

    // MARK: - Launch phase breakdown (LESSSHEET_LAUNCH_PHASES)

    /// Phase stamps between process start and the first data-bearing frame —
    /// INERT unless `LESSSHEET_LAUNCH_PHASES` is set, so the shipped launch path
    /// is unchanged and the cold-start marker above stays comparable.
    ///
    /// Why this exists: the marker above is a single number, and a single number
    /// cannot be optimized — it can only be argued about. Measuring from outside
    /// the process showed the invisible pre-`main` prefix (dyld: dylib loading,
    /// rebasing, ObjC setup, Swift runtime) is only ~17 ms of a ~188 ms wait, so
    /// ~91% of it happens in code we own and none of it was attributed.
    ///
    /// Each stamp prints `lesssheet.phase.<name>=<ms since process start>`, so
    /// the deltas between consecutive stamps are the phase costs.
    private static let phasesOn =
        ProcessInfo.processInfo.environment["LESSSHEET_LAUNCH_PHASES"] != nil

    static func phase(_ name: String) {
        guard phasesOn else { return }
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000)
        FileHandle.standardError.write(Data("lesssheet.phase.\(name)=\(elapsedMs)\n".utf8))
    }

    /// Names already stamped by `phaseOnce`. Main-actor isolated because its one
    /// caller is AppKit's main-thread draw path — a real isolation guarantee, so
    /// no lock and no `nonisolated(unsafe)` escape hatch is needed.
    @MainActor private static var stampedOnce: Set<String> = []

    /// One-shot `phase(_:)` for a stamp that sits in a PER-FRAME path: the first
    /// call for a given name emits, every later call is a `Set` lookup. Inert
    /// without `LESSSHEET_LAUNCH_PHASES`, exactly like `phase(_:)` — in the
    /// shipped launch path this costs one `Bool` read per row draw.
    ///
    /// This exists for `first_row_pixels`, stamped from `SheetRowView.draw` on
    /// the first real data row: the GROUND TRUTH for "the rows are on screen",
    /// and the number the launch work is measured against. Note that
    /// `markFirstRowsVisible()` / `lesssheet.first_rows_visible_ms` is an
    /// APPROXIMATION of the same moment that fires EARLIER (~15 ms on a 50 MB
    /// file) — it marks the point where SwiftUI schedules the document `.task`,
    /// before AppKit has laid out and drawn a single row. That marker is
    /// contract-adjacent (pinned by the frozen corpus cold-open tests) and is
    /// deliberately left exactly as it is.
    @MainActor
    static func phaseOnce(_ name: String) {
        guard phasesOn, stampedOnce.insert(name).inserted else { return }
        phase(name)
    }
}
