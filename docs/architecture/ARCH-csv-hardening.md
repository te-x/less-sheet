# ARCH — csv-hardening

Real-world CSV robustness — the two remaining gaps of brief slice 3 ("Real-world CSV"). Everything
else in the slice (quoting, embedded newlines, CRLF/lone-CR, ragged rows, UTF-8 BOM strip, dialect
sniffing, the header/numeric grammar) already shipped in earlier slices and is unchanged here. This
slice adds exactly two things:

1. **Encodings** — detect and read non-UTF-8 files (UTF-16 LE/BE, legacy 8-bit Latin-1 /
   Windows-1252), transcoding to UTF-8 inside the core so the ABI stays byte-clean.
2. **Huge single rows** — cap the decode so a pathological first record or a giant single cell can
   never make open O(file) or blow memory; display-truncate oversized cells with an indicator.

This is a delta on the existing delimited-text path: the same mmap lexer, the same head-budget open,
the same windowed row access, the same dialect report / re-open flow. It reuses the `ls_open_options`
/ `ls_dialect` "forced-vs-sniffed" pattern (adding a fourth parse dimension, *encoding*) and the
existing `capped`-record machinery (extending it to bound record 1 and to per-cell size).

## Problem & scope

Real exports are not always clean UTF-8. Excel-on-Windows writes UTF-16 (usually with a BOM); older
tools and European datasets emit Latin-1 / Windows-1252. Today the core assumes the file's bytes are
UTF-8 and hands them straight through — a UTF-16 file renders as text interleaved with NUL boxes, an
8-bit file mangles every accented character. Separately, the open path decodes record 1 in full to
fix the column count and header; a pathological first line (hundreds of MB, or one enormous quoted
cell) would make open O(file) and could exhaust memory, violating the cold-start and O(viewport)
budgets.

**In scope**
- **Encoding detection** (default, automatic): UTF-8 (with/without BOM), UTF-16 LE/BE (by BOM, and
  by a NUL-ratio heuristic for the BOM-less case), and an 8-bit fallback.
- **Encoding override** (manual): the user forces one of a fixed set of encodings from the Settings
  window; the forced encoding flows into the open options exactly as a forced dialect does.
- **Internal transcoding** to UTF-8, streaming and windowed — never a full-file read to detect or
  transcode.
- **Effective-encoding report** back to the frontend (like the dialect report) for the Settings UI.
- **A per-cell display cap** with a truncation indicator, and a **bounded record-1 decode** so a
  giant first line still opens as a (degenerate) table.

### Non-goals (this slice)
- No statistical / language charset detection (no `chardet`-class guessing). Detection is limited to
  BOM, a NUL-ratio test, UTF-8 validation, and a single 8-bit default.
- No encodings beyond the fixed set below — no UTF-32, EBCDIC, Shift-JIS, GBK, Big5, KOI8, etc.
  (These are a future slice if ever demanded; the override enum is designed to extend.)
- No re-detection mid-file: the encoding is resolved once at open, from the head, and is constant for
  the document's lifetime (a new choice is a re-open).
- No change to the smart-case rule, the numeric grammar, the header rule, or the sniffer scoring —
  they now simply run on the transcoded UTF-8 head.
- No editing, no re-encoding on save (the core is read-only; the source file is never touched).
- Display truncation is presentation-only; it never alters stored/served bytes for search or the
  source file.

## Inputs / Outputs

**Inputs**
- The existing per-open parse profile (separator / quote / header / index mode) **plus a new
  `encoding` field**: either **Automatic** (detect) or one **forced** encoding from the fixed set:
  `UTF-8`, `UTF-16 LE`, `UTF-16 BE`, `ISO-8859-1 (Latin-1)`, `Windows-1252`. A forced encoding
  bypasses detection (a forced UTF-16 is honored even with no BOM); an unknown encoding value is a
  usage error (`LS_ERROR_INVALID_ARGUMENT`), consistent with the other option fields.
