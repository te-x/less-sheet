# ARCH — csv-gz (transparent, checkpointed `.csv.gz`)

**Feature:** open an RFC 1952 gzip-compressed CSV through the same document, Reader, window, search,
filter, navigation, and copy behavior as a plain CSV, while keeping launch-to-first-rows below 500 ms and
never retaining or inflating the whole logical file. Decisions in this document were made interactively
with the author on 2026-07-11.

This is a delta on commit `af83db9`'s Reader/Source reorganization. That reorganization established the
right ownership boundary—gzip is a byte Source feeding the CSV Reader—but its concrete `len`/`slice`
contract assumes a known, fully contiguous byte span. `csv_reader.zig` currently asks for
`slice(0, len())` on every operation, and unbounded search/filter/navigation materialize a complete row
before matching. Neither behavior can support an unknown-length, bounded-memory gzip stream. During the
architecture interview the author explicitly approved repairing those internal seams. The C ABI remains
frozen; the correction is entirely behind it.

## Problem and scope

The product promise is size-flat first paint: a useful 5 KiB CSV and a useful 500 GB CSV must both expose
their first rows after the same bounded amount of work. Gzip makes that harder in three ways:

1. Compressed file offsets and decompressed CSV offsets are different coordinate systems, and the final
   decompressed length is unknowable without reaching the end. Gzip's ISIZE is only a per-member value
   modulo 2³².
2. DEFLATE is sequential. Serving an old decompressed range without retaining the entire prefix requires
   restartable inflater checkpoints.
3. A tiny compressed prefix can expand into a huge logical prefix. Bounding only compressed input does
   not bound CPU or memory; bounding only output does not preserve the existing file-I/O bound.

This feature includes:

- gzip detection by the physical file's first two magic bytes, `1f 8b`, independent of filename;
- RFC 1952 method-8 gzip, including optional header fields, concatenated members, and BGZF-style member
  streams;
- a bounded streaming gzip Source with logical-range caching, inflater checkpoints, and exact lifecycle
  ownership;
- incremental CSV lexing and matching over Source chunks, including records larger than memory budgets;
- separate logical-byte and physical-file-byte accounting for limits, estimates, and progress;
- best-effort recovery that exposes every safely decoded prefix instead of rejecting useful content; and
- byte-identical behavior for every existing plain-CSV operation and C-ABI result.

### Explicit non-goals

- No change of any kind to `api/lesssheet.h`; no new status, option, flag, progress field, or frontend UI.
- No extension-based format selection. A gzip stream named `.csv` is inflated; a plain CSV named
  `.csv.gz` remains a plain CSV because it lacks gzip magic.
- No TAR interpretation. A `.tar.gz` is not unpacked into entries; its decompressed TAR bytes are merely
  offered to the CSV Reader like any other non-CSV byte content.
- No raw-DEFLATE or zlib-container support, and no gzip compression method other than DEFLATE (method 8).
- No gzip-wrapped Parquet. Parquet remains a future Reader; this slice selects the CSV Reader after the
  gzip Source.
- No whole-file validation before open returns, no trust in ISIZE as a length, and no tail read solely to
  obtain ISIZE.
- No persistent sidecar or cross-open index reuse. Checkpoint storage is private to one live document and
  disappears with it.
- No attempt to resynchronize after structural corruption loses a member boundary. Searching arbitrary
  compressed bytes for another magic sequence could accept a false positive.
- No source modification, lock, rewrite, or full decompressed copy.

## Exact byte model

Three byte measures must remain distinct:

- **Physical file bytes** are bytes in the mapped file on disk, including gzip headers, compressed
  DEFLATE payloads, footers, and member boundaries. `ls_index_poll.bytes_total` remains the physical
  `stat` size, and progress/row estimation use this axis.
- **Inflated source bytes** are the concatenation of member payloads after DEFLATE, before CSV encoding
  conversion and before stripping the one allowed leading BOM. Open expansion and synchronous row-scan
  limits use this axis. This is the user's “amount of characters/data” axis, expressed as bytes so UTF-8,
  UTF-16, Latin-1, and Windows-1252 retain the existing byte-oriented contracts.
- **Served UTF-8 bytes** are CSV cell output after quote removal and encoding conversion. Existing
  `LS_CELL_MAX_BYTES` and caller-provided `ls_cell_copy` buffer limits continue to bound this axis.

