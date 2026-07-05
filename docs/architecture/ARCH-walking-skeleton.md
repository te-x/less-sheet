# ARCH — walking-skeleton (slice 1)

The macOS app opens a CSV file through the Zig core's C ABI and shows its first rows.
This slice proves the **pipeline**, thin: Zig parser → frozen C ABI (`api/`) → Swift wrapper →
SwiftUI pixels, with the zig↔SwiftPM build chain, the `.app` bundle, and both component gates
green. Every later slice deepens a layer of what this slice wires up.

## Problem & scope

**In scope**
- Open a CSV via three user paths sharing one internal entry: File › Open… dialog,
  launch-with-file (Finder double-click / `open -a LessSheet file.csv` via file-type
  association), and a CLI path argument to the binary.
- Parse the **head** of the file — enough to serve the first **N = 200** data rows (planner may
  pin N as a named constant; it must overfill any current screen) — with a **quote-aware
  RFC-4180 lexer**: quoted fields, embedded commas and newlines inside quotes, `""` escapes,
  LF and CRLF row endings. Comma delimiter only.
- Display rows in a plain scrollable table capped at N rows (no virtual scrolling — slice 2).
- **Header rule**: row 1 is the header **unless every cell of row 1 is numeric** (then row 1 is
  data and columns get generic spreadsheet names A, B, …, Z, AA, AB, …). The core computes the
  suggestion (typing is core-side); the frontend applies it and **must offer a user override**
  (menu item, checkable: "First Row Is Header") that re-derives the display immediately without
  reopening. The header is rendered in the table's sticky header slot — it is never a normal
  scrolling row.
- **Errors**: distinct open failures (not found, permission denied, I/O error) cross the ABI as
  distinct codes and render as an **in-window error state** (icon + message + path) in place of
  the table. An **empty file is not an error**: it opens as an empty table.
- Encoding: assume UTF-8; a leading UTF-8 BOM is stripped; invalid byte sequences render as
  U+FFFD at the display boundary. (Full encoding handling is slice 3.)
- Ragged tolerance (minimal): column count = the header row's field count (or row 1's if
  headerless). Longer rows are truncated to it; shorter rows are padded with empty cells.
  (Real ragged-row handling is slice 3.)

**Non-goals (this slice)**
- No scrolling beyond N / no windowed viewport machinery (slice 2), no row index, no jumps.
- No search, no drag & drop, no multi-window (opening a file while one is open **replaces** the
  document in the existing window), no recents, no column resize/sort, no toggle persistence.
- No delimiter sniffing (comma only), no UTF-16/Latin-1, no XLSX/Parquet.
- No progress UI: every operation in this slice is near-instant by construction (head-only
  reads); the no-silent-stalls machinery starts in slice 2.

## Inputs / Outputs

**Input**: a local file path (from dialog, `onOpenURL`-style app event, or CLI argv). File may
be any size; only its head region is ever read in this slice.

**Output (nominal)**: a rendered table — sticky header (real or generic A/B/C names) + up to N
data rows of cell text; cells beyond the loaded region simply don't exist yet.

**Output (error)**: in-window error panel showing a human message derived from the ABI error
code plus the offending path.

Edge inputs and their defined outcomes:
- Empty file (0 bytes) → empty table, zero columns, zero rows; header toggle is a no-op.
- File with a single row, not all-numeric → header only, zero data rows.
- File with a single row, all-numeric → generic headers, one data row.
- Row 1 like `1,,3` (empty cell) → empty cell is **not numeric** → not all-numeric → header.
- Fewer than N rows in file → all rows shown; no error.
- File whose row 1 is wider/narrower than later rows → truncate/pad per the ragged rule.
- Numeric cell definition (for the heuristic): after ASCII-whitespace trim, non-empty and fully
  matching an integer/float grammar (optional sign, digits, optional fraction, optional
  exponent). `"1e5"` is numeric; `""`, `"0x1F"`, `"1,000"`, `"12 "` (trailing junk after trim
  rules — planner pins the exact grammar) are not.

## Functional requirements

1. One internal open path: all three user-facing entries funnel into a single open(path) flow.
2. The core owns file access and parsing; the frontend owns presentation state (header toggle).
3. The core exposes, over the C ABI: open → handle or distinct error code; loaded dimensions
   (row count ≤ N+1, column count); borrowed cell text access by (row, column); the header
   suggestion (row-1-all-numeric fact or equivalent); close. Exact C signatures are the
   planner's to freeze in `api/` — a single C header is the entire cross-component surface.
4. Memory ownership across the ABI: the core owns all storage; cell text crosses as borrowed
   UTF-8 (pointer + length) valid until document close (planner pins the exact validity
   window); no per-cell heap allocation on the access path; Swift copies at the render boundary.
5. Opening must not block the main thread (structure: open on a background queue, results
   published to the UI); with head-only reads it will be near-instant regardless.
6. The app is a real `.app` bundle (assembled from the SwiftPM binary + Info.plist) declaring
   the CSV file-type association so Finder/`open -a` launching works.
