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
- **macOS frontend**: Swift 6 / SwiftPM. SwiftUI baseline, AppKit escape hatch if the cold-start
  budget demands it. Links the core **statically — in-process, no helper process, no IPC** (a
  process boundary would spend the cold-start budget before the file is even open).
- **Future frontends**: Linux (toolkit TBD — research first), possibly a TUI. All consume the same
  `api/` headers.
- **Build & gate**: `zig build` / `zig build test` (core), `swift build` / `swift test` (macOS).
  Per-component `.aidev/gate.sh`, chained by the workspace root gate.

## Hard constraints
- **Cold start < 500 ms** on Apple Silicon: app launch → first rows of the target file visible.
  Applies to every frontend, forever.
- **Open is O(viewport), not O(file)**: no full-file scan, parse, or copy before first paint.
  mmap + lazy/background indexing; a 10 GB CSV opens as fast as a 10 KB one.
- **Bounded memory**: never load the whole file; memory scales with viewport + index, not file size.
- **Read-only core**: source files are never modified, locked, or copied.
- **Formats**: CSV first; XLSX and Parquet later — the core's public surface must not bake in
  "a document is a text file".

## Non-goals
- No editing, no formulas, no charting — a viewer, period.
- No cloud, sync, or collaboration.
- No Windows frontend (for now).
- No plugin system until at least two formats ship natively.

## Domain glossary
- **core** — the Zig library behind the C ABI; the only component that touches files.
- **frontend** — a thin platform UI; renders what the core serves, owns no parsing.
- **api/** — the frozen, language-neutral C headers every component builds against.
- **document** — one opened tabular file, whatever its format.
- **viewport** — the row/column window a frontend currently displays; the unit the core serves.
- **row index** — the core's lazily / background-built map from row number to byte offset,
  enabling random access without a full scan.

## Feature slices (rough, ordered)
1. **Walking skeleton** — the macOS app opens a small CSV through the C ABI and shows its first
   rows. End-to-end proof: Zig core → `api/` header → Swift UI; both component gates green.
2. **Instant open + virtual scroll** — mmap, background row indexing, smooth scrolling of
   multi-GB files; cold-start and time-to-first-rows budgets measured and enforced.
3. **Real-world CSV** — quoting, embedded newlines, encodings, ragged rows, huge single rows.
4. **Search** — incremental streaming search with progress over not-yet-indexed regions.
5. **Column ergonomics** — widths, alignment, sticky header, type-aware rendering.
6. **XLSX** (read-only). 7. **Parquet**. 8. **Linux frontend** (research spike first).

## Open questions
- Linux frontend toolkit (GTK4? Qt? TUI first?) — research before slice 8.
- Distribution: notarized DMG vs Homebrew cask vs App Store (sandbox entitlements vs mmap of
  arbitrary user paths) — decide before first release.
- XLSX/Parquet: pure-Zig readers vs vendored C libraries — decide at those slices.
