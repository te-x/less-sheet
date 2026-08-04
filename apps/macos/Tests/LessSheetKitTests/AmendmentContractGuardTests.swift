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
        // Baseline re-bumped 2026-08-04 for a COMMENT-ONLY correction: the
        // LS_FILTER_CANCELLED doc block listed only "a jump-scan or match-scan took
        // the slot" as the cause, which does not describe what happens on a NETWORK
        // document -- the filtered jump that was driving the scan lands and nothing
        // else drives it, because a net document gets no background filter scan. A
        // frontend author reading only that list would not anticipate the state, and
        // could render it as a user cancellation instead of a partial count. Wording
        // endorsed by the reviewer in review/REVIEW-netgz-mutex-wedge.md. ZERO
        // struct / enum / signature / constant / layout change -- ls_filter_state's
        // values are untouched -- so the ABI is byte-compatible; only the comment
        // bytes moved, which this guard deliberately notices.
        // Baseline re-bumped for the ARCH-thin-frontend-shared-core Phase 1
        // amendment: ONE additive appended block (the MATCH-FLAGS EXTENSION —
        // the single new prototype ls_window_match_flags), with struct / enum /
        // signature / constant LAYOUT above it BYTE-IDENTICAL (verified by the
        // root planner: the only change is the appended block). Updated through
        // the change-authority process, exactly as this guard provides for an
        // architect-approved header amendment.
        // Baseline re-bumped for the ARCH-never-full-download-streaming amendment:
        // THREE documentation / sentinel changes (the LS_BYTES_TOTAL_UNKNOWN
        // sentinel + the network demand-driven / search-demand-bounded doc
        // carve-outs) with BYTE-IDENTICAL struct/enum/signature LAYOUT (verified
        // by the root planner: the only non-comment change is the one #define).
        // Prior bump: the ARCH-network-source additive block (ls_open_url_* +
        // ls_net_*). Updated by the planner through the change-authority process,
        // exactly as this guard's contract provides for an architect-approved
        // header amendment.
        // Baseline re-bumped for the ARCH-thin-frontend-shared-core Phase 2
        // amendment: ONE additive appended block (the STREAMING COPY EXTENSION —
        // LS_COPY_MAX_CELLS + ls_copy_rect / ls_copy_step / ls_copy_progress /
        // ls_copy_job + ls_copy_open / ls_copy_next / ls_copy_close), with struct /
        // enum / signature / constant / prototype LAYOUT above it (incl. the Phase 1
        // MATCH-FLAGS EXTENSION) BYTE-IDENTICAL (verified by the root planner: the
        // only change is the appended block). Updated through the change-authority
        // process, exactly as this guard provides for an approved header amendment.
        // Baseline re-bumped for the ARCH-search-case-mode amendment (authorized:
        // signed ARCH + root freeze 95bce88): ls_search_request GREW one trailing
        // `bool case_sensitive` and its case-folding prose was rewritten (smart-case
        // deleted). A v1 frozen-surface change under lock-step rebuild (no external
        // ABI consumer), NOT a byte-identical layout change — every OTHER symbol's
        // layout is unchanged. Updated through the change-authority process, exactly
        // as this guard provides for an approved header amendment.
        // Baseline re-bumped for the ARCH-security-hardening (v1) frozen-surface
        // work, resolving accumulated staleness in ONE pass: the guard had been left
        // pinned at the search-case-mode SHA through TWO api/ changes — the original
        // security-hardening freeze and its 2026-07-24 convergence amendment. The
        // header now reflects the CONVERGED contract: (d) is WITHDRAWN, so
        // ls_scan_progress carries NO expansion field (the original freeze's trailing
        // `bool expansion_capped` was RETIRED, not deprecated — no-backcompat v1);
        // (e) keeps LS_NET_ERROR_INSECURE_REDIRECT (8) / LS_NET_ERROR_SHORT_BODY (9)
        // and narrows LS_NET_ERROR_TIMEOUT (3) to connect-only (idle-read deferred);
        // (f) is NUMBER-AWARE copy neutralization (leading = / @ always; + / - only
        // for non-plain-number cells). A v1 frozen-surface change under lock-step
        // rebuild (no external ABI consumer). Updated through the change-authority
        // process. See docs/architecture/ARCH-security-hardening.md.
        expectEmptyDiff("api/lesssheet.h",
                        baseline: "b949b3dc8166c977c40ce451a37436ae057bf3e6b392f19704abf2c1c5c54805")
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