7. Debug and release builds emit a single timing marker (e.g. one stderr/os_signpost line)
   `lesssheet.first_rows_visible_ms=<int>` measured from process start to first frame with data
   — the hook the reviewer (and slice 2's budget enforcement) measures against.

## Non-functional constraints (measured, not claimed)

- **O(viewport) open**: opening a ~1 GB CSV touches only its head region. Core-level: open +
  first-window materialization completes in **< 50 ms** on Apple Silicon (release), independent
  of file size.
- **Cold start**: `open -a LessSheet <1 GB fixture>` → `first_rows_visible_ms` **< 500 ms**
  (median of 3 cold launches, release build).
- **Memory**: peak RSS after opening the 1 GB fixture **< 100 MB** (proves no full-file load).
- **Binary budget**: the assembled `.app` totals **single-digit MB**.
- Zig 0.16.0 pinned (gate-enforced); docs-first rule from `CLAUDE.md` applies to all Zig work.

## Component decomposition & data flow

- **`api/` (root-frozen)** — one C header: opaque document handle, open/close, dimensions,
  borrowed cell access, header suggestion, error codes. The only cross-language surface.
- **`backend/` (Zig core)** — bounded head reader (mmap or bounded read — implementer's choice
  within the O(viewport) constraint), quote-aware lexer, head-window materializer (≤ N+1 rows),
  numeric-cell test + header suggestion, error mapping. Implements exactly the `api/` header.
- **`apps/macos/`** —
  - `LessSheetKit` (library): Swift wrapper over the C module (RAII handle, error enum,
    `[[String]]` snapshot copy at the boundary), view model (header heuristic application,
    toggle, generic column names, truncate/pad rule).
  - App executable: SwiftUI shell — window, Table with sticky header, error panel, Open dialog,
    open-URL event handling, CLI arg handling, timing marker.
  - Bundle assembly: a build step producing `LessSheet.app` (Info.plist with CSV UTI
    association) from the SwiftPM binary.

Data flow: open event → background open(path) in core → handle + dims + suggestion → Kit copies
head cells into an immutable snapshot → view model derives (header mode, column names, rows) →
Table renders; marker emitted on first data frame. Errors short-circuit to the error panel.

Build/gate flow: `backend` gate = `zig build` + `zig build test`. `apps/macos` gate builds the
core artifact first (mechanism is the planner's — e.g. its conformance command invoking the
backend build) then `swift build` + `swift test`; Swift tests exercise the REAL linked core
through the ABI (fixture-based integration, not mocks). Root gate chains both after checking
`api/` integrity.

## External interfaces

- macOS file-open plumbing: NSOpenPanel (dialog), Finder/LaunchServices open events (bundle UTI
  association), `CommandLine.arguments` (CLI path).
- No network, no persistence, no other external services.

## Acceptance criteria (each testable)

Backend (Zig tests, frozen):
1. Lexes plain CSV: `a,b\n1,2\n` → 2×2 grid with expected cell texts.
2. Quoted field with embedded comma and newline: `"x,y"` and `"line1\nline2"` land in single
   cells; row count reflects quote-aware boundaries.
3. `""` escape inside quoted field produces a literal `"`.
4. CRLF and LF files produce identical grids; trailing-newline presence does not change row count.
5. Leading UTF-8 BOM is absent from the first cell's text.
6. A file with > N rows loads exactly N data rows (+ header if present); a file with fewer
   loads them all.
7. Ragged rule: rows wider than the column count are truncated; narrower rows read as empty
   cells at the missing positions.
8. Header suggestion: `name,age` → header; `1,2.5` → not header; `1,,3` → header; `+1e5,-2` →
   not header (numeric grammar per spec).
9. Empty file → open succeeds, 0×0 dimensions.
10. Open of a nonexistent path and an unreadable path yield the two distinct documented error
    codes (I/O error code exists and is distinct as well).
11. All of the above via the public C ABI (exported symbols, C calling convention), not
    internal Zig APIs; no allocation on the cell-access path (verified with a counting/failing
    allocator in tests).

macOS (swift-testing, frozen; real linked core):
12. Opening a small fixture through LessSheetKit yields the expected header + first-rows
    snapshot (cell-exact).
13. Header toggle: for an all-numeric-row-1 fixture the suggestion is "no header"; forcing the
    toggle ON re-derives columns from row 1 immediately (view-model state, no reopen).
14. Generic column names follow A…Z, AA, AB order for a headerless fixture.
15. Kit maps the three ABI error codes to distinct Swift errors; empty-file fixture produces an
    empty, non-error table state.

End-to-end (reviewer measures on the assembled app; not part of the frozen gate):
16. `open -a LessSheet <generated 1 GB CSV>` → window shows first rows;
    `first_rows_visible_ms < 500` (median of 3 cold launches, release).
17. Core open+first-window < 50 ms on the same fixture (release micro-benchmark or marker).
18. Peak RSS < 100 MB for criterion 16's runs; `.app` bundle size in single-digit MB.
19. File › Open… on a fixture renders it; CLI arg path renders it; a missing path shows the
    in-window error panel with the path in the message.

## Open Questions
(none — all resolved in the interview of 2026-07-05)
