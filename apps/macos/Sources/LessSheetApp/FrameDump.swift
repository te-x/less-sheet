import AppKit
import Foundation
import SwiftUI

/// Opt-in, self-rendering frame dump for HEADLESS visual verification without any
/// screen-capture / TCC-prompting API. When `LESSSHEET_DUMP_FRAME=<path>` is set,
/// the given view is rendered OFF-SCREEN with SwiftUI's `ImageRenderer` to a PNG
/// at `<path>`, then `lesssheet.frame_dumped=<path>` is logged to stderr.
///
/// Inert (zero cost, no output) when the env var is absent, and always invoked
/// AFTER the cold-start timing marker fires, so it never pollutes the < 500 ms
/// measurement. Uses an ENV var (never argv), so it cannot be mistaken for a
/// document path by `LaunchArguments`.
enum FrameDump {
    private static let dumpPathEnvKey = "LESSSHEET_DUMP_FRAME"

    @MainActor
    static func dumpIfRequested(_ content: some View) {
        guard let path = ProcessInfo.processInfo.environment[dumpPathEnvKey], !path.isEmpty else { return }

        let renderer = ImageRenderer(content:
            content
                .frame(width: 900, height: 600)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2

        guard
            let cgImage = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else {
            log("lesssheet.frame_dump_failed=\(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log("lesssheet.frame_dumped=\(path)")
        } catch {
            log("lesssheet.frame_dump_failed=\(path)")
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