CSV row positions remain opaque to the format-agnostic core. For CSV they carry at least a 64-bit logical
inflated offset and the physical compressed high-water mark needed to produce that position. A future
format may interpret the opaque payload differently. A synthetic limit position may omit the physical
mark; positions returned after actual reading contain both. Core code may compare positions for equality,
store them, and pass them back to Reader operations, but may not inspect or calculate either coordinate.

Only a BOM at inflated offset zero of the complete concatenated stream is stripped. A BOM at the start of
a later member is ordinary CSV data. Likewise, a repeated CSV header in a later member is a data record,
and a member boundary without a newline concatenates bytes within the current field or record.

## Inputs, outputs, and error cases

### Inputs and format recognition

The input remains the existing `ls_open` path plus optional `ls_open_options`. Option validation still
finishes before file access. After opening and statting a regular file, `root.zig` examines exactly the
first two bytes when present:

- `1f 8b` selects the gzip Source and the CSV Reader;
- every other prefix, including a zero- or one-byte file, follows the existing mmap CSV path.

A supported gzip member has RFC 1952 compression method 8 and may use FTEXT, FEXTRA, FNAME, FCOMMENT, and
FHCRC. Member payloads are concatenated in order. After one member footer, another valid gzip header starts
the next member. Bytes after a completed member that do not begin a valid next member are trailing gzip
garbage: they are not appended as raw CSV bytes and terminate the usable gzip stream.

### Successful output

A successful gzip open returns the same opaque `ls_doc` and the same observable surface as the equivalent
plain decompressed CSV: effective dialect/encoding, header and column count, row windows, row-count
knowledge, source-row mappings, jump/search/filter state, full-cell copy results, truncation flags, and
oversized-row flags. Gzip metadata such as FNAME never changes the document title or CSV header.

For incomplete indexing, the row-count estimate is derived without extra I/O from physical compressed
file size divided by the observed mean physical compressed bytes per indexed row. It is clamped to at
least the discovered row count and becomes exact only at terminal EOF. ISIZE is checked for integrity but
never supplies document length or the estimate.

### Recovery and failure rules

Gzip damage is a Source condition, not malformed-CSV syntax. CSV remains deliberately permissive: ragged
rows, an unterminated final row, an unclosed quote at terminal EOF, invalid UTF-8 pass-through bytes, and a
surprising header are viewable data under the existing rules.

The gzip Source has clean EOF, damaged EOF, and budget-stop outcomes. Both EOF outcomes present a stable
logical end to the CSV Reader. Budget-stop means more data may exist and must never be mistaken for EOF.

- A valid gzip whose complete concatenated payload is empty returns `LS_OK` with an empty document.
- If no payload byte and no integrity-valid empty member can be reached within the dual open budget,
  `ls_open` returns `LS_ERROR_IO`. This covers invalid method/header/DEFLATE data, truncation before useful
  output, and a valid or invalid optional filename/comment that consumes the whole physical head budget.
- Once at least one payload byte has been produced, damage never discards that prefix. Open succeeds (or
  an already-open document remains usable), and the bytes produced before the terminal damage are parsed
  exactly as a CSV ending at that point.
- If a structurally parsed header has a bad FHCRC, or a member reaches its footer with a bad CRC32 or
  ISIZE, its decoded bytes are kept. Because the payload/footer boundary is still known, a following
  valid member is decoded and concatenated.
- If header/DEFLATE truncation or structural corruption loses the member boundary, decoding stops at the
  emitted prefix. The Source does not scan for a later magic sequence.
- Non-gzip trailing bytes after a completed member are ignored and mark terminal damaged/trailing EOF.
- Failure to create or extend private checkpoint storage does not fail an otherwise useful document. The
  Source continues in memory-only mode until its resident ceiling would be exceeded, then stops at the
  last prefix for which bounded backward access remains guaranteed.
- Allocation or mapping failure before a document with useful content can be constructed remains
  `LS_ERROR_IO`, as today.

A damaged or resource-limited prefix is a complete document for that handle: row count is exact for the
rows exposed, index/search/filter scans can reach their normal terminal states, and index progress reports
`bytes_scanned == bytes_total` with `complete == true`. This terminal normalization prevents a permanent
“estimating” or apparently stalled UI even when unread physical tail bytes are unusable.

