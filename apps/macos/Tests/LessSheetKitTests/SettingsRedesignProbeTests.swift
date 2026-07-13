// Frozen behavior tests — settings-panel-redesign GUI end-to-end (planner-owned).
// ARCH-column-config amendment criteria 11 (embedded Settings stays O(viewport)
// at 100k), 20 (one coherent Settings surface — no "Configure Columns…" entry,
// no document-window sheet/second panel, Parsing full-width above a side-by-side
// list+inspector), 22 (header deep-links), 19 (session reset). These are the
// facts a PURE unit cannot reach — they need the real linked app + AppKit — so,
// like NativeGridTests, they PROCESS-LAUNCH the gate-built LessSheet binary
// headless and assert on its stderr probe lines. The deterministic decision
// logic beneath them (adaptive mode, `#N`, ten-cap/overflow, the
// selection/search/disclosure reducer) is pinned purely in ColumnDiscoveryTests;
// the empty-diff of the frozen C ABI + ColumnPanel.swift by
// AmendmentContractGuardTests.
//
// PROBE CONTRACT (implementer-owned, to be wired in the build — the same
// division of labor as NativeGridTests: this file pins the env hooks, line
// prefixes, and required values; the probes live in implementer-owned Sources
// and stay INERT in production). All are RED at freeze because the current app
// has the OLD separate-sheet panel and emits none of these lines; each probe
// self-terminates after its ONE terminal line under LESSSHEET_DUMP_EXIT.
//
//   LESSSHEET_SETTINGS_COMPOSE=1
//     After first paint, raise the embedded Settings surface, then emit ONE:
//       lesssheet.settings.compose configure_columns_command=<b> column_sheet=<b>
//         parsing_above=<b> list_present=<b> inspector_present=<b>
//     AC20: configure_columns_command=false (no such entry), column_sheet=false
//     (the document window has no attached column sheet / there is no second
//     panel), parsing_above=true (Parsing is the full-width section above
//     Columns), list_present=true AND inspector_present=true (discovery/results
//     and the inspector are both present, side by side, without a tab/nav).
//
//   LESSSHEET_SETTINGS_DISCOVERY=1  (launched on wide_100k_cols)
//     Raise embedded Settings with an EMPTY query, then emit ONE:
//       lesssheet.settings.discovery total_columns=<n> search_field=<b>
//         unfiltered_rows=<n> settings_request_ids=<n> open_ms=<n>
//     AC11/AC13: total_columns=100000, search_field=true, unfiltered_rows=0 (no
//     unfiltered list above ten columns), settings_request_ids<=1 (an empty query
//     contributes ONLY the selected inspector column to the inference union — not
//     all columns, not a viewport of list rows), open_ms<500 (hard bound).
//
//   LESSSHEET_SETTINGS_HEADER_LINK=<1-based column>  (launched on a >10-col file)
//     Invoke the column-header configuration action for that column, then emit:
//       lesssheet.settings.header_link requested_col_1based=<n>
//         selected_col_0based=<n> raised=<b>
//     AC22: raised=true and selected_col_0based == requested-1 — a header action
//     raises the one Settings window and deep-links the target (resolving it via
//     direct `#N` when an empty/excluding query would otherwise hide it).
//
//   LESSSHEET_SETTINGS_RESET=<second document path>
//     Raise Settings, move the selection off column 0 and type a query, then open
//     the given NEW document, then emit:
//       lesssheet.settings.reset selected_col_0based=<n> query_empty=<b>
//     AC19: after an explicit new document, selected_col_0based=0 and
//     query_empty=true (a fresh logical session resets Settings selection/search).
//
// ROUTED TO A HUMAN / REVIEWER VISUAL PASS (cannot be gated headlessly — an
// off-screen run has no WindowServer geometry / never materializes paged
// NSTableView row views; see NativeGridTests' REVIEWER-MEASURED note): the actual
// side-by-side visual layout and the declared MINIMUM-usable window size showing
// Visible/Type/format without expanding a disclosure (AC20); keyboard-only +
// VoiceOver navigation and Increase-Contrast / Reduce-Motion behavior (AC16/AC20);
// the 100 ms interactive TARGET for open/raise/select/scroll and the release-mode
// timing on the real corpus (AC11/AC5 non-functional) — this gate pins only the
// 500 ms HARD bound in debug. State these to the orchestrator; do not weaken them.
import Foundation
import Testing

