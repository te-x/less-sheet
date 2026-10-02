import AppKit
import Foundation

/// Created only when the menu command is used: launch does no update work or networking.
@MainActor
final class UpdateChecker {
    private var task: Task<Void, Never>?
    private var checkID: UUID?
    private var checkingAlert: NSAlert?
    private var finishedCheck: (@MainActor @Sendable () -> Void)?
    private weak var parentWindow: NSWindow?

    func check(for window: NSWindow?) {
        guard checkID == nil else {
            checkingAlert?.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let current = ReleaseVersion(text) else {
            showMessage("Couldn’t Check for Updates", UpdateCheckError.invalidVersion.localizedDescription,
                        for: window)
            return
        }
        guard let window, window.attachedSheet == nil else {
            showMessage("Couldn’t Check for Updates", "Close the current dialog and try again.", for: nil)
            return
        }
        let identifier = UUID()
        checkID = identifier
        parentWindow = window
        showChecking(for: window, identifier: identifier)
        task = Task { [weak self] in
            guard let self else { return }
            await self.runCheck(current: current, identifier: identifier)
        }
    }

    private func showChecking(for window: NSWindow, identifier: UUID) {
        let alert = NSAlert()
        alert.messageText = "Checking for Updates…"
        alert.informativeText = "Looking for the latest version of less-sheet."
        alert.addButton(withTitle: "Cancel")
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        progress.style = .spinning
        progress.startAnimation(nil)
        alert.accessoryView = progress
        checkingAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.checkingDidEnd(response, identifier: identifier)
        }
    }

    private func runCheck(current: ReleaseVersion, identifier: UUID) async {
        do {
            let release = try await UpdateRelease.latest()
            guard checkID == identifier, !Task.isCancelled else { return }
            finishChecking(identifier: identifier) {
                if release.version > current {
                    self.offerDownload(release, current: current)
                } else {
                    self.showMessage("You’re Up to Date", "less-sheet \(current.text) is up to date.",
                                     for: self.parentWindow)
                }
            }
        } catch {
            guard checkID == identifier, !Task.isCancelled else { return }
            let message = error.localizedDescription
            finishChecking(identifier: identifier) {
                self.showMessage("Couldn’t Check for Updates", message, for: self.parentWindow)
            }
        }
    }

    private func finishChecking(identifier: UUID, completion: @escaping @MainActor @Sendable () -> Void) {
        guard checkID == identifier else { return }
        finishedCheck = completion
        if let parent = checkingAlert?.window.sheetParent, let alert = checkingAlert {
            parent.endSheet(alert.window, returnCode: .stop)
        } else {
            checkingDidEnd(.stop, identifier: identifier)
        }
    }

    private func checkingDidEnd(_ response: NSApplication.ModalResponse, identifier: UUID) {
        guard checkID == identifier else { return }
        let oldTask = task
        let completion = finishedCheck
        checkingAlert?.window.orderOut(nil)
        checkingAlert = nil
        finishedCheck = nil
        task = nil
        checkID = nil
        if response == .alertFirstButtonReturn {
            oldTask?.cancel()
        } else {
            completion?()
        }
    }

    private func offerDownload(_ release: UpdateRelease, current: ReleaseVersion) {
        let alert = NSAlert()
        alert.messageText = "less-sheet \(release.version.text) Is Available"
        alert.informativeText = "You have version \(current.text). Download the latest version for macOS?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        present(alert, for: parentWindow) { response in
            guard response == .alertFirstButtonReturn else { return }
            if !NSWorkspace.shared.open(release.downloadURL) {
                self.showMessage("Couldn’t Open Download", "Your browser could not open the download link.",
                                 for: self.parentWindow)
            }
        }
    }

    private func showMessage(_ title: String, _ message: String, for window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert, for: window) { _ in }
    }

    private func present(_ alert: NSAlert, for window: NSWindow?,
                         completion: @escaping @MainActor @Sendable (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
