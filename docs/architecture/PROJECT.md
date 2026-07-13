# less-sheet — project brief

## What & why
A spreadsheet **viewer** built for speed: open tabular files the way `less` opens text — instantly,
regardless of file size. One shared native core (Zig) owns file access, parsing, and windowed row
access; thin per-platform frontends render. Existing tools (Excel, Numbers, LibreOffice) cold-start
in seconds and choke on large files; for less-sheet, **time-to-first-rows is the product**.

## Users & primary use cases
- Developers / data engineers — peek at a CSV (log export, dataset, dump): open, scroll, search,
  close, without waiting. `open file.csv` / drag onto the app and it's just there.
- Analysts — sanity-check multi-GB exports that spreadsheet apps refuse to open or swap on.

## Stack & tools (and why)
- **core**: Zig **0.16.0** (pinned, gate-enforced) — a static library exposing a **C ABI**;
  no runtime dependencies; mmap-based file access. The C headers in `api/` are the frozen,
  language-neutral cross-component contract.
- **Docs-first Zig**: 0.16.0 postdates most training data and the language churns — every agent
  verifies Zig APIs against the locally installed std source / docs (pointers in `CLAUDE.md`),
  never from memory.
- **macOS frontend**: Swift 6 / SwiftPM, **minimum macOS 26** (approved 2026-07-13 with column-config —
  enables the chromeless Liquid-Glass control panel + native exact-decimal/ISO FormatStyles). SwiftUI
  baseline, AppKit escape hatch if the cold-start budget demands it. Links the core **statically — in-process, no helper process, no IPC** (a
  process boundary would spend the cold-start budget before the file is even open).
- **Future frontends**: Linux (toolkit TBD — research first), possibly a TUI. All consume the same
  `api/` headers.
- **Dependencies & binary size**: the distributed app stays **single-digit MB**. A dependency is
  admissible only if it serves the windowed data flow AND fits the size budget. Expected: the CSV
  path is a DIY mmap lexer (Zig std only); XLSX/Parquet library-vs-DIY decided at their slices
  (Arrow/DuckDB-class readers are excluded by the budget).
- **Build & gate**: `zig build` / `zig build test` (core), `swift build` / `swift test` (macOS).
  Per-component `.aidev/gate.sh`, chained by the workspace root gate.

## Hard constraints
- **Cold start < 500 ms** on Apple Silicon: app launch → first rows of the target file visible.
  Applies to every frontend, forever. This is the **only** operation required to be instant.
- **No silent stalls**: every non-instant operation (jump-scans, indexing, search, future stats)
  shows constant feedback — progress bars, scan percentages — from the first moment, and never
  blocks the UI thread. Slow is acceptable; unexplained is not.
- **Open is O(viewport), not O(file)**: no full-file scan, parse, or copy before first paint.
  mmap + lazy/background indexing; a 10 GB CSV opens as fast as a 10 KB one.
- **Windowed reads**: the core parses only enough to fill the current viewport plus a scroll
  buffer (≈2× the viewport in each direction), evicts what falls behind, and re-parses on
  demand. Memory scales with buffer + sparse row index — never with file size.
- **Jumps & the scan frontier**: sequential scrolling never blocks (parse forward from where you
  are). A jump beyond the scanned region (e.g. row 10⁹ from the top) is served by scanning
  forward to the target **with visible progress feedback** — never denied, never guessed from
  byte offsets. The jump-scan and the background indexer are the same machinery: every byte
  scanned feeds the sparse row index, so the cost is paid once, and everything behind the scan
  frontier is permanently instant (backward navigation never blocks).
- **Read-only core**: source files are never modified, locked, or copied.
- **Formats**: CSV first; XLSX and Parquet later — the core's public surface must not bake in
  "a document is a text file".
- **Maniacal perf & memory discipline**: every slice is designed and reviewed against speed and
  low memory consumption. ARCH docs state measurable targets; the reviewer verifies them by
  measurement, not by claim.

## Non-goals
- No editing, no cell formulas, no charting — a viewer, period. (Read-only conveniences —
  display precision, hidden columns, quick column stats — are *future slices*, not non-goals;
  they are presentation-layer transforms and never modify the source.)
- No cloud, sync, or collaboration.
- No Windows frontend (for now).
- No plugin system until at least two formats ship natively.

## Domain glossary
- **core** — the Zig library behind the C ABI; the only component that touches files.
- **frontend** — a thin platform UI; renders what the core serves, owns no parsing.
- **api/** — the frozen, language-neutral C headers every component builds against.
- **document** — one opened tabular file, whatever its format.
- **view** — an ordered row set over a document. Today only the identity view (all rows, file
  order); filtered views later. All row addressing is view-relative.
- **viewport** — the row/column window (within a view) a frontend currently displays; the unit
  the core serves.
- **row index** — the core's background-built sparse map from row number to byte offset (safe
  row-boundary checkpoints), enabling random access despite quoted newlines. Until it completes,
  positions beyond the parsed region are estimates.
- **scroll buffer** — rows/columns parsed beyond the viewport (≈2×) so scrolling never blocks;
  evicted as the window moves on.

## Feature slices (rough, ordered)
1. **Walking skeleton** — the macOS app opens a small CSV through the C ABI and shows its first
   rows. End-to-end proof: Zig core → `api/` header → Swift UI; both component gates green.
2. **Instant open + virtual scroll** — mmap, background row indexing, smooth scrolling of
   multi-GB files; cold-start and time-to-first-rows budgets measured and enforced.
3. **Real-world CSV** — quoting, embedded newlines, encodings, ragged rows, huge single rows.
4. **Find & seek** — incremental streaming search with progress over not-yet-indexed regions:
   plain-text match and typed column predicates (jump to next/first row where col == X).
5. **Column ergonomics** — widths, alignment, sticky header, type-aware rendering.
6. **XLSX** (read-only). 7. **Parquet**. 8. **Linux frontend** (research spike first).
9. **Viewer utilities (future)** — display formatting (e.g. decimal precision), hidden columns,
   quick column stats (sum, avg, …). Architectural givens: value typing/inference lives in the
   core (shared by all frontends); these are view-layer transforms over immutable source; column
   stats are streaming scans reusing the progress-feedback scan machinery from slice 2.
10. **Filtered views (future)** — show only rows where col == Y: a derived row set (its own
    match index, built by a progress-reporting scan) over the same windowed machinery.
    Architectural given from day one: the core addresses rows **within a view** (the unfiltered
    document being the identity view), never as bare physical file rows — so filtering is a new
    view kind, not a breaking change to the addressing model.

## Open questions
- Column widths come from sampled windows only — freeze after first window vs refine-as-you-scroll.
- Linux frontend toolkit (GTK4? Qt? TUI first?) — research before slice 8.
- Distribution: notarized DMG vs Homebrew cask vs App Store (sandbox entitlements vs mmap of
  arbitrary user paths) — decide before first release.
- XLSX/Parquet: pure-Zig readers vs vendored C libraries — decide at those slices.
