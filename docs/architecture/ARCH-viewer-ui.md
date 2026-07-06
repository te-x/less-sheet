# ARCH — viewer-ui

The real macOS UI replacing the walking-skeleton shell, plus the slice-2 core machinery it
needs: windowed viewport access over files of any size, a background row index, jump-to-row
with visible progress, and dialect guessing (separator, quote char, header) surfaced as
overridable "guess-pills". Supersedes the skeleton's fixed 200-row head window.

Decisions in this doc were made interactively with the author on 2026-07-05.

## Problem & scope

The walking skeleton proved the pipeline (Zig core → C ABI → Swift UI) but is capped at a
200-row head, comma-only, with a throwaway UI. This slice delivers:

1. **Core**: windowed row access over arbitrarily large files; a background row indexer;
   jump-scans with progress; dialect sniffing (separator + quote char, extending the existing
   header suggestion) and caller-forced dialect overrides.
2. **UI**: the intended chromeless, data-first macOS app — full-window spreadsheet grid,
   hover-revealed floating controls in the Liquid Glass style, guess-pills, a Configure
   window (v1), native components wherever they meet the design.

### Non-goals (this slice)
- Find/filter (slice 4). No find/filter button appears — no dead controls.
- Column datatype inference, formatting overrides, column resize/alignment (slices 5/9).
  The Configure window is designed with room for them but ships without them.
- Encodings beyond UTF-8-assumed bytes, ragged-row policy changes, huge single-row
  hardening beyond what the dialect already pins (slice 3).
- Per-file persistence of overrides (session-only; a later feature may persist).
- XLSX/Parquet, Linux, editing of any kind (project non-goals).

## Inputs / Outputs

**Inputs**
- A file path (Finder open/drag, `File › Open`, CLI argument) — unchanged launch modes.
- A dialect override from the UI: separator = any single ASCII byte except CR/LF and the
  quote char (sniff candidates: `,` `;` TAB `|`); quote = any single ASCII byte except
  CR/LF and the separator, or NONE meaning quote characters are literal text (sniff
  candidates: `"` `'`); header = on/off. Overrides are per-open, session-only.
- Scroll position changes and jump requests (target row number, 0/1-based per UI copy,
  64-bit).

**Outputs (nominal)**
- A window whose content is entirely the spreadsheet grid (data top-left, empty grid cells
  extending to both window edges — the established fill), scrollable through the whole file.
- The core's dialect guess and header suggestion, rendered as the current values of the
  guess-pills.
- Progress states: background indexing progress (fraction of file bytes indexed) and
  jump-scan progress (fraction of the distance to the target), each observable by the UI at
  poll granularity ≤ 100 ms.
- Row-count knowledge: `(count, exact|estimated)` — estimated = file bytes ÷ mean indexed
  row bytes until the index completes, then exact.

**Error cases**
- Open failures: unchanged (not-found / permission / other-IO), same in-window error panel.
- A dialect override that yields zero columns (e.g. separator not present) is NOT an error:
  the file renders as a single column, exactly as a wrong guess would.
- Jump target beyond the last row: clamps to the last row (discovered by scanning to EOF).
- Cancelled jump-scan: the viewport returns to where it was when the jump started; the
  frontier keeps whatever the scan indexed (paid once, kept). No error.

## Functional requirements

**Window & chrome**
1. Chromeless: no visible title bar; grid content occupies the full window frame. Traffic
   lights are hidden at rest and revealed together with the floating controls. The window
   still carries the document title for Mission Control / Window menu / Dock.
2. Launch modes and determinism as the skeleton pinned them (direct exec, `open --args`,
   doc-launch, no-args) — one window, one timing marker on the first data-bearing frame,
   silent on error/empty. The `lesssheet.first_rows_visible_ms=` marker format is unchanged.
3. Launch with no document: the empty window immediately presents the native open panel;
   cancel leaves the empty grid with the menu bar available. `File › Open` remains a menu
   item; the temp shell's duplicate "View" menu and reachable empty Settings window are gone.
4. Drag & drop of a file onto the window or Dock icon opens it (replacing the document, as
   today).

**Floating controls (the overlay)**
5. At rest the window shows only data. Mouse movement over the window reveals the overlay;
   it fades after ~2 s of pointer inactivity (exact timing is presentation state). Keyboard
   users can reveal/reach every control (Tab or a shortcut); all controls are
   accessibility-labelled.
6. The overlay uses the macOS 26 Liquid Glass materials (`glassEffect` family) and contains,
   as a vertical cluster: the document filename (display only), the jump-to-row button, the
   guess-pills, and the Configure button. Placement of the cluster and of progress feedback
   is presentation state — v1 renders progress within/adjacent to the cluster; expect
   iteration after first build reviews (explicitly allowed without contract change).
