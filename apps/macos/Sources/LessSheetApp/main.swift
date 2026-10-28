// The executable entry point: mark process start as early as possible, then run
// AppKit's own application lifecycle. A `main.swift` file precludes `@main`, and
// there is no SwiftUI `App` to hand off to — the single window and the Settings
// window are both delegate-owned NSWindows, so an `App` would have contributed
// nothing but its bring-up cost.
import AppKit
import Foundation

if CommandLine.arguments.count == 2, ["--help", "-h", "--help-all"].contains(CommandLine.arguments[1]) {
    print("""
    less-sheet — a fast viewer for CSV and Parquet files

    Usage: less-sheet [FILE_PATH]
           less-sheet --version
           less-sheet --update
           less-sheet --help, -h
    """)
    exit(0)
}

if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--version" {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "unknown"
    print("less-sheet \(version)")
    exit(0)
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--update" {
    Task.detached {
        do {
            guard let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  let current = ReleaseVersion(text) else { throw UpdateCheckError.invalidVersion }
            let release = try await UpdateRelease.latest()
            if release.version > current {
                print("less-sheet \(release.version.text) is available (installed: \(current.text)).")
                print("Download: \(release.downloadURL.absoluteString)")
            } else {
                print("less-sheet \(current.text) is up to date.")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Could not check for updates: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

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
