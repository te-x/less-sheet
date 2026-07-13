// Frozen behavior tests — settings-panel-redesign discovery + Settings lifecycle
// (planner-owned). ARCH-column-config amendment: the adaptive discovery boundary
// and `#N` direct addressing (criteria 12/13), the bounded ten-result cap +
// overflow (criterion 12), and the deterministic Settings selection/search/
// disclosure lifecycle (criteria 17/19/22). PURE, no GUI, no core: the AppKit
// list reuse, off-main batched search, and window composition live in the app;
// THIS pins the deterministic decisions the SwiftUI/AppKit layer is thin over.
// The GUI end-to-end facts (sole surface, embedded O(viewport) at 100k, header
// deep-link, session reset) are pinned by SettingsRedesignProbeTests; the frozen
// C ABI + ColumnPanel.swift empty-diff by AmendmentContractGuardTests.
//
// RED SEED (Sources/LessSheetKit/ColumnDiscoveryLogic.swift, implementer-owned):
// `ColumnDiscovery` always reports `.fullList`, recognizes no `#N`
// (`resolveDirectAddress` returns nil), and retains every match uncapped;
// `SettingsLifecycleReducer` never validates/collapses/clears. So the new-value
// assertions FAIL while the tree compiles (conformance holds) — a behavior RED.
//
// The off-main batched (<=1024) label MATCH decision stays in the unchanged
// frozen `ColumnLabelSearching` (pinned by ColumnPanelTests); its cancellation
// within one batch / under 100 ms on query replacement, Settings close, or
// document replacement is a runtime concern (SettingsRedesignProbeTests +
// reviewer), not a pure unit.
import Foundation
import Testing
import Contracts
import LessSheetKit

@Suite("settings-panel-redesign discovery + lifecycle")
struct ColumnDiscoveryTests {

    private let d = ColumnDiscovery()
    private let r = SettingsLifecycleReducer()

    // Signature drift fails the build.
    @Test func conformancePins() {
        let _: any ColumnDiscoveryRouting = ColumnDiscovery()
        let _: any SettingsLifecycleReducing = SettingsLifecycleReducer()
    }

    // AC12 — the pinned adaptive-list and result-cap thresholds are both ten.
    @Test func discoveryThresholdsArePinned() {
        #expect(columnDiscoveryInlineListMax == 10)
        #expect(columnDiscoveryResultMax == 10)
    }

    // AC12 — the 0 / 1-10 / >10 discovery boundary. Six and ten columns show
    // the full unfiltered source-order list and NO search field (`.fullList`);
    // eleven and wide_100k_cols show search-only (`.searchOnly`) with no
    // unfiltered list; zero columns is the empty state. RED: seed is always list.
    @Test func discoveryModeFollowsTheColumnCountBoundary() {
        #expect(d.mode(columnCount: 0) == .empty)             // RED
        #expect(d.mode(columnCount: 1) == .fullList)          // guard
        #expect(d.mode(columnCount: 6) == .fullList)          // guard (six-column fixture)
        #expect(d.mode(columnCount: 10) == .fullList)         // guard (ten-column fixture)
        #expect(d.mode(columnCount: 11) == .searchOnly)       // RED (eleven columns)
        #expect(d.mode(columnCount: 100_000) == .searchOnly)  // RED (wide_100k_cols)
    }

    // AC12 — an exact `#N` addresses one valid 1-based column directly, never
    // scanning labels; `#1`, `#10`, `#100000` on the 100k fixture resolve. RED:
    // seed recognizes no direct address.
    @Test func directAddressResolvesValidOneBasedColumns() {
        #expect(d.resolveDirectAddress("#1", columnCount: 10) == .column(0))            // RED
        #expect(d.resolveDirectAddress("#10", columnCount: 10) == .column(9))           // RED
        #expect(d.resolveDirectAddress("#100000", columnCount: 100_000) == .column(99_999)) // RED
    }

    // AC12 — an ordinary (non-`#`) query is NOT a direct address; the caller hands
    // it to `ColumnLabelSearching`. A leading space is likewise an ordinary query,
    // not a `#`-input. RED: seed returns nil for these too, but so does GREEN —
    // these are the recognition-boundary guards that the `#N` cases below are RED
    // against.
    @Test func directAddressIgnoresOrdinaryQueries() {
        #expect(d.resolveDirectAddress("name", columnCount: 20) == nil)   // ordinary label query
        #expect(d.resolveDirectAddress("age", columnCount: 20) == nil)
        #expect(d.resolveDirectAddress("", columnCount: 20) == nil)       // empty query
        #expect(d.resolveDirectAddress(" #5", columnCount: 20) == nil)    // leading space: not a #-input
    }