## Functional requirements

### 1. Bounded open and small-file behavior

`ls_open` may map the physical file address range, as the current mmap path does, but page faults and
inflation during open obey two simultaneous hard ceilings:

- at most `LS_OPEN_HEAD_MAX_BYTES` (4 MiB) of physical compressed file input is consumed; and
- at most `LS_OPEN_HEAD_MAX_BYTES` (4 MiB) of inflated source output is produced.

Magic bytes, gzip headers, optional fields, DEFLATE input, footers, and the first member transition all
count against the physical ceiling. BOM bytes count against the inflated ceiling. Open stops when either
ceiling is reached; it never compensates for one axis by exceeding the other.

Encoding detection, dialect sniffing, record-1 shape/header logic, and the initial row frontier operate on
the bounded inflated head. Existing samples and tie-breaks are reused: encoding resolution sees up to its
current 256 KiB logical sample; sniffing sees its current bounded logical sample; cell output remains
display-capped. If at least `LS_OPEN_READY_MIN_ROWS` rows exist and fit inside both ceilings, they are
ready when open returns.

The existing “small file is exact at open” behavior applies when the entire gzip stream, including all
member footers, reaches clean or recoverable terminal EOF within both limits. Compressed size alone does
not trigger full indexing: a 1 MiB gzip expanding to hundreds of MiB returns after 4 MiB of inflated
output and continues in the background. A normal 5 KiB gzip whose complete payload fits both limits is
still exact immediately.

No ISIZE or other tail metadata is read speculatively. After the bounded head is committed, AUTO mode
starts the existing worker and MANUAL mode remains idle until existing jump/search/filter work requests
advance it.

### 2. Source contract repair

`source.zig` changes from “known total length plus one contiguous slice” to a bounded logical-byte
provider:

- `mmap` remains a zero-copy variant with a known end and direct spans.
- `gzip_inflate` owns mutable inflater/cache/checkpoint state behind a pointer, while the `Source` union
  remains cheap to copy through Reader calls.
- A Source cursor starts at an opaque logical position and yields immutable contiguous spans. Gzip spans
  are no larger than 256 KiB and supply up to four bytes of cross-span lookahead for encoding units; the
  mmap specialization may expose the caller's whole direct span. The cursor reports whether it stopped at
  a caller limit, clean EOF, damaged EOF, or unavailable resources.
- A cursor request carries independent logical-output and optional physical-input ceilings. Window/copy
  requests use the logical row limit; open requests use both limits; unbounded worker scans use neither.
- End knowledge is explicit. “The currently inflated prefix ends here” is not EOF while the gzip decoder
  can still advance.
- Chunks are leased/pinned for the duration of a Reader operation, so concurrent eviction cannot
  invalidate bytes being parsed. Inflation and disk reads occur outside the short cache-metadata lock.
- Source destruction releases cursor sessions and cache blocks, closes the already-unlinked checkpoint
  store, destroys its synchronization, and runs before the physical mapping is unmapped.

The mmap specialization must retain today's direct-slice inner loop. Generic Source dispatch occurs at a
chunk boundary, never once per byte on the plain-CSV hot path.

### 3. Incremental CSV parsing

`lexer.zig` becomes one resumable CSV state machine parameterized by a Source cursor. Its state covers
field position, quoted/unquoted mode, doubled-quote lookahead, CRLF handling, requested column count,
encoding-unit carry, output cap, and logical limit. The same state machine drives record bounds,
materialization, one-cell copy, sniff field counting, and streaming matching; separate implementations
must not drift on row boundaries.

Chunk boundaries are semantically invisible, including when they split:

- a UTF-8 sequence, UTF-16 code unit or surrogate pair;
- an opening, closing, or doubled quote;
- CR from LF;
- a separator or record terminator from surrounding bytes;
- a text-search match; or
- any sign, digit, decimal point, exponent, or surrounding whitespace in a numeric predicate.

Bounded window and copy operations stop at the existing 1 MiB inflated-source row limit and preserve
their current truncation/oversized semantics. Unbounded background record scans stream through arbitrarily
large rows without retaining them. Materialization allocates only the cell bytes the caller contract
allows; no operation obtains the whole gzip payload as one slice.

### 4. Streaming search/filter/navigation matching