7. Jump-to-row: opens a small field accepting a row number (digits only; 64-bit). It shows
   the current row-count knowledge, marked "estimated" while the index is incomplete
   (e.g. "~12.4M rows, estimating…"). Submitting jumps; if the target lies beyond the scan
   frontier the control shows scan progress (percentage) with a cancel affordance (Esc);
   cancel returns the viewport to the pre-jump position (the scan's index gains are kept).
   Suggested shortcut ⌘J (presentation state).
8. Guess-pills: one compact circular control per guessed parameter — header (on/off),
   separator, quote char — each showing the CURRENT effective value (e.g. `,` · `"` · "H").
   Clicking expands that pill into a vertical list of its candidate values (separator:
   `,` `;` TAB `|`; quote: `"` `'` NONE; header: on/off) plus, for separator and quote, a
   "custom…" entry accepting exactly one ASCII character. Selecting a value applies it
   immediately (see 10). The pill visually distinguishes "guessed" from "user-overridden"
   state (presentation detail).
9. Configure (v1): a button opening a separate, normal (titled) window with the same three
   parse parameters (bound to the same state as the pills) plus per-column visibility
   checkboxes (columns listed by effective header name or generic A/B/C names). The last
   visible column cannot be hidden. Layout leaves obvious room for the future
   datatype/formatting sections. Closing the window keeps settings (session state).
10. Changing separator, quote, or header re-opens the document with the forced dialect:
    the head re-renders instantly (open stays O(viewport)); the row index restarts (its
    progress feedback restarts too — acceptable, user-initiated). Hidden-column choices
    survive a re-open within the session as long as the column count is unchanged; if the
    column count changes, visibility resets to all-visible.
11. Hidden columns are removed from the rendered grid (widths re-flow); data addressing in
    the core is unaffected (hiding is pure presentation).

**Scrolling, index, jump (core-backed)**
12. The grid scrolls vertically through the ENTIRE file, however large. The frontend
    requests a contiguous row window (viewport + ≈2× scroll buffer each direction) from the
    core; the core serves windows behind the scan frontier instantly and evicts storage for
    rows left behind. Sequential scrolling never blocks the UI thread and never shows a
    stall: worst case briefly shows empty cells that fill in.
13. A background indexer starts at open and advances a sparse row index (row → byte offset
    at safe record boundaries, correct under quoted embedded newlines) to EOF, without
    blocking accessors. Its progress (bytes indexed / file bytes) is observable. Memory for
    the index is O(checkpoints), never O(rows).
14. The vertical scrollbar reflects total rows: estimated (file size ÷ mean row bytes so
    far) while indexing, correcting as the index advances, exact after completion. Thumb
    drift during refinement is acceptable; jumps in either direction remain accurate.
15. Scrolling/dragging beyond the frontier and jump-to-row use the same machinery: scan
    forward to the target, feeding the row index (cost paid once), with progress visible
    from the first moment. Everything behind the frontier is permanently instant; backward
    navigation never blocks. Targets are never served by byte-offset guessing.
16. Horizontal: column widths are measured from the loaded head sample once (clamped to
    sane min/max), then frozen for the document's session; columns overflowing the window
    scroll horizontally with the leftmost visible column's grid alignment intact. The sticky
    header row stays pinned vertically and scrolls horizontally with its columns.

**Dialect sniffing (core)**
17. At open (unless overridden), the core sniffs separator and quote char over the head
    sample only: candidates as in req 8, scored for consistent field counts across sampled
    records (exact scoring is implementation detail; ties break toward comma and double
    quote). The existing header suggestion then applies under the chosen dialect. Sniffing
    adds O(head) work only. The chosen dialect is reported to the frontend (pill values).
18. A forced dialect (any combination of separator/quote/header) bypasses sniffing for
    those parameters. Custom bytes per the Inputs constraints are honored exactly.

## Non-functional constraints
- **Cold start < 500 ms** launch → first rows visible, unchanged, for any file size,
  including sniffing (O(head) only).
- Open remains **O(viewport)**; no full-file work before first paint, ever.
- **No silent stalls**: any operation that can exceed ~100 ms perceived latency (jump-scan,
  drag past frontier, index restart) shows progress feedback from its first moment and is
  cancellable where meaningful. The UI thread never blocks on core calls that can scan
  (window requests behind the frontier are the only synchronous-fast path).
- **Memory**: steady-state RSS while viewing any file ≤ 10 GB stays **< 120 MB** (framework
  baseline ~90 MB dominates; buffer + sparse index must stay within the remainder; the
  skeleton's ~4.5 MB headroom motivated the raise from 100). Transient scan state doesn't
  count against steady-state but must be released when the scan ends.
- **Scroll smoothness**: continuous scrolling within the indexed region drops no frames at
  60 Hz in reviewer measurement (no main-thread hitch > 17 ms attributable to row serving).
- Bundle stays single-digit MB. macOS **26 minimum** (Liquid Glass) — deployment target
  bump is part of this slice's contract amendment. Native components (scrollbars, open
  panel, menus, windows) wherever they meet the design; the grid itself remains custom
  (spreadsheet fill — decided with the skeleton).
- Zig 0.16.0 pinned; docs-first rule stands. Read-only core; never modify/lock/copy source.

## Component decomposition & data flow

- **api/lesssheet.h (root-frozen, amended)**: the head-window surface (`LS_HEAD_MAX_DATA_ROWS`,
  head accessors) is superseded by: open-with-options (forced dialect), windowed row access
  (64-bit row addressing), row-count knowledge (count + exactness), index/scan control and
  progress, dialect report. Exact types/signatures are the planner's; semantics above.
  Existing ownership rules (core owns storage; borrowed text valid until release/eviction —
  planner pins the eviction-safety rule), zero-alloc accessor discipline, and threading
  rules (core may own background threads; accessors safe from any thread; progress pollable)
  carry over.
- **backend/ (Zig)**: dialect sniffer; windowed reader with eviction; background indexer
  thread feeding the sparse row index; jump-scan sharing the indexer machinery; forced-
  dialect open path. Existing mmap head reader and lexer generalize (parameterized dialect).
- **apps/macos/Sources/Contracts (frozen, amended)**: protocol layer grows windowed
  document access, dialect/report types, progress observation, and view-model contracts for
  pills/configure/jump state. `Package.swift` gains the macOS 26 platform bump.
- **apps/macos LessSheetKit**: bridges the new ABI (window paging, progress polling,
  dialect forcing); LessSheetApp: the chromeless window, overlay cluster, pills, Configure
  window, jump control, scrollbar estimation — replacing the skeleton shell (delegate-owned
  window architecture and the `LESSSHEET_DUMP_FRAME` self-render hook are kept; the hook
  must capture overlay states too).

Flow: open(path, overrides?) → sniff (unless forced) → head window + pills report →
first paint (< 500 ms) → indexer advances in background (progress observable) → UI pages
row windows as the user scrolls → jump/drag-past-frontier triggers scan-with-progress →
index completion turns estimates exact.

## External interfaces
Only the C ABI between core and frontends (above). No network, no persistence store
(session-only state lives in the app process), no new external dependencies (Zig std +
Apple SDKs only — bundle budget).

## Acceptance criteria (each testable)

*Core (gate-enforced by contract tests)*
1. Open with forced dialect (each candidate separator, custom byte, each quote incl. NONE,
   header on/off) parses a fixture correctly; zero-column-yielding separator renders one
   column; CR/LF-conflicting or quote==separator overrides are rejected at the API boundary
   as a distinct usage error.
2. Sniffer picks the right dialect on fixtures for each candidate pair (incl. quoted fields
   containing other candidates); ambiguous fixtures resolve to comma/double-quote; sniffing
   reads only the head sample (enforced by an access-counting/probe test).
3. Header suggestion behaves per the existing pinned grammar under every sniffed/forced
   dialect.
4. Windowed access: any (start,row-count) window behind the frontier serves exact cell text
   with zero allocation on the access path; rows evicted and re-served on re-request match
   byte-for-byte; row addressing is 64-bit clean.
5. Index correctness: on fixtures with quoted embedded newlines and CRLF mixes, every
   checkpoint maps to a true record boundary; count turns exact at completion and equals
   the true record count.
6. Progress monotonicity: index and jump-scan progress values are monotonically
   non-decreasing to 1.0; row-count estimate is available from first paint and marked
   estimated until final.
7. Jump semantics: jump to row N beyond the frontier lands exactly on N (or clamps to last
   row at EOF); cancellation mid-scan returns the viewport to the pre-jump position while
   keeping the frontier advanced (a re-jump into the scanned region is then instant); a jump
   behind the frontier is instant (no scan).
8. Open with a 10 GB-class fixture: open cost measured O(head) (bytes-read probe), first
   window served < 50 ms in-core.

*App (gate-enforced where headless; reviewer-measured otherwise)*
9. Cold start < 500 ms (marker) for tiny and multi-GB fixtures across all launch modes;
   one window, one marker, error/empty silent — as the skeleton pinned.
10. Frame dumps show: chromeless full-window grid with the spreadsheet fill on tiny and
    huge fixtures; overlay revealed state (controls + filename + pills with correct current
    values); Configure window with parse params + column checkboxes; error panel unchanged.
11. Pill override of separator/quote/header re-renders correctly (dump-verified before/after
    on a semicolon fixture guessed wrong on purpose via forced-initial dialect); hidden
    columns disappear from dumps and reflow widths; last visible column's checkbox is
    disabled.
12. Jump-to-row within head, behind frontier, and beyond frontier (scan) each land on the
    exact target row (dump shows target row's distinctive content); beyond-frontier jump
    exposes observable progress states on the way (probe via the app's state logging).
13. Steady-state RSS < 120 MB viewing the 10 GB-class fixture after: open, scroll 10k rows,
    jump to 50%, jump to end (reviewer-measured, dump hook disabled).
14. Reviewer-measured: scroll smoothness (no >17 ms main-thread hitch serving rows within
    the indexed region), overlay reveal/fade behavior, traffic-light hover reveal,
    auto-open panel on no-document launch. Human-eyes items listed by the reviewer as usual.

## Open Questions
None. (Progress-feedback placement and overlay cosmetics are explicitly presentation state,
revisited freely during build rounds without contract change.)
