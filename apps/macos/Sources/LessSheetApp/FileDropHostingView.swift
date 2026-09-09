import AppKit
import SwiftUI

/// The main window's root accepts files over every document/launch/error state.
/// Opening uses the same model path as the file panel, including cancellation
/// of an earlier network open and reset of per-document state.
@MainActor
final class FileDropHostingView: NSHostingView<ContentView> {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              fileURL(from: sender.draggingPasteboard) != nil else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy),
              let url = fileURL(from: sender.draggingPasteboard),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        else { return false }
        Task {
            await DocumentModel.shared.open(
                path: url.path(percentEncoded: false), forcing: launchForcedOverride())
        }
        return true
    }

    private func fileURL(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first, url.isFileURL else { return nil }
        return url
    }
}
