import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

// The non-grid content states — empty, launch and error — and the reactive
// window chrome.

/// A single quiet line, centered.
struct EmptyStateView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown when the app starts with no document. It spells out both ways to open
/// one rather than popping the file panel, which would assume "open" means a
/// local file.
struct LaunchStateView: View {
    /// Matches what the GNOME status pages draw the app icon at, so both
    /// frontends read alike.
    private static let logoSize: CGFloat = 128

    /// The bundle's own icon — the one image AppKit already loads for the Dock
    /// and About, so no resource of ours is shipped or looked up. Outside an
    /// assembled bundle AppKit hands back its generic application icon.
    private static var logo: NSImage {
        NSApplication.shared.applicationIconImage ?? NSImage()
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Self.logo)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.logoSize, height: Self.logoSize)
                .accessibilityHidden(true) // the title below carries the meaning
                .padding(.bottom, 8)
            Text("Open a spreadsheet to view it")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌘O", "Open a local file")
                shortcut("⌘⇧O", "Open a URL")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .frame(minWidth: 44, alignment: .trailing)
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// The in-window error panel: the fact, then the fix.
struct ErrorPanel: View {
    let error: DocumentOpenError
    let path: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(fact).font(.headline)
            Text(fix).font(.callout).foregroundStyle(.secondary)
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var fact: String {
        switch error {
        case .notFound: "File not found"
        case .permissionDenied: "Permission denied"
        case .ioFailure, .invalidArgument: "Can't read this file"
        }
    }

    private var fix: String {
        switch error {
        case .notFound: "Check the path, then open it again."
        case .permissionDenied: "Grant read access to this file, then open it again."
        case .ioFailure, .invalidArgument: "It may be a folder or otherwise unreadable. Try another file."
        }
    }
}

/// The network analog of `ErrorPanel`. Each case gets its own fact and fix, so a
/// 404, a DNS failure, a timeout, a redirect loop, a disallowed scheme and a
/// spool-IO error never read as the same generic message.
struct NetworkErrorPanel: View {
    let error: NetworkOpenError
    let path: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(fact).font(.headline)
            Text(fix).font(.callout).foregroundStyle(.secondary)
            Text(path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var fact: String {
        switch error {
        case .invalidArgument: "Not an http:// or https:// address"
        case .unreachable: "Couldn't reach that host"
        case .timeout: "The connection timed out"
        case let .httpStatus(code): "Server returned \(code)"
        case .tooManyRedirects: "Too many redirects"
        case .ioFailure: "Couldn't create the local download"
        case .cancelled: "Open cancelled"
        }
    }

    private var fix: String {
        switch error {
        case .invalidArgument: "Only http:// and https:// URLs are supported. Check the address and try again."
        case .unreachable: "Check the address and your network connection, then try again."
        case .timeout: "The server didn't respond in time. Try again."
        case let .httpStatus(code) where code == 401 || code == 403:
            "This URL requires authentication, which isn't supported. Try a public URL."
        case .httpStatus: "The server rejected the request. Check the address and try again."
        case .tooManyRedirects: "The URL redirected too many times. Check the address."
        case .ioFailure: "Couldn't create the local spool file. Check available disk space and try again."
        case .cancelled: "The open was cancelled before it finished."
        }
    }
}

// MARK: - Window chrome (reactive)

/// Keeps the window's document title current. The static chrome — transparent
/// title bar, hidden title — is set once by the delegate at window creation.
struct WindowConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        // The title is kept current for Mission Control, the Window menu and the
        // Dock, but `titleVisibility` must NEVER be toggled: making the title
        // visible flips AppKit into titled layout, which insets the content view
        // below the title bar — killing the under-titlebar scroll and its frost —
        // and misaligns the pinned header against row 1. The filename the user
        // sees is our own label instead.
        window.title = title
        window.titleVisibility = .hidden
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
    }
}