The Reader gains an internal streaming row-match operation returning the next opaque position plus the
same lowest matching column/result that `matcher.matchRecord` returns today. It accepts one predicate or
the existing composed filter-plus-find pair, so a row is decompressed and lexed once. The operation still
scans to the record boundary after an early match so the frontier remains exact.

`matcher.zig` supplies bounded per-cell states with byte-identical semantics:

- TEXT uses a precomputed failure table and carries match state across chunks. Smart ASCII case folding,
  byte-exact non-ASCII behavior, per-cell boundaries, scope masks, empty queries, and lowest-column wins
  are unchanged. Failure-table memory is O(query) and is allocated only by calls already permitted to
  allocate.
- EQ/NE compares the decoded cell stream with the query while tracking length; missing ragged columns are
  the same padded empty cells as today.
- LT/GT/LE/GE uses a streaming form of the existing exact decimal grammar. It tracks validity, sign,
  integer/fraction digit counts, first/last significant digits, saturated exponent, magnitude, and the
  first significant-digit difference from the query. It never converts through floating point and never
  stores the cell's digit string.

The unbounded `materialize(..., cap = null)` path is removed from search scan, filter scan, search
navigation, and match-position counting. `search.zig`, `filter.zig`, and the matching portions of
`nav.zig` call the Reader match operation instead. Bounded filtered-window matching may retain its current
materialized-prefix path because the 1 MiB row ceiling already controls it.

### 5. Logical and physical accounting

The Reader exposes two internal position measurements:

- logical inflated bytes for row extents, `LS_WINDOW_ROW_SCAN_MAX_BYTES`, oversized-row detection, and
  CSV parsing; and
- physical compressed file bytes needed to produce a position for index/search/filter progress and the
  row-count estimate.

For mmap CSV the measurements are identical apart from the leading BOM base. For gzip they differ. A
position returned by actual cursor work records both, so accessors and polls never inflate merely to
calculate progress. Physical progress is monotone and clamped to the file size. Decoder read-ahead may
make it a conservative high-water mark for a row boundary, which is acceptable; terminal progress is
exactly the physical total.

`ls_index_poll.bytes_total` remains physical file size. Search and filter progress use the same physical
axis. Before EOF, base row count uses the physical span after data row zero and the observed row density;
it does no tail read and does not use the inflated cache length. Exactness changes only when the presented
logical stream reaches terminal EOF.

### 6. Inflater checkpoints and random access

Zig 0.16's authoritative standard library provides streaming gzip through
`std.compress.flate.Decompress.init(input, .gzip, buffer)`. The gzip Source uses that implementation and
adds the state the standard API does not export: checkpoint persistence, per-member integrity hashing,
member chaining, and bounded logical-range caching. It does not add zlib or another compression
dependency.

A durable checkpoint is written at least every 32 MiB of inflated source output. A member boundary may
replace the next scheduled checkpoint when that still keeps the maximum gap at 32 MiB; member boundaries
must not increase checkpoint cadence or create duplicate zero-progress checkpoints. A checkpoint contains
everything needed to resume without byte zero: logical and physical
positions, bit alignment, DEFLATE block/pending-symbol state, Huffman decoder state, the required history
window, member CRC/count state, and input/output reader state. Pointer fields are repaired on restore; the
snapshot is process-local and tied to pinned Zig 0.16, never a portable file format.

The implementation must use a compile-proven snapshot adapter around the installed Zig 0.16 type. A
restored decoder must be byte-identical to uninterrupted decoding for stored, fixed-Huffman, and
dynamic-Huffman blocks and for checkpoints inside pending literal/match states.

Any request at or beyond the first durable checkpoint resumes from the greatest checkpoint not after its
logical start. No replay spans more than 32 MiB of inflated output before reaching the requested start.
Only positions in the initial interval may necessarily begin at logical byte zero, and that replay is
still bounded by 32 MiB rather than file size. Sequential forward work reuses its live inflater and never
restarts per row.

### 7. Cache and checkpoint storage

One gzip document has a hard 16 MiB resident-memory ceiling for gzip-specific state, excluding the
existing materialized window, caller-owned copy buffer, and query text. The intended partition is:

- up to 8 MiB of immutable inflated-byte cache, including the open head;
- up to 4 MiB of hot checkpoint snapshots; and
- up to 4 MiB for fixed cursor sessions, inflater/history scratch, synchronization, and metadata.