@Suite("settings-panel-redesign GUI probes", .serialized)
struct SettingsRedesignProbeTests {

    // MARK: Headless launcher (one app instance at a time)

    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// The gate-built app binary sits beside this test target's resource bundle
    /// (`swift build`/`swift test` (re)build it) — never a stale installed .app.
    private static var appBinary: URL {
        Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("LessSheet")
    }

    /// Workspace root, up from this file (mirrors CorpusColdOpenTests).
    private static var workspaceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Launch the app headless on `fixture` with exactly the LESSSHEET_* hooks in
    /// `env` (outer-shell LESSSHEET_* stripped first), capture stderr until
    /// self-termination or `timeout`, return the log. A moderate timeout keeps a
    /// still-unwired probe (its terminal line absent) from stalling the RED build
    /// loop while leaving a wired op ample room.
    private func launch(fixture: String, env extra: [String: String], timeout: TimeInterval = 45) throws -> String {
        let binary = Self.appBinary
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ProbeError("LessSheet binary not found at \(binary.path) — build it (swift build / the component gate) first")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = [fixture]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("LESSSHEET_") { environment.removeValue(forKey: key) }
        for (k, v) in extra { environment[k] = v }
        process.environment = environment

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let sink = LogSink()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil } else { sink.append(chunk) }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate(); Thread.sleep(forTimeInterval: 1.0)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { sink.append(rest) }
        return sink.text
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Probe-log parsing