    // AC12 — a `#`-prefixed but malformed / out-of-range address is "No such
    // column" (selection left unchanged by the caller): `#0`, over-count, leading
    // zero, sign, surrounding whitespace, a lone `#`, a non-ASCII digit, and
    // numeric overflow. Duplicate labels past the ten-result cap stay reachable
    // by a VALID `#N` (the resolve above). RED: seed returns nil, not noSuchColumn.
    @Test func directAddressRejectsMalformedAndOutOfRange() {
        #expect(d.resolveDirectAddress("#0", columnCount: 10) == .noSuchColumn)          // RED: zero
        #expect(d.resolveDirectAddress("#11", columnCount: 10) == .noSuchColumn)         // RED: > count
        #expect(d.resolveDirectAddress("#100001", columnCount: 100_000) == .noSuchColumn) // RED: > count
        #expect(d.resolveDirectAddress("#01", columnCount: 20) == .noSuchColumn)         // RED: leading zero
        #expect(d.resolveDirectAddress("#+5", columnCount: 20) == .noSuchColumn)         // RED: sign
        #expect(d.resolveDirectAddress("#5 ", columnCount: 20) == .noSuchColumn)         // RED: trailing whitespace
        #expect(d.resolveDirectAddress("#", columnCount: 20) == .noSuchColumn)           // RED: no digits
        #expect(d.resolveDirectAddress("#\u{0665}", columnCount: 20) == .noSuchColumn)   // RED: non-ASCII digit (Arabic-Indic 5)
        #expect(d.resolveDirectAddress("#999999999999999999999999999999", columnCount: 20) == .noSuchColumn) // RED: overflow
    }

    // AC12 — an ordinary search retains at most ten matching IDs in source order
    // plus ONE overflow Boolean, and stops on the eleventh match — never all
    // matching labels/IDs. Exactly ten matches is NOT overflow. RED: seed retains
    // every match and never sets overflow.
    @Test func ordinarySearchCapsAtTenWithOverflow() {
        // Nine matches across batches: retained, no overflow, keep scanning.
        var nine = ColumnMatchAccumulation.empty
        for batch in [[0, 1, 2, 3], [4, 5, 6, 7], [8]].map({ $0.map(UInt32.init) }) {
            nine = d.accumulate(nine, matches: batch)
        }
        #expect(nine.retained == (0..<9).map(UInt32.init))  // guard
        #expect(!nine.overflow)                             // guard
        #expect(!nine.stop)

        // Exactly ten matches: retained in full, still NOT overflow.
        let ten = d.accumulate(.empty, matches: (0..<10).map(UInt32.init))
        #expect(ten.retained == (0..<10).map(UInt32.init))  // guard
        #expect(!ten.overflow)                              // guard

        // An eleventh match across batches: retain the first ten, set overflow,
        // stop. RED: seed retains eleven and leaves overflow false.
        var eleven = ColumnMatchAccumulation.empty
        for batch in [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10]].map({ $0.map(UInt32.init) }) {
            eleven = d.accumulate(eleven, matches: batch)
        }
        #expect(eleven.retained == (0..<10).map(UInt32.init))  // RED (seed keeps 11)
        #expect(eleven.overflow)                               // RED
        #expect(eleven.stop)                                   // RED (derived from overflow)

        // Overflow inside a SINGLE batch caps at ten too.
        let burst = d.accumulate(.empty, matches: (0..<13).map(UInt32.init))
        #expect(burst.retained.count == 10)                    // RED (seed keeps 13)
        #expect(burst.retained == (0..<10).map(UInt32.init))   // RED
        #expect(burst.overflow)                                // RED