Additional concurrent poll/control callers may wait for a fixed session; they may not force unbounded
session allocation. The core worker, serialized window lane, and one poll/control operation can progress
independently without sharing a mutable decoder.

Older checkpoint snapshots spill to a mode-0600 temporary file opened in the platform temporary
directory and unlinked immediately. It has no application-imposed size cap and grows only as the frontier
naturally advances. Fixed-interval lookup must not require an O(checkpoints) in-memory directory; record
ordinal/file offset is derivable or itself stored in the bounded index. Checkpoint storage is at most
0.25% of inflated bytes plus fixed per-document overhead at the 32 MiB interval.

The temporary file stores restart state, not a complete decompressed copy. It is never named beside the
source, never survives document/process lifetime, and is never reused. If creation or writing fails, all
already durable checkpoints remain valid. Memory-only checkpointing continues within the same 16 MiB
ceiling; before another required checkpoint would exceed it, the Source turns the last safely replayable
prefix into damaged EOF.

### 8. Integrity, members, and salvage

The Source validates optional header CRC when present and computes each member's CRC32 and output count as
bytes are emitted. At the footer it compares CRC32 and ISIZE modulo 2³². Validation happens only when the
normal forward/read request reaches those bytes; it never causes pre-open work.

A footer mismatch is recoverable because the next member boundary is known. A structural decoder error is
terminal unless it occurs before any useful/verified-empty content, in which case open fails. Once damaged
EOF is chosen, the logical end is immutable: later calls cannot retry past it and produce a different row
set. This determinism is required for row indexes, filter/search counts, and borrowed window results.

### 9. Concurrency and lifecycle

The existing C-ABI lane rules remain unchanged. Gzip Source state adds its own short metadata lock and
immutable cache leases; it must not hold the document frontier mutex or Source metadata lock while
inflating 32 MiB, reading checkpoint storage, or parsing a row. The background worker cannot evict a chunk
leased by window/copy work, and window/copy work cannot mutate the worker's live forward decoder.

Gzip Source cursors check document shutdown at least once per 256 KiB output chunk. `ls_close` first signals
shutdown, joins the existing worker, drains/invalidates cursor sessions, destroys gzip state and its
temporary file, and finally unmaps the physical file. Search/jump/filter cancellation keeps its existing
frontier semantics; completed decompression/checkpoints remain reusable even when a higher-level scan
commit is cancelled.

Calls documented as zero-heap-allocation remain so. Required cursor/history buffers are preallocated at
open or live in bounded fixed sessions; checkpoint reads during `ls_cell_copy` do not allocate. Background
checkpoint persistence is an allowed internal scan allocation/write and never invalidates borrowed cells.

## Non-functional requirements

- **Cold start:** app launch through first data-bearing frame remains below 500 ms on the supported Apple
  Silicon probe. Core open work is bounded by the smaller stopping point of 4 MiB physical input and
  4 MiB inflated output, independent of physical or logical file length.
- **Size flatness:** open performs no tail read, whole-member validation, whole-file inflation, or
  checkpoint prebuild. A useful 500 GB apparent-size input and a normal 5 KiB input differ only in bounded
  head content, not asymptotic work.
- **Backward landing:** after a region has crossed the row frontier and its hot inflated chunks have been
  evicted, a landing restores the nearest durable inflate checkpoint and replays at most 32 MiB. The
  existing release landing probe remains below 100 ms on representative gzip fixtures.
- **Memory:** gzip-specific resident state is at most 16 MiB per open document. Overall steady-state RSS
  remains below the existing 120 MiB target on a 10 GB-class document after open/scan/backward-landing
  exercise. Memory is never proportional to inflated file size, row size, or match density.
- **Disk:** ephemeral checkpoint storage is O(inflated bytes / 32 MiB), at most 0.25% of inflated bytes
  plus fixed overhead. No full decompressed cache or persistent artifact is permitted.
- **Responsiveness:** inflation runs off the UI thread except bounded head/window/copy replay. Cache locks
  cover metadata only. Operations that advance beyond the row frontier retain existing pollable progress;
  behind-frontier replay meets the synchronous landing budget.
- **Plain CSV:** the mmap fast path remains zero-copy. Across at least five identical release runs, median
  window/search/filter throughput is no more than 5% slower than the immediate pre-csv-gz baseline;
  cold-open and landing remain within their existing limits, and steady RSS grows by no more than 5 MiB.