    private func line(_ log: String, prefix: String) -> String? {
        log.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).last { $0.hasPrefix(prefix) }
    }
    private func fields(_ line: String) -> [String: String] {
        var f: [String: String] = [:]
        for token in line.split(separator: " ") where token.contains("=") {
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { f[String(parts[0])] = String(parts[1]) }
        }
        return f
    }
    private func intField(_ line: String, _ key: String) -> Int? { fields(line)[key].flatMap(Int.init) }
    private func boolField(_ line: String, _ key: String) -> Bool? {
        switch fields(line)[key] { case "true": true; case "false": false; default: nil }
    }
    private func tail(_ log: String, _ n: Int = 30) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: true).suffix(n).joined(separator: "\n")
    }

    /// A bundled small fixture path.
    private func bundled(_ name: String) throws -> String {
        try #require(Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "Fixtures"),
                     "missing fixture \(name).csv").path(percentEncoded: false)
    }

    /// A one-shot >10-column numeric fixture (headerless; 20 cols, 2 rows) written
    /// to the temp dir — exercises the `#N`/adaptive path for the header deep-link.
    private func wideFixture(columns: Int = 20) throws -> String {
        let row = (0..<columns).map { String($0) }.joined(separator: ",")
        let text = row + "\n" + row + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lesssheet-settings-wide-\(columns)col.csv")
        try text.data(using: .utf8)!.write(to: url)
        return url.path(percentEncoded: false)
    }

    /// Relaunch only when a run never produced its terminal line (infra, not
    /// behavior); a present-but-wrong value fails immediately.
    private func run(fixture: String, env: [String: String], terminal prefix: String, attempts: Int = 2) throws -> String {
        var log = ""
        for _ in 1...attempts {
            log = try launch(fixture: fixture, env: env)
            if line(log, prefix: prefix) != nil { break }
        }
        return log
    }

    // MARK: AC20 — one coherent Settings surface

    @Test func settingsIsTheSoleColumnConfigurationSurface() throws {
        let env = ["LESSSHEET_SETTINGS_COMPOSE": "1", "LESSSHEET_DUMP_EXIT": "1"]
        let log = try run(fixture: try bundled("people"), env: env,
                          terminal: "lesssheet.settings.compose ")
        guard let l = line(log, prefix: "lesssheet.settings.compose ") else {
            #expect(Bool(false), Comment(rawValue: "no lesssheet.settings.compose line (embedded Settings surface not wired):\n\(tail(log))"))
            return
        }
        #expect(boolField(l, "configure_columns_command") == false,
                "AC20: the \"Configure Columns…\" entry must be removed:\n\(tail(log))")
        #expect(boolField(l, "column_sheet") == false,
                "AC20: there must be no document-window column sheet / second panel:\n\(tail(log))")
        #expect(boolField(l, "parsing_above") == true,
                "AC20: Parsing must be the full-width section above Columns:\n\(tail(log))")
        #expect(boolField(l, "list_present") == true && boolField(l, "inspector_present") == true,
                "AC20: discovery/results and the inspector must both be present (side by side):\n\(tail(log))")
    }

    // MARK: AC11 — embedded Settings stays O(viewport) at 100k

    @Test func embeddedSettingsIsBoundedOnWide100kColumns() throws {
        let fixture = Self.workspaceRoot
            .appendingPathComponent("apps/macos/.build/corpus-cache/wide_100k_cols.csv")
        try #require(FileManager.default.fileExists(atPath: fixture.path), """
            wide_100k_cols.csv not found at \(fixture.path). The corpus generate step is not wired
            for this run; generate it with tools/csvgen/gen.py (--case wide_100k_cols --seed 1337)
            or point the macOS conformance step at it, then re-run.
            """)
        let env = ["LESSSHEET_SETTINGS_DISCOVERY": "1", "LESSSHEET_DUMP_EXIT": "1"]
        let log = try run(fixture: fixture.path, env: env, terminal: "lesssheet.settings.discovery ")
        guard let l = line(log, prefix: "lesssheet.settings.discovery ") else {
            #expect(Bool(false), Comment(rawValue: "no lesssheet.settings.discovery line (embedded Settings on 100k not wired):\n\(tail(log))"))
            return
        }
        #expect(intField(l, "total_columns") == 100_000, "expected the 100k fixture:\n\(tail(log))")
        #expect(boolField(l, "search_field") == true,
                "AC13: above ten columns Settings shows a search field:\n\(tail(log))")
        #expect(intField(l, "unfiltered_rows") == 0,
                "AC11/AC13: an empty query above ten columns creates NO unfiltered list rows:\n\(tail(log))")
        #expect((intField(l, "settings_request_ids") ?? .max) <= 1,
                "AC11: an empty query requests inference for only the selected inspector column, not all columns:\n\(tail(log))")
        let openMs = intField(l, "open_ms") ?? .max
        #expect(openMs < 500,
                "AC11: Settings open on wide_100k_cols must stay under the 500 ms hard bound (got \(openMs) ms). The 100 ms interactive target + release timing are reviewer-measured:\n\(tail(log))")
    }

    // MARK: AC22 — header deep-link raises Settings and selects the target

    @Test func columnHeaderActionDeepLinksTheTarget() throws {
        let env = ["LESSSHEET_SETTINGS_HEADER_LINK": "15", "LESSSHEET_DUMP_EXIT": "1"]
        let log = try run(fixture: try wideFixture(columns: 20), env: env,
                          terminal: "lesssheet.settings.header_link ")
        guard let l = line(log, prefix: "lesssheet.settings.header_link ") else {
            #expect(Bool(false), Comment(rawValue: "no lesssheet.settings.header_link line (header deep-link not wired):\n\(tail(log))"))
            return
        }
        #expect(intField(l, "requested_col_1based") == 15)
        #expect(boolField(l, "raised") == true,
                "AC22: a header action must raise the one Settings window:\n\(tail(log))")
        #expect(intField(l, "selected_col_0based") == 14,
                "AC22: the header action must select the 1-based target (resolving it via direct #N above ten columns):\n\(tail(log))")
    }

    // MARK: AC19 — an explicit new document resets Settings selection/search

    @Test func newDocumentResetsSettingsSelectionAndSearch() throws {
        let env = [
            "LESSSHEET_SETTINGS_RESET": try bundled("semicolon"), // the SECOND document to open
            "LESSSHEET_DUMP_EXIT": "1",
        ]
        let log = try run(fixture: try bundled("people"), env: env, terminal: "lesssheet.settings.reset ")
        guard let l = line(log, prefix: "lesssheet.settings.reset ") else {
            #expect(Bool(false), Comment(rawValue: "no lesssheet.settings.reset line (cross-document reset not wired):\n\(tail(log))"))
            return
        }
        #expect(intField(l, "selected_col_0based") == 0,
                "AC19: opening a new document resets the Settings selection to column 0:\n\(tail(log))")
        #expect(boolField(l, "query_empty") == true,
                "AC19: opening a new document clears the Settings search:\n\(tail(log))")
    }
}