        // Overflow is sticky and never grows retained past ten on later batches.
        let sticky = d.accumulate(burst, matches: [100, 101])
        #expect(sticky.retained == (0..<10).map(UInt32.init))  // RED (seed appends 100,101)
        #expect(sticky.overflow)                               // RED
    }

    // AC22/AC17 — first opening in a logical session (or any close→reopen) clears
    // search, collapses BOTH disclosures, and restores the prior valid selection,
    // falling back to zero-based column 0 when absent/invalid and a column exists;
    // a zero-column document has no selection. RED: seed neither validates the
    // restored selection nor collapses.
    @Test func openingRestoresSelectionAndCollapsesDisclosures() {
        // No prior selection, columns exist -> column 0, collapsed, no query.
        #expect(r.opened(columnCount: 5, restoring: nil)
            == SettingsLifecycleState(selection: 0))                        // RED
        // A valid prior selection is restored, disclosures collapsed.
        let restored = r.opened(columnCount: 5, restoring: 3)
        #expect(restored.selection == 3)                                    // guard
        #expect(!restored.nullValuesExpanded && !restored.widthAutoFitExpanded) // RED (seed expands)
        #expect(restored.query.isEmpty)                                     // guard
        // An invalid restored selection falls back to column 0.
        #expect(r.opened(columnCount: 5, restoring: 9).selection == 0)      // RED (seed 9)
        #expect(r.opened(columnCount: 5, restoring: -1).selection == 0)     // RED
        // A zero-column document has no selection.
        #expect(r.opened(columnCount: 0, restoring: nil).selection == nil)  // guard
        #expect(r.opened(columnCount: 0, restoring: 2).selection == nil)    // RED (seed 2)
    }

    // AC22 — closing preserves the selection but clears search and collapses both
    // disclosures (expansion survives only until close). RED: seed keeps query +
    // expansion.
    @Test func closingClearsSearchAndCollapsesButKeepsSelection() {
        let open = SettingsLifecycleState(selection: 2, query: "foo",
                                          nullValuesExpanded: true, widthAutoFitExpanded: true)
        let closed = r.closed(open)
        #expect(closed.selection == 2)                                       // guard
        #expect(closed.query.isEmpty)                                        // RED
        #expect(!closed.nullValuesExpanded && !closed.widthAutoFitExpanded)  // RED
    }

    // AC22 — selecting a different column moves the selection but leaves the query
    // and BOTH disclosure expansions untouched (expansion survives a column
    // change). RED: seed collapses the disclosures on selection.
    @Test func selectingAColumnKeepsDisclosureExpansion() {
        let s = SettingsLifecycleState(selection: 1, query: "na",
                                       nullValuesExpanded: true, widthAutoFitExpanded: false)
        let sel = r.columnSelected(s, column: 4)
        #expect(sel.selection == 4)            // guard
        #expect(sel.query == "na")             // guard (query untouched)
        #expect(sel.nullValuesExpanded)        // RED (must survive)
        #expect(!sel.widthAutoFitExpanded)     // unchanged
    }

    // AC22 — each advanced disclosure toggles independently; selection/query
    // are untouched. RED: seed ignores the toggle.
    @Test func disclosuresToggleIndependently() {
        let base = SettingsLifecycleState(selection: 0)
        let n = r.disclosureSet(base, .nullValues, expanded: true)
        #expect(n.nullValuesExpanded)                          // RED
        #expect(!n.widthAutoFitExpanded)                       // unchanged
        let w = r.disclosureSet(n, .widthAutoFit, expanded: true)
        #expect(w.nullValuesExpanded && w.widthAutoFitExpanded) // RED
        let collapse = r.disclosureSet(w, .nullValues, expanded: false)
        #expect(!collapse.nullValuesExpanded)                  // RED
        #expect(collapse.widthAutoFitExpanded)                 // still expanded
        #expect(collapse.selection == 0 && collapse.query.isEmpty) // untouched
    }

    // AC22 — a header action raises Settings and selects the target. When the
    // target is already in current discovery/result rows the query is preserved;
    // above ten columns, when current results exclude it, the excluding label
    // query is replaced with the exact direct address `#N`. RED: seed neither
    // selects the target nor rewrites the query.
    @Test func headerActionDeepLinksTheTarget() {
        let inRows = r.headerAction(SettingsLifecycleState(selection: 1, query: "foo"),
                                    target: 4, columnCount: 20, targetInCurrentRows: true)
        #expect(inRows.selection == 4)       // RED (seed keeps 1)
        #expect(inRows.query == "foo")       // preserved (guard)

        let excluded = r.headerAction(SettingsLifecycleState(selection: 1, query: "zzz"),
                                      target: 50, columnCount: 100, targetInCurrentRows: false)
        #expect(excluded.selection == 50)    // RED (seed keeps 1)
        #expect(excluded.query == "#51")     // RED (clears query, resolves via #N)
    }

    // AC22/AC19/AC18 — a SAFE internal Parsing re-open preserves the selected
    // ordinal (clamped, else column-0 fallback) and clears search; an UNSAFE map
    // falls back to column 0 (or no selection when zero columns) and clears
    // search. The safe/unsafe decision itself is the existing frozen
    // `ColumnSessionModeling`. RED: seed clears neither and never resets.
    @Test func parsingReopenPreservesOnSafeResetsOnUnsafe() {
        let safe = r.parsingReopened(SettingsLifecycleState(selection: 2, query: "x"),
                                     decision: .replayOrdinally, columnCount: 5)
        #expect(safe.selection == 2)         // preserved (guard)
        #expect(safe.query.isEmpty)          // RED
        // A safe replay whose old ordinal no longer fits falls back to column 0.
        #expect(r.parsingReopened(SettingsLifecycleState(selection: 7),
                                  decision: .replayOrdinally, columnCount: 5).selection == 0) // RED

        let unsafe = r.parsingReopened(SettingsLifecycleState(selection: 3, query: "y"),
                                       decision: .resetAll, columnCount: 5)
        #expect(unsafe.selection == 0)       // RED (seed keeps 3)
        #expect(unsafe.query.isEmpty)        // RED
        #expect(r.parsingReopened(SettingsLifecycleState(selection: 3),
                                  decision: .resetAll, columnCount: 0).selection == nil) // RED
    }

    // AC19/AC22 — an explicit new document is a fresh logical session: selection
    // falls back to column 0 (none when empty), search is cleared, both
    // disclosures collapse. RED: seed gives no column-0 fallback and leaves
    // disclosures expanded.
    @Test func documentOpenResetsSelectionSearchAndDisclosures() {
        let doc = r.documentOpened(columnCount: 5)
        #expect(doc.selection == 0)                                   // RED (seed nil)
        #expect(doc.query.isEmpty)                                    // guard
        #expect(!doc.nullValuesExpanded && !doc.widthAutoFitExpanded) // RED (seed expands)
        #expect(r.documentOpened(columnCount: 0).selection == nil)    // guard
    }
}