- **Dependencies and size:** Zig standard library only; distributed binary remains single-digit MB.
- **Read-only and private:** the physical source is never modified or locked and is never copied
  wholesale. The checkpoint store contains only bounded DEFLATE history dictionaries and decoder state,
  never the complete decompressed stream. Temporary checkpoint data is private and automatically
  unlinked.

## Component decomposition and data flow

### Changed components

- **`backend/src/source.zig`** — generalizes Source end/range semantics; retains the mmap specialization;
  adds `gzip_inflate`, bounded cursors, immutable chunk cache, forward and replay inflater sessions,
  member/integrity state, dual-coordinate reporting, durable checkpoints, temporary storage, shutdown,
  and deinitialization.
- **`backend/src/reader.zig`** — keeps tagged-union dispatch but expands opaque CSV positions to preserve
  logical and physical coordinates; separates logical row-byte accounting from physical progress; adds
  streaming match dispatch and explicit unknown/terminal Source-end behavior.
- **`backend/src/csv_reader.zig`** — changes open-head setup to consume a bounded Source head rather than a
  whole mapping, rebases the Source after the initial BOM, and adapts bounds/materialize/cell/match
  operations to the resumable lexer. CSV dialect and encoding semantics do not change.
- **`backend/src/lexer.zig`** — refactors the existing quote-aware grammar into the shared resumable
  cursor state machine. The mmap instantiation remains a direct contiguous fast path.
- **`backend/src/matcher.zig`** — retains `matchRecord` for bounded materialized callers and adds streaming
  text/equality/decimal states with identical outcomes.
- **`backend/src/root.zig`** — detects magic after open/stat, constructs the selected Source, obtains the
  bounded logical head, builds the unchanged CSV Reader/profile, normalizes useful-prefix errors, and
  destroys gzip state in the correct order. Its copy/cursor exports are outside this feature.
- **`backend/src/base.zig` and `backend/src/index.zig`** — stop treating one byte count as both logical
  extent and physical progress; use the proper Reader measurement for row caps, oversized detection,
  row-count estimation, progress, and mmap page release. The document owns no gzip details beyond Source.
- **`backend/src/search.zig`, `backend/src/filter.zig`, and matching portions of
  `backend/src/nav.zig`** — replace unbounded whole-row materialization with the Reader's streaming match
  operation. Their job state machines, counters, coordinates, scan-slot arbitration, and outputs remain
  unchanged.

Because `base.zig` and `nav.zig` are also in the sibling `stream-copy` implementation area, csv-gz is no
longer a safe parallel build cell. `stream-copy` must land first; csv-gz then applies this delta on top of
its finished cursor behavior. The two features still make no semantic change to one another.

### Reused unchanged components

- **`backend/src/encoding.zig`** remains the source-encoding authority. Cursor lookahead presents complete
  units to its existing decode rules, preserving invalid UTF-8 pass-through and replacement behavior.
- **`backend/src/sniff.zig`** runs unchanged over the bounded inflated head.
- **`backend/src/window.zig`** retains window, borrow, display-cap, filtered-window, and cell-copy behavior;
  it sees only Reader operations and opaque positions.
- **The row/search/filter core models** retain their checkpoint counts, frontier monotonicity, view-relative
  addressing, and scan-slot behavior.
- **`api/lesssheet.h` and every frontend** are byte-identical and behaviorally unchanged for valid content.

### Open data flow

```text
path + existing options
          │
          ▼
 open/stat + read-only physical mmap
          │
          ├── first bytes != 1f 8b ──► mmap Source ───────────────┐
          │                                                       │
          └── first bytes == 1f 8b ──► gzip Source                │
                                        │                         │
                               dual-bounded inflate head          │
                                        │                         │
                                        └─────────────────────────┤
                                                                  ▼
                           encoding resolve → dialect sniff → CSV Reader
                                                                  │
                                      record 1 + bounded head scan│
                                                                  ▼
                                              existing Document / C ABI
```

### Behind-frontier range flow

```text
requested row
    │
    ▼
existing sparse row checkpoint → opaque logical CSV position
    │
    ▼
greatest inflate checkpoint ≤ position
    │        (hot RAM or private unlinked store)
    ▼
restore decoder + history → replay ≤ 32 MiB → bounded chunk cursor
    │
    ▼
incremental CSV lexer / materializer / matcher → unchanged caller result
```

