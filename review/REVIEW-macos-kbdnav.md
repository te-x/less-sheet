# REVIEW — macOS keyboard-nav parity (cursor seed + auto-scroll + keyboard-only copy + accent outline)

**Verdict: PASS (1 round, clean).** Build cell (implementer + reviewer, both opus, run-id `mac_kbdnav`)
on branch `feat/kbdnav-a11y`; implementation commit `4085b2d`, frozen contract `59a508e`. Orchestrator
ran the trusted gate `--require-frozen --relay mac_kbdnav` = **GATE PASS** (integrity OK / conformance OK /
behavior GREEN 175/175; `swift build -warnings-as-errors` + `swiftlint --strict` clean); `verify-relay`
PASS; post-review tree-hash `4990b67e…` **unchanged** (clean binding). Signed design
`docs/architecture/ARCH-macos-kbdnav.md` (APPROVED 2026-07-22). Parallel to the GTK a11y slice; adopts the
same settled keyboard-nav interaction (the author's decisions, incl. seed-only/no-step + Cmd+arrow synonyms).

Ran in parallel with the GTK cell (`gtk_a11y`, disjoint component). No `api/` change → both AC23 SHA
baselines (`api/lesssheet.h`, `Contracts/ColumnPanel.swift`) verified byte-identical.

## What shipped (`Sources/LessSheetKit` + `Sources/LessSheetApp` only)
- **Pure module (gate-tested):** `KeyboardNavigator.navigate` (target-cell reducer composing the frozen
  `Selecting.select`/`extend`; seed top-left no-step from nil; **visible-column invariant** — a hidden
  incoming active column snaps to nearest visible at-or-below else first, BEFORE the motion), `RevealScroller`
  (byte-exact minimal-reveal, one 1-D clamp per axis, no-move-when-visible), `EscapeResolver` (dismiss >
  cancel-copy > clear-selection > none).
- **Grid wiring (gate-blind; reviewer + the author's macOS pass):** `NativeGrid+KeyNav.swift` (new) —
  `SheetTableView` key overrides route arrows/Page/Home-End/Cmd-arrows (+ `…AndModifySelection`) through the
  reducer; `controller.navigate` mutates selection + minimal auto-scroll via the existing `landOn` clip path;
  `pageRows()` + `horizontalReveal` single sources. `handleEscape` dispatches on `EscapeResolver` (dead
  `moveSelection` removed). Accent active-cell outline (`controlAccentColor`, 1pt inset) atop the marquee via
  `SelectionMark.isActive`.

## Reviewer-confirmed (the residue the gate can't see)
Reducer composes `Selecting` with no duplicated clamp; G4 snap cases hand-traced from general code (not
overfit). Reveal `horizontalReveal` prefix-sum is in the same coordinate space as `clip.bounds.origin.x`
(`refreshColumnWidth` sizes the single column to `totalDataWidth`) → no wide-doc bug. **Focus scope
verified:** all overrides are `SheetTableView` instance methods (fire only when it's first responder); NO
global capture (no `NSEvent` monitors, no `performKeyEquivalent`, no menu key-equivalents) → a focused
Find/Jump/Where field keeps its keystrokes. Dual selector families are defensive (one physical key → one
selector via `interpretKeyEvents`; no double-handling). `controller` back-refs `weak` (no cycle);
empty-extent → nil no-op; dead code fully removed. Cold-open budget passed all 5 corpus cases incl.
`wide_100k_cols`.

## Non-blocking notes for the author's macOS GUI pass (H1–H4; ARCH-designated, NOT defects)
- **H1** — the line-start/end overrides also capture emacs `Ctrl+A`/`Ctrl+E` (→ first/last visible column)
  in addition to Cmd+←/→; eyeball that no expected Ctrl+A/E behavior is lost. Confirm each physical key
  (Page Up/Down, Home, End, Cmd+arrows + Shift variants) lands as expected — which selector each binds isn't
  gate-verifiable, but the pure geometry is deterministic.
- **H2** — `Cmd+A` / whole-column / whole-row selections leave the active corner at a possibly-hidden last
  column or off-screen last row, so the accent outline won't show for those (pre-existing select-copy
  active-corner semantics; the reducer never produces a hidden active corner).
- **H4** — downward reveals land the active row's bottom at the literal viewport bottom edge (byte-exact per
  G5); confirm it reads well against the floating-controls overlay strip.

## PASSED: human macOS GUI pass (the author, 2026-08-04) — "H1, 2, 3 and 4 all feel good"

the author ran H1–H4 against `/Applications/less-sheet.app` reassembled 2026-08-03 21:39 — the first
bundle built on the **ReleaseSafe** core (`376abb9`), so the pass also covers the shipped-mode flip.
He separately confirmed the week's `.csv.gz` correctness work live: "csv.gz seems all correctly
handled" — i.e. the silent row-count drift (#14), the flate feed guard (#40) and the network-gzip
wedge are validated by hand as well as by the frozen locks. **#38 is closed.** The GTK/Orca pass
(#37, H-A1–H-A5) is still outstanding.

The original items, retained for the record:

## (was) Pending: human macOS GUI pass (the author, reassembled `.app`)
H1 keyboard-only select+copy (seed, move, auto-scroll, ←/→ visible columns, Cmd+C single cell) + physical-key
mapping; H2 accent outline light/dark + live accent; H3 Esc precedence + no focus hijack while typing; H4 no
regression + native auto-scroll feel. The implementer already reassembled `less-sheet.app` on fresh bits.
