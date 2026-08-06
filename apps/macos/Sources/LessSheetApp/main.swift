// less-sheet macOS app entry point.
//
// This file is `main.swift`, so its top-level code is the executable entry:
// mark process-start as early as possible, then hand off to the SwiftUI app.
// (Using a `main.swift` file precludes `@main`; calling `App.main()` explicitly
// is the supported equivalent.) The full UI — window, sticky-header Table,
// in-window error panel, File › Open…, launch-with-file / CLI open, and the
// checkable "First Row Is Header" menu item — lives in AppUI.swift; the
// cold-start timing marker is emitted from LaunchTiming.swift.
import Foundation

LaunchTiming.begin()
LaunchTiming.phase("main_entry")

// Start the LAUNCH document's core open HERE, at process entry, when the path
// arrived on argv (direct exec / `open --args`): it then overlaps AppKit and
// SwiftUI bring-up on a background thread instead of queuing behind them on the
// main actor. A BUNDLE launch (Finder double-click, `open -a`, drag-onto-icon)
// carries no path in argv — it gets one from an Apple Event ~90 ms in, and
// `AppDelegate.route` starts the same prewarm there. Idempotent either way.
if let launchDocument = LaunchArguments.documentPath(from: CommandLine.arguments) {
    LaunchOpenPrewarm.start(path: launchDocument, forcing: launchForcedOverride())
}

// Halve the tooltip show delay before AppKit spins up (NSToolTipManager reads
// `NSInitialToolTipDelay`, in ms, near launch — SwiftUI's `.help()` bridges to
// it). Baseline: `defaults read -g NSInitialToolTipDelay` is unset on a stock
// system, so AppKit falls back to its built-in default — widely corroborated
// at ~2000 ms (e.g. the macOS 12.4 restored-preference discussion), so half is
// 1000 ms. Set on THIS APP's own preferences domain (not `-g`/NSGlobalDomain):
// it forces the effective delay for LessSheet's tooltips, wins over any
// global value now or set later, and never touches the user's actual
// system-wide default on disk.
UserDefaults.standard.set(1_000, forKey: "NSInitialToolTipDelay")

LaunchTiming.phase("before_swiftui_main")
LessSheetApp.main()