## External and internal interfaces

### External C ABI

`api/lesssheet.h` must remain byte-for-byte identical. In particular:

- `ls_open` still auto-detects internally and returns only existing `ls_status` values;
- `ls_dialect_get` reports the decompressed CSV's dialect/encoding, not gzip metadata;
- `ls_index_poll` retains physical-file byte totals;
- every window, cell, copy, jump, search, filter, source-row, and truncation contract is unchanged; and
- all existing ownership, allocation, and threading rules remain normative.

The only gzip-specific interpretation visible through existing fields is that a salvaged terminal prefix
is the complete document represented by that handle. No caller can distinguish clean from damaged EOF
through this ABI, and no caller is left in a nonterminal state that it cannot resolve.

### Internal Source/Reader contract

The planner may choose exact Zig names, but the frozen internal behavior must provide:

- Source construction from a physical mmap and a selected mmap/gzip kind;
- a known-end/unknown-end query that never mistakes current availability for EOF;
- bounded cursor acquisition by opaque logical position and dual limits;
- logical-byte and physical-file-byte measurements for actual positions;
- Source rebase after the one leading BOM;
- Reader bounds/materialize/cell/match operations over cursors; and
- explicit Source shutdown/deinitialization.

No operation may require a total logical length or a slice beginning at logical byte zero. No core module
may inspect CSV position fields directly.

## Acceptance criteria

1. **Frozen boundary.** `api/lesssheet.h` is byte-identical to the pre-feature file; exported symbols,
   option layouts, statuses, and frontend contracts are unchanged. The root integrity gate passes.

2. **Magic, not name.** A gzip-compressed CSV opens through gzip under `.csv`, `.gz`, or an unrelated
   extension. A plain CSV named `.csv.gz` follows the plain path. Zero- and one-byte files retain existing
   plain-CSV behavior.

3. **Plain/gzip equivalence.** For the same logical CSV, a plain file, a single-member gzip, a
   multi-member gzip split at adversarial byte positions, and a BGZF-style stream produce byte-identical
   dialect reports, headers, dimensions, windows, truncation/oversized flags, row counts, source-row
   mappings, jump landings, search/filter counts and navigation, and `ls_cell_copy` results. The matrix
   includes every supported encoding, BOM/no-BOM, forced and sniffed dialects, quotes/doubled quotes,
   embedded newlines, CR/LF/CRLF, ragged rows, empty cells, and invalid UTF-8 pass-through.

4. **Member transparency.** A member split inside a quote escape, CRLF, UTF-16 unit/surrogate pair, field,
   or record is invisible. Only the first overall BOM is stripped. A later BOM and repeated CSV header are
   ordinary data. Missing newline between members concatenates their bytes. Raw trailing bytes are not
   appended.

5. **Dual open bound.** Test instrumentation proves every gzip open consumes no more than 4 MiB physical
   input and produces no more than 4 MiB inflated output before returning, including gzip header/footer
   work. No trailer/tail page is touched merely for ISIZE. A high-expansion gzip smaller than 4 MiB is not
   fully inflated at open.

6. **Five-kilobyte to 500-gigabyte flatness.** The release first-frame probe is below 500 ms for a normal
   roughly 5 KiB gzip and for a sparse apparent-size 500 GB fixture with the same useful valid head and an
   unread tail; read/fault counters prove the large file does not cause extra open work. A synthetic
   high-expansion Source independently proves the bound against very large logical length.

7. **Small normal gzip determinism.** A gzip whose complete physical and inflated streams both fit the
   4 MiB limits is fully indexed at open, has exact row count, and reports complete progress immediately.
   A small compressed file whose output crosses 4 MiB returns with a usable head and inexact count rather
   than blocking for full inflation.

8. **RFC/member coverage.** Stored, fixed-Huffman, and dynamic-Huffman DEFLATE blocks; every supported
   optional gzip header field; empty members; multiple members; and BGZF-style extra fields decode
   correctly. Raw DEFLATE, zlib, and non-method-8 gzip do not enter a different parser accidentally.

