# ARCH — reader-interface (pluggable Source + Reader; format-agnostic core)

**Feature:** a focused backend reorg that puts a **Reader** (format/parser) interface + a **Source** (byte
provider) seam between the format-agnostic core (window / index / nav / search / filter / the C ABI) and
the CSV-specific parsing that is currently called directly everywhere. CSV becomes the first Reader; csv.gz
becomes a Source; Parquet becomes a second Reader — with no duplication and clean separation. **Pure
internal refactor: NO `api/` change, NO behavior change, no perf regression** — all frozen tests stay green.

**Read first:** the prior reorg (commit `4a392ad`, `root.zig` → modules) for the house style; `backend/src/`
(`lexer.zig`, `window.zig`, `index.zig`, `nav.zig`, `search.zig`, `filter.zig`, `sniff.zig`, `base.zig`,
`root.zig`, `encoding.zig`); the workspace `CLAUDE.md` (Zig 0.16 docs-first; the O(head)/O(viewport)/frontier
guarantees). `[[formats-roadmap]]`.

## Problem (from the survey)
CSV parsing is pervasively coupled: `lexer.lexInto(content, off, sep, quote, column_count, cap, limit,
encoding, …)` and `lexer.recordBounds(content, off, sep, quote, limit, encoding)` are called DIRECTLY from
`window` (materialize + cellCopy), `index` (checkpoints/frontier), `nav` (skip/in-block re-lex),
`filter` (match scan), `search`, and `sniff`. Every one assumes **rows at byte offsets in one contiguous
stream**. Parquet has no byte-offset rows (columnar: row groups + column chunks + typed values), so it
cannot satisfy that shape — and bolting it on would duplicate/tangle the whole cell-production path. csv.gz
is orthogonal (a gzip-inflate byte source feeding the same CSV parser).

## Goal
The core operates on two small internal interfaces; CSV is one Reader impl behind them; the format-specific
code lives in one place per format. csv.gz (Source) + Parquet (Reader) then plug in without touching the
core. Byte-for-byte the same behavior + perf for CSV today.

## Design direction (the two seams; implementer works out the exact Zig shape)
- **Source** — the byte provider the byte-oriented Readers consume. Today: the read-only `mmap` slice
  (`doc.content` + `data_start`). Add a Source seam so a Reader gets bytes via it: an mmap Source (identity,
  zero-copy — unchanged perf) and, later, a gzip Source (inflate + inflate-checkpoints so a behind-frontier
  seek resumes decompression from the nearest checkpoint, O(checkpoint) not O(file)). A columnar Reader
  (Parquet) may bypass the byte-Source and read the file structure itself.
- **Reader** — the format→rows/cells parser the core calls INSTEAD of `lexer` directly. Minimal operations
  the survey shows the core needs:
  1. `boundsAfter(pos) -> pos'` — the next row's position (CSV: `recordBounds` over bytes; Parquet:
     advance within/across row groups). Used by index/nav/window skip loops.
  2. `materialize(pos, want, cap, out) -> RowResult` — decode a row's cells into the caller buffer, capped/
     bounded (CSV: `lexInto`; Parquet: reconstruct the row's column values → text). Used by window/nav/filter.
  3. `cell(pos, col, buf, cap) -> CopyResult` — decode ONE cell (the `ls_cell_copy`/cellCopy primitive).
  4. `checkpoint`/position support — the frontier stores an OPAQUE **row position** (the crux): today a
     `usize` byte offset; generalize to an opaque value the Reader interprets (byte offset for CSV; a
     (row-group, index) encoding for Parquet). The core's checkpoints/window/nav hold positions opaquely and
     never assume "byte offset" — they ask the Reader to advance/materialize.
  5. `open`/sniff — detect + set up (CSV: `sniff` sep/quote/encoding; Parquet: read the footer/schema).
- **Format-agnostic core** keeps: the C ABI (`root.zig`), the `Doc` window/frontier/checkpoint state,
  the display-cap + borrow rules, search/filter/nav SEMANTICS + the huge-row per-row/aggregate bounds — all
  expressed against the Reader interface, not the CSV lexer.
- **Zero-cost:** the seam must not regress the CSV hot path (window/index/nav re-lex). Prefer Zig comptime/
  tagged-union dispatch (or a thin vtable) — measure the window/landing probes unchanged. `lexer.zig` +
  `encoding.zig` + `sniff.zig` become the CSV Reader's internals (moved, not rewritten).

## Constraints
- **NO `api/` change; NO behavior change.** All 124 backend + all macOS + root tests stay green, byte-for-
  byte the same cells/dims/counts/status. This is a refactor, not a feature — its correctness proof is the
  existing frozen suite staying green.
- **No perf regression:** cold-start (<500 ms), landing (<100 ms), window materialize, memory (O(head)/
  O(checkpoints)) unchanged. Verify with the existing probes + a spot re-measure on big2g/wide/sparse.
- **CSV is the only Reader in this slice.** csv.gz (Source) + Parquet (Reader) are FOLLOW-ONS that plug into
  the seams — not built here (this slice just makes them possible + clean).

## Acceptance criteria (testable)
1. `window`/`index`/`nav`/`search`/`filter` no longer import/call `lexer` directly — they go through the
   Reader interface; CSV parsing (lexer/encoding/sniff) lives behind the CSV Reader.
2. The row **position** the frontier/checkpoints/window/nav store is opaque to the core (the Reader defines
   it); nothing in the core assumes "byte offset".
3. A Source seam exists; the mmap Source is the CSV Reader's byte provider (zero-copy, unchanged).
4. **All existing tests green, no behavior change, no perf regression** (re-measure the window/landing/cold-
   start probes + big2g/wide/sparse spot checks vs pre-reorg).
5. The interfaces are documented + demonstrably ready — validated against ALL THREE format shapes on paper:
   a short design note shows how (a) the **gzip Source** (text-stream), (b) the **Parquet Reader**
   (columnar-binary; row-group/index position), and (c) a **ZIP-of-XML format (ODS/XLSX)** — a ZIP-entry
   stream-inflate Source + an XML Reader whose opaque position carries an offset **+ XML parser state** —
   ALL slot in with NO core change. If any of the three would require a core/interface change, the seam
   isn't right yet — Parquet (most different) and ODS (container + stateful XML position) are the acid tests
   that keep the abstraction from needing a re-reorg per format. This forces the Source to be a GENERAL byte
   provider (mmap / gzip stream / ZIP entry) and the row position to be TRULY opaque (incl. parser state),
   not a byte offset (reinforces AC2).
6. Gates green (backend + macOS + root).

## Contract surface
NONE frozen changes: `api/lesssheet.h`, `backend/contracts/api.zig`, and all frozen tests are UNCHANGED (the
refactor must keep them green). Internal-only: new `backend/src/reader.zig` (+ `source.zig`) interfaces + a
`csv_reader.zig` (the CSV Reader wrapping `lexer`/`encoding`/`sniff`), and edits to `window`/`index`/`nav`/
`search`/`filter`/`root` to route through them. Implementer + reviewer (no planner freeze — no contract change).

## Sequencing
Runs AFTER select-copy is committed (both touch `window.zig`/`cellCopy`; avoid the conflict). Then: this
reorg → csv.gz (Source plugin) + the select-copy streaming copy accessor (a cursor over the Reader) + Parquet
(its own architect→build, a Reader plugin).

## Open questions
None blocking — the Reader op set + the opaque-position are the design; the exact Zig dispatch shape
(comptime vs vtable) is the implementer's call under the zero-cost constraint.