- The file bytes (mmap), read for detection/transcode/sniff only within the existing O(head) budget.

**Outputs**
- Cell / header text across the ABI: **guaranteed-valid UTF-8 for every transcoded encoding**
  (UTF-16 LE/BE, Latin-1, Windows-1252). For a file **detected or forced as UTF-8** the bytes pass
  through unchanged (the existing "assumed UTF-8, consumers replace invalid sequences with U+FFFD at
  display" caveat is retained for that path only — see Text semantics below).
- The **effective-dialect report gains the effective (resolved) encoding and an `encoding_forced`
  flag**, mirroring the existing `separator_forced` / `quote_forced` / `header_forced`. In Automatic
  mode this reports what detection chose; when forced it echoes the forced value. Constant for the
  document's lifetime.
- Cells are **display-truncated to at most `LS_CELL_MAX_BYTES` = 4 KiB** of served UTF-8 output,
  truncated at a UTF-8 code-point boundary (≤ 4 KiB). A **truncation flag** per cell (and per header
  cell) lets the frontend render an indicator.

**Text semantics (updates to the frozen TEXT AND ENCODING / SEARCH sections)**
- The leading-BOM strip generalizes from "UTF-8 BOM" to "the resolved encoding's BOM" (UTF-8
  `EF BB BF`, UTF-16LE `FF FE`, UTF-16BE `FE FF`): the BOM is consumed before parsing and never
  appears in any cell.
- Malformed input in a transcoded encoding maps to U+FFFD: Windows-1252's five undefined bytes
  (`0x81 0x8D 0x8F 0x90 0x9D`) and any ill-formed / lone-surrogate UTF-16 unit. Latin-1 maps all 256
  byte values (never U+FFFD from decoding).
- **Search matches the FULL cell, not the truncated display bytes.** `ls_cell` serves at most 4 KiB,
  but the match-scan streams the entire cell's (transcoded) content. This diverges from the previous
  "matching is exactly the bytes `ls_cell` serves" wording: byte-cap truncation affects display only;
  column-count truncate/pad still applies to both display and matching as before. A consequence: a
  match (and its reported column/position) can lie past the 4 KiB a frontend can display — the
  truncation indicator signals that more exists; frontends clamp any in-cell highlight to the served
  bytes.

**Error cases**
- Unknown `encoding` value → `LS_ERROR_INVALID_ARGUMENT` (no file touched), like other bad options.
- File I/O / not-found / permission unchanged.
- Empty (0-byte) or BOM-only file: opens as the existing empty document; the report's encoding is the
  forced value, or UTF-8 (or the BOM's encoding for a UTF-16 BOM-only file).
- A first record that never terminates within the head budget does **not** error — see requirement 9.

## Functional requirements

**Core — encoding**
1. **Detection pipeline (Automatic), on raw head bytes, before dialect sniffing**, in this order:
   1. **BOM**: `EF BB BF` → UTF-8; `FF FE` → UTF-16LE; `FE FF` → UTF-16BE. The BOM is stripped.
   2. **NUL-ratio heuristic** (BOM-less): if the head sample is dominated by NUL bytes sitting in one
      alternating parity of byte positions, resolve UTF-16 — LE when the NULs fall on odd offsets
      (`48 00 65 00 …`), BE when on even offsets (`00 48 00 65 …`). (Exact threshold is an
      implementation detail with pinned outcomes below.)
   3. **UTF-8 validation** of the head sample → UTF-8 (a multibyte sequence cut by the head boundary
      does not fail detection).
   4. Otherwise **ISO-8859-1 (Latin-1)** — the never-lose-a-byte 8-bit default.
2. **Forced encoding** bypasses the whole pipeline: the head (and every window) is decoded as the
   forced encoding. A forced UTF-16 LE/BE is honored with or without a BOM; a BOM matching the forced
   encoding is still stripped.
3. **Internal transcoding to UTF-8 is streaming and windowed.** Index checkpoints are byte offsets in
   the **source** file; a window transcodes only its source byte range on demand; the background
   index and the search/jump scans read source bytes. Nothing transcodes the whole file, and cell
   memory scales with the window + sparse index, never the file. UTF-8 (detected or forced) transcode
   is a zero-copy pass-through.
4. **Pipeline order at open**: resolve encoding (raw head) → transcode the head → run the *unchanged*
   dialect sniffing, column-count, header, and numeric-grammar logic on the transcoded UTF-8 head.
   Sniffer/candidate bytes (`, ; \t |`, `" '`) and the numeric/whitespace grammar are ASCII, so this
   logic is unaffected by which encoding produced the UTF-8.
5. **O(head) bound is on SOURCE bytes.** `ls_open` consumes at most `LS_OPEN_HEAD_MAX_BYTES` of the
   *file* for detection + transcode + sniff, for every encoding. Transcoded output may be larger
   (Latin-1 high bytes double; UTF-16 ASCII halves) — that is bounded by the head budget times a
   small constant and does not read more file. The determinism pin (a file whose *size* ≤ head budget
   is fully indexed at open) holds, measured in source bytes.
6. **The report carries the effective encoding + `encoding_forced`.** In Automatic mode the effective
   encoding is the resolved one (never "Automatic"); forced echoes the choice.
7. **Changing the encoding is a re-open**, identical in mechanics to changing a dialect parameter: a
   fresh document with the forced encoding in its open options; search state, highlights, and index
   are invalid (new document identity), other forced parameters carry forward.

**Core — huge single rows**
8. **Per-cell display cap `LS_CELL_MAX_BYTES` = 4 KiB.** `ls_cell` and `ls_header_cell` serve at most
   4 KiB of transcoded UTF-8, cut at a UTF-8 code-point boundary ≤ 4 KiB (never a partial code
   point). This bounds per-cell decode/transcode and window memory (window worst case = rows × cols ×
   4 KiB, reached only by pathological data; normal cells are untouched). A **per-cell truncation
   flag** (data and header) reports whether a cell was cut, via a dedicated zero-alloc, total,
   never-fail accessor — `ls_cell` itself (frozen) is not changed.
9. **Bounded record-1 decode.** If record 1 — which fixes the column count, the header decision, and
   the header cells — does not terminate within the head budget (a multi-hundred-MB first line, or a
   giant unterminated quoted cell), the document still opens: the **column count is the number of
   fields decoded within the budget (≥ 1)**, the final in-progress field is display-truncated (and
   its truncation flag set), and the header decision runs on those (capped) record-1 cells. This
   extends the existing `capped`-record mechanism (which today defers a spilling record beyond
   record 1) to make record 1 itself safe.
10. **Search reads the full cell** (requirement in Text semantics above): the match-scan is not
    bounded by the 4 KiB display cap; it streams the full (transcoded) cell content in bounded
    memory. Predicate `=`/`≠` compare the full cell byte-exactly; numeric ordering parses the pinned
    grammar over the cell (numeric tokens are short, so the cap is irrelevant to them).

**App UX (macOS)**
11. **A "Text encoding" control joins the Settings window's Parsing section** (not a sixth
    control-row pill, per the brief). It is a picker: **Automatic**, UTF-8, UTF-16 LE, UTF-16 BE,
    ISO-8859-1 (Latin-1), Windows-1252. In Automatic mode it surfaces the detected encoding (e.g.
    "Automatic — detected: Latin-1") from the report, mirroring how the pills show sniffed dialect
    values.
12. **Selecting an encoding re-opens the document** with that forced encoding (same code path as
    changing a dialect parameter in Settings): forced dialect parameters carry forward, search
    results/highlights clear, the grid re-renders from the new decode.
13. **A truncated cell renders a visible indicator** — a trailing ellipsis plus a subtle marker
    (and/or tooltip) — driven by the per-cell truncation flag. Purely presentational; the source is
    untouched and (via requirement 10) the hidden tail remains searchable.

## Non-functional constraints
- **O(head) open, no full-file work**: detection, transcoding, and sniffing read ≤
  `LS_OPEN_HEAD_MAX_BYTES` source bytes regardless of encoding or of a pathological first row. A
  10 GB Latin-1 or UTF-16 file opens as fast as a 10 KB one.
- **Cold start < 500 ms** on Apple Silicon is unchanged, including for a file whose first record is
  gigantic or whose first cell is enormous (both bounded by requirements 8–9).
- **Memory O(viewport) + sparse index**: per-cell ≤ 4 KiB served; transcoding is streaming per
  window; no buffer scales with file size.
- **Windowed transcode cost** is O(window source bytes) re-lex+transcode from the nearest checkpoint
  — `ls_window_set` stays the synchronous-fast UI-thread path it is today.
- **Read-only**: the source file is never modified, copied, or re-encoded on disk.
- **ABI stability**: additions only (a new option field, new report fields, a new constant, new
  truncation accessors, and clarified TEXT/SEARCH prose). Existing signatures (`ls_open`, `ls_cell`,
  `ls_header_cell`, search) keep their shapes.

## Component decomposition & data flow
- **`api/lesssheet.h` (root planner)** — the contract delta: an `encoding` field in
  `ls_open_options`; `encoding` + `encoding_forced` in `ls_dialect`; an `LS_ENCODING_*` enum
  (Automatic sentinel + the five encodings); an `LS_CELL_MAX_BYTES` constant; per-cell truncation
  accessors for data and header cells; and updated TEXT AND ENCODING / SEARCH wording (BOM
  generalization, transcode guarantee for non-UTF-8, search-over-full-cell divergence, record-1
  bound).
- **`backend/` (Zig core)** — a **decode/transcode stage** in front of the existing lexer: encoding
  resolution from the raw head, then a streaming source→UTF-8 transcoder feeding the lexer per
  window/scan (zero-copy for UTF-8). The lexer, sniffer, header/numeric logic, index, window buffer,
  jump/search scans are reused, now operating on transcoded UTF-8 and honoring the 4 KiB cell cap and
  the bounded record-1 decode. Truncation flags are recorded alongside cell refs.
- **`apps/macos/` (Swift)** — `Contracts`: an `EncodingOverride` (Automatic / one of five) added to
  the per-open override, and effective-encoding + `encodingForced` added to the report; the cell
  model surfaces the truncation flag. App: the Settings "Text encoding" picker (bound to the same
  re-open path as the dialect controls) and the truncation indicator in the grid renderer.
- **Data flow (open)**: raw head bytes → encoding resolution → streaming transcode(head) → sniff +
  column count + header (unchanged) → report (dialect + encoding). **Data flow (scroll)**:
  `ls_window_set(range)` → transcode(source range for those rows) → lex → capped cells + truncation
  flags → `ls_cell` / `ls_cell_truncated`. **Data flow (search)**: match-scan streams source →
  transcode → full-cell match (uncapped).

## External interfaces
- The C ABI in `api/lesssheet.h` is the only cross-component surface; the additions above are frozen
  by the root planner pass. Both frontends consume the same header. The Swift `Contracts` types
  mirror the new fields.

## Acceptance criteria (each testable)

**Encoding — detection & transcoding**
1. A UTF-16LE file **with BOM** (`FF FE …`) of accented text (e.g. `José,42`) opens with cells
   equal to the correct UTF-8 bytes; the BOM never appears in a cell; the report's encoding is
   UTF-16 LE, `encoding_forced` false.
2. Same for a UTF-16BE file with BOM (`FE FF …`) → UTF-16 BE.
3. A **BOM-less** UTF-16LE file of ASCII-range text (bytes `48 00 65 00 …`) detects as UTF-16 LE via
   the NUL-ratio heuristic and reads correctly (no NUL boxes); the BE-shaped counterpart detects as
   UTF-16 BE.
4. A Latin-1 file (`caf\xE9`) opened in **Automatic** detects as ISO-8859-1 and yields `café`
   (UTF-8 `63 61 66 C3 A9`); report encoding ISO-8859-1.
5. A file whose head is pure ASCII but which is actually Latin-1 with an accented byte only *after*
   the head detects as UTF-8 (documented limitation of head-only detection); **forcing ISO-8859-1**
   via the options re-reads it correctly. (Demonstrates the override recovery path.)
6. A Windows-1252 file with a smart-quote byte (`0x93`/`0x94`) forced to Windows-1252 yields the
   curly quotes (`“ ”`); its five undefined bytes yield U+FFFD; the same bytes under forced
   ISO-8859-1 yield the C1 code points instead.
7. A valid UTF-8 file (with or without BOM) opens byte-identically to today (pass-through); an
   invalid UTF-8 byte in a UTF-8-detected file is served **unchanged** (not U+FFFD'd by the core).
8. `encoding` outside the defined enum → `LS_ERROR_INVALID_ARGUMENT`, file untouched.
9. Detection + transcode + sniff read **≤ `LS_OPEN_HEAD_MAX_BYTES` source bytes** for a large file of
   each encoding (assert bytes faulted/read from the file at open are within the budget); a large
   Latin-1 and a large UTF-16 file both open within the cold-start budget.
10. A forced UTF-16 LE/BE **without** a BOM decodes correctly; a leading BOM matching a forced
    encoding is stripped.
11. An empty file and a BOM-only file open as the empty document; report encoding = forced value, or
    UTF-8 (or the BOM's encoding for a UTF-16 BOM-only file).
12. Sniffing/header/numeric outcomes on a transcoded non-UTF-8 file match those on the byte-identical
    UTF-8 transcription (encoding is orthogonal to dialect on the ASCII structural bytes).

**Huge single rows**
13. A cell longer than 4 KiB is served truncated to ≤ 4 KiB at a UTF-8 code-point boundary (never a
    split code point), and its truncation accessor returns true; a ≤ 4 KiB cell returns false and is
    served whole.
14. A file whose **record 1 is a single unterminated ~500 MB line** (or an unclosed quoted cell)
    opens successfully: column count = fields decoded within the head budget (≥ 1), the last field is
    truncated+flagged, and **open stays within the cold-start budget** (asserts no O(file) read: file
    bytes touched ≤ head budget).
15. Text search finds a query occurring **only past the 4 KiB display cap** of a large cell (proves
    search reads the full cell); the reported match column is correct and its position may exceed the
    served cell length.
16. Predicate `=` on a value longer than 4 KiB matches a cell whose full content equals it (full-cell
    comparison), even though the served/display bytes are truncated.
17. A window full of oversized cells has bounded materialized memory (≈ rows × cols × 4 KiB), and
    `ls_window_set` over such a range stays on the synchronous-fast path (no scan, no full-file read).

**App UX (macOS)**
18. The Settings window shows a "Text encoding" picker with Automatic + the five encodings, and in
    Automatic mode displays the detected encoding from the report; it is **not** present as a
    control-row pill.
19. Choosing an encoding re-opens the document with that forced encoding, clears active search
    results/highlights, and re-renders the grid; other forced dialect parameters carry forward.
20. A truncated cell shows a visible truncation indicator in the grid driven by the truncation flag;
    the source file is unmodified.

## Open Questions
None. (Resolved during the design interview: UTF-8 path is pass-through — the "assumed UTF-8, display
does U+FFFD" caveat is retained only for the UTF-8 path, while transcoded encodings guarantee valid
UTF-8; the 8-bit Automatic default is ISO-8859-1; BOM-less UTF-16 is caught by a NUL-ratio heuristic;
`LS_CELL_MAX_BYTES` = 4 KiB; truncation is signalled by dedicated per-cell/-header bool accessors;
search matches the full cell rather than the capped display bytes; a giant record 1 opens from the
fields decoded within the head budget.)