9. **Recovery matrix.** A valid empty gzip opens empty. Invalid gzip with neither payload nor a valid empty
   member returns `LS_ERROR_IO`. Truncation after emitted payload opens the exact emitted prefix. Footer
   CRC/ISIZE/FHCRC mismatch preserves payload and permits a following valid member. Structural corruption
   stops without magic resynchronization. A header consuming the open budget before useful content returns
   `LS_ERROR_IO` within the budget.

10. **Terminal prefix semantics.** Every salvaged or resource-limited prefix has a deterministic immutable
    logical end. Its base/filter/search counts become exact, terminal jobs finish normally, and
    `ls_index_poll` reports `{bytes_total, bytes_total, true}`. Repeated access never exposes additional
    bytes after that terminal decision.

11. **No ISIZE length dependency.** Fixtures with deliberately false/wrapped ISIZE and concatenated
    members demonstrate that pre-EOF row estimates and progress do not use it. Estimates require no reads
    beyond already consumed head/frontier bytes, never fall below discovered rows, and collapse to the
    exact presented count at terminal EOF.

12. **Chunk-boundary correctness.** A test Source forcing one-byte and irregular chunks splits every CSV,
    encoding, text-query, and decimal token boundary. Results match the contiguous mmap reference exactly,
    including lowest matching column and exact 40-digit/exponent numeric comparisons.

13. **No unbounded row materialization.** Static/call-path verification shows search, filter, and
    navigation no longer call unbounded `materialize(..., cap = null)`. A gzip with a very large single
    cell and a match beyond the display/row head is found and navigated correctly while matcher memory is
    O(query + fixed state), not O(cell) or O(file). Window and copy still stop at their existing row/output
    caps and report truncation honestly.

14. **Checkpoint restore correctness.** Snapshot/restore probes cover checkpoints inside stored, fixed,
    dynamic, pending-literal, and pending-match states and across member transitions. Output and integrity
    results equal uninterrupted Zig 0.16 `.gzip` decoding byte-for-byte.

15. **Bounded replay.** After scanning at least four 32 MiB intervals, evicting inflated/hot state, and
    landing backward in each interval, instrumentation records the restored checkpoint and inflated replay
    count. Every target after the first interval starts from a nonzero nearest checkpoint and replays at
    most 32 MiB; no request re-inflates the whole prefix. Returned rows/cells equal the plain reference.

16. **Landing performance.** The existing Apple Silicon release landing probe, repeated across spilled
    gzip checkpoints and representative small/large rows, records less than 100 ms per behind-frontier
    landing. Sequential scrolling through cached/indexed gzip rows preserves the existing frame budget.

17. **Resident and temporary storage bounds.** Allocation/RSS instrumentation holds gzip-specific resident
    state to 16 MiB and overall 10 GB-class steady RSS below 120 MiB after open, forward scan, cache
    eviction, and far backward landing. Checkpoint-file size is at most 0.25% of inflated bytes plus fixed
    overhead; it is mode 0600, already unlinked while open, and absent after close/process exit.

18. **Checkpoint-store failure.** Injected create, write, and disk-full failures retain all already usable
    content, never exceed 16 MiB resident state, and terminate at the last replay-safe prefix with the exact
    completion behavior from criterion 10. Source bytes and neighboring paths remain untouched.

19. **Concurrency and cleanup.** Concurrent AUTO scanning, window changes, and background `ls_cell_copy`
    across spilled checkpoints produce reference-equal data with no deadlock, race, lease invalidation, or
    borrow-rule violation. Close during active inflation observes shutdown at a bounded chunk boundary,
    joins cleanly, closes temporary state, and unmaps once.

20. **Plain-CSV regression guard.** Every existing backend and macOS test remains green. Across at least
    five identical release runs against the immediate pre-csv-gz commit, median plain-mmap
    window/search/filter throughput regresses by no more than 5%, steady RSS grows by no more than 5 MiB,
    and cold-open/landing retain their existing limits. The mmap parser still obtains direct spans rather
    than copying through the gzip cache.

21. **Read-only/source integrity.** Hash and metadata checks before and after open, scan, random access,
    corruption recovery, and close prove the physical source is never modified, locked, renamed, or
    copied wholesale.

22. **Build and distribution.** The implementation uses the pinned Zig 0.16 standard library gzip
    decoder, adds no runtime dependency, keeps the assembled application in the single-digit-MB budget,
    and passes backend, macOS, and root gates.
