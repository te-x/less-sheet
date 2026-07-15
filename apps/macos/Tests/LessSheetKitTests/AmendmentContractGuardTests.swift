// Frozen behavior test — settings-panel-redesign AC23 contract guard
// (planner-owned). The inline-Settings amendment is a UI COMPOSITION + ROUTING
// change ONLY: relative to the shipped column-config baseline, both the frozen
// C ABI `api/lesssheet.h` and the public Swift contracts in
// `apps/macos/Sources/Contracts/ColumnPanel.swift` must have an EMPTY DIFF, so
// every existing ABI and Swift-contract conformance check keeps passing
// unchanged and no new dependency/persistence/header-index/helper/network is
// introduced.
//
// This is a REGRESSION-LOCK, not a red seed: it is GREEN at freeze (both files
// are the committed baseline) and must STAY green through the build — if the
// implementer edits either file to move the surface, this fails immediately,
// BEFORE the deterministic frozen-path gate would. It complements the existing
// `ColumnPanelTests` conformance pins (which exercise the reused
// `ColumnPanelLayouting` / `ColumnLabelSearching` symbols): those catch a symbol
// change, this catches ANY byte change, including comments and layout.
//
// Both files are located from THIS file's compile-time path (#filePath), the
// same root-relative technique CorpusColdOpenTests uses, so the check is
// independent of the test runner's working directory. If a FUTURE, architect-
// approved feature legitimately extends `api/lesssheet.h`, its planner updates
// the pinned baseline below through the change-authority process — this
// amendment must not.
import Foundation
import Testing
import CryptoKit

@Suite("settings-panel-redesign AC23 contract guard")
struct AmendmentContractGuardTests {

    /// Workspace root, up from this source file
    /// (<root>/apps/macos/Tests/LessSheetKitTests/AmendmentContractGuardTests.swift).
    private static var workspaceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../LessSheetKitTests
            .deletingLastPathComponent() // .../Tests
            .deletingLastPathComponent() // .../macos
            .deletingLastPathComponent() // .../apps
            .deletingLastPathComponent() // <root>
    }

    private func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expectEmptyDiff(_ relativePath: String, baseline: String) {
        let file = Self.workspaceRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: file.path) else {
            Issue.record("AC23: protected contract file is missing at \(file.path)")
            return
        }
        let hex = (try? sha256Hex(of: file)) ?? "<unreadable>"
        #expect(hex == baseline, """
            AC23 VIOLATION: \(relativePath) changed relative to the shipped column-config baseline.
            The inline-Settings amendment must leave this file with an EMPTY DIFF (composition/routing
            only). Expected SHA-256 \(baseline), got \(hex). Revert the change (or, for a separate
            architect-approved feature, update this pin through the change-authority process).
            """)
    }

    // AC23 — the frozen C ABI is byte-identical: no additive block, no edit to any
    // existing symbol/layout/prototype for this UI amendment.
    @Test func frozenCAbiHeaderHasEmptyDiff() {
        // Baseline re-bumped for the ARCH-never-full-download-streaming amendment:
        // THREE documentation / sentinel changes (the LS_BYTES_TOTAL_UNKNOWN
        // sentinel + the network demand-driven / search-demand-bounded doc
        // carve-outs) with BYTE-IDENTICAL struct/enum/signature LAYOUT (verified
        // by the root planner: the only non-comment change is the one #define).
        // Prior bump: the ARCH-network-source additive block (ls_open_url_* +
        // ls_net_*). Updated by the planner through the change-authority process,
        // exactly as this guard's contract provides for an architect-approved
        // header amendment.
        expectEmptyDiff("api/lesssheet.h",
                        baseline: "28b76aa7006983582e2b5acc1210eb1631ec9c20277e52321b6634a170e0667b")
    }

    // AC23 — the public Swift search/layout contracts are byte-identical:
    // `ColumnPanelViewport`, `ColumnPanelPlan`, `ColumnPanelLayouting`,
    // `ColumnLabelCandidate`, `columnLabelSearchBatchMax`, and
    // `ColumnLabelSearching` keep their exact source and meaning; the "panel"
    // legacy name stays internal.
    @Test func columnPanelSwiftContractHasEmptyDiff() {
        expectEmptyDiff("apps/macos/Sources/Contracts/ColumnPanel.swift",
                        baseline: "d4ed5d70f840bb1b0928c391e606dba171bef3004d96c411677d517f000c9276")
    }
}
