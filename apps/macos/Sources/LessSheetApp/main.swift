// The executable entry point: mark process start as early as possible, then run
// AppKit's own application lifecycle. A `main.swift` file precludes `@main`, and
// there is no SwiftUI `App` to hand off to — the single window and the Settings
// window are both delegate-owned NSWindows, so an `App` would have contributed
// nothing but its bring-up cost.
import AppKit
import Foundation

LaunchTiming.begin()
LaunchTiming.phase("main_entry")

// Start the launch document's core open HERE when the path arrived on argv, so
// it overlaps AppKit bring-up instead of queuing behind it. A bundle launch
// carries no path in argv — it gets one from an Apple Event about 90 ms in, and
// the delegate starts the same prewarm there. Idempotent either way.
if let launchDocument = LaunchArguments.documentPath(from: CommandLine.arguments) {
    LaunchOpenPrewarm.start(path: launchDocument, forcing: launchForcedOverride())
}

// Halve the tooltip show delay: the built-in default is around two seconds. Set
// on THIS app's own preferences domain rather than the global one, so it wins
// for our tooltips without ever touching the user's system-wide default on disk.
// Off the launch path because this is the process's first touch of the
// preferences system and costs about 5 ms there, while nothing reads the value
// until a pointer has rested on a control.
DispatchQueue.global(qos: .userInitiated).async {
    UserDefaults.standard.set(1_000, forKey: "NSInitialToolTipDelay")
}

LaunchTiming.phase("before_app_run")
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
