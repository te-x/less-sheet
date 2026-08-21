import AppKit
import Foundation

// MARK: - Screenshot-capture affordance (LESSSHEET_CAPTURE_*)

// Capture affordance for `tools/shots/capture_shots` — INERT unless one of the
// env vars below is set, so it costs nothing in normal use and never touches
// the < 500 ms cold-start measurement.
//
// Why it exists: the frontpage's screenshots were first produced from
// `FrameDump`'s off-screen content renders, and the author rejected them — no
// window frame, no traffic lights, none of the glass/scroll-edge material the
// real window has, because `ImageRenderer` rasterizes a view tree, not a
// composited window. The honest fix is photographing the REAL window
// (`screencapture -l <windowNumber>`), which needs three things a live app
// doesn't otherwise offer a tool:
//
//   LESSSHEET_CAPTURE_SIZE=<w>x<h>   Deterministic content size. The main
//     window autosaves its frame ("LessSheetMain"), so without this two runs
//     capture two different geometries; the shot set requires all variants of
//     a shot to be pixel-identical. Applied after the autosaved frame is
//     restored, then centered. The saved frame on disk is not modified.
//   LESSSHEET_CAPTURE_APPEARANCE=dark|light   Pin the WHOLE app's appearance
//     for this process (NSApp.appearance) so both theme variants can be
//     captured on one machine regardless of the system setting. Unlike
//     LESSSHEET_DUMP_APPEARANCE (which pins only FrameDump's off-screen
//     container), this must cover the window chrome, panels and popovers too.
//     Per-process only — never writes a default, never touches the system.
//   LESSSHEET_CAPTURE_REVEAL=header|separator|quote   Expand that guess pill
//     after first paint, exactly as clicking it would (the same
//     `expandedPill` state GuessPills reads), so the dialect shot can show
//     the open control — hover state is not scriptable from outside, the
//     model state it sets is.
//
// When any of these is set, the first data-bearing paint also logs
//   lesssheet.capture_window=<windowNumber>
// to stderr — `windowNumber` IS the CGWindowID `screencapture -l` takes, so
// the tool needs no window-list lookup (whose names are redacted without the
// Screen Recording permission anyway).
@MainActor
enum CaptureProbe {
    private static let env = ProcessInfo.processInfo.environment

    /// True when the hook is armed by any of its env vars.
    static var active: Bool {
        env["LESSSHEET_CAPTURE_SIZE"] != nil
            || env["LESSSHEET_CAPTURE_APPEARANCE"] != nil
            || env["LESSSHEET_CAPTURE_REVEAL"] != nil
    }

    /// Called by `AppDelegate.showMainWindow` after the autosaved frame is
    /// restored, so the deterministic size wins without persisting anything.
    static func configure(window: NSWindow) {
        guard active else { return }
        switch env["LESSSHEET_CAPTURE_APPEARANCE"]?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let raw = env["LESSSHEET_CAPTURE_SIZE"] {
            let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts[0] >= 520, parts[1] >= 360 {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                window.center()
            }
        }
    }

    /// Called when a jump reaches its landing (`JumpProbe.arrived`). Inert unless
    /// `LESSSHEET_CAPTURE_REVEAL=jump`.
    ///
    /// Why it exists: landing DISMISSES the jump field, so a jump shot driven by
    /// `LESSSHEET_JUMP` alone photographs a grid parked at row 1500 with no
    /// control visible — a picture indistinguishable from the hero, which is
    /// exactly what shipped in the first macOS set. The author caught it by looking.
    /// Re-requesting focus reopens the field on the landed rows, the same state a
    /// user sees when they press ⌘J again, and the same workaround the GTK side
    /// already uses (Ctrl+G after the landing).
    ///
    /// Prints `lesssheet.capture_jump_reopened=<row>` so the capture tool can
    /// gate on the field being BACK rather than on the landing, which would shoot
    /// too early.
    static func afterJumpLanded(model: DocumentModel, row: UInt64) {
        guard active,
              env["LESSSHEET_CAPTURE_REVEAL"]?.lowercased() == "jump" else { return }
        model.requestJumpFocus()
        FileHandle.standardError.write(
            Data("lesssheet.capture_jump_reopened=\(row)\n".utf8))
    }

    /// Called once after the first data-bearing paint (AppUI's probe hook,
    /// alongside — not instead of — the verification probes, so a state probe
    /// like LESSSHEET_FIND still runs and leaves its popup open).
    static func announce(model: DocumentModel) {
        guard active else { return }
        switch env["LESSSHEET_CAPTURE_REVEAL"]?.lowercased() {
        case "header": model.expandedPill = .header
        case "separator": model.expandedPill = .separator
        case "quote": model.expandedPill = .quote
        default: break
        }
        let number = NSApp.mainWindow?.windowNumber ?? NSApp.windows.first?.windowNumber ?? -1
        FileHandle.standardError.write(
            Data("lesssheet.capture_window=\(number)\n".utf8))
    }
}
