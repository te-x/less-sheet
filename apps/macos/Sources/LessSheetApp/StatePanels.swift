import AppKit
import Contracts
import Foundation
import LessSheetKit
import Observation
import SwiftUI

// The non-grid content states (empty / launch / error panels) and the reactive
// window chrome, split out of AppUI.swift to keep each file within the length
// budget. Pure code motion — no behavior change.

/// A single quiet line, centered — used for the empty-file state.
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

/// The blank launch screen shown when the app starts with no document (i.e. not
/// via a Finder open / argv). It spells out the two ways to open something —
/// a local file (⌘O) and a network URL (⌘⇧O) — instead of the old behavior of
/// immediately popping the file panel, which predated network support and
/// wrongly assumed "open" meant a local file. Same quiet, centered aesthetic as
/// the empty-file state.
struct LaunchStateView: View {
    var body: some View {
        VStack(spacing: 14) {
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

/// In-window error panel: the fact, then the fix path (ARCH: errors = fact +
/// fix). Semantic colors; the path is selectable.
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

/// The network-open analog of `ErrorPanel` (ARCH-network-source AC7 — round-2
/// review finding 2): renders each of the 7 distinct `NetworkOpenError` cases
/// with its own fact + fix, so a 404, a DNS/connect failure, a timeout, a
/// redirect-loop, a disallowed scheme, and a spool-IO error never read as the
/// same generic message.
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

/// Reveals/hides the traffic lights with the overlay and keeps the window's
/// document title current. Static chrome (transparent title bar, hidden title)
/// is set once by the delegate at window creation.
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
        // Keep the document title current for Mission Control / the Window menu
        // / the Dock (ARCH req 1) — but NEVER toggle `titleVisibility`. Making the
        // title visible flips AppKit into "titled" layout: it insets the content
        // view BELOW the title bar (so grid content no longer scrolls under it —
        // killing the scroll-edge frost) and misaligns the pinned header vs row 1
        // (the 6 pt overlap). be86b2a kept it statically `.hidden`; that is what
        // preserved the blur and the clean top edge, so we restore that. Only the
        // traffic lights fade in/out with the overlay reveal.
        window.title = title
        window.titleVisibility = .hidden
        // Traffic lights always visible (no fade); the filename is drawn by our
        // own always-on title label (keeping titleVisibility .hidden preserves
        // the under-titlebar scroll + frost + header alignment).
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.alphaValue = 1
        }
    }
}
