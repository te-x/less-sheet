# csvgen — a streaming, deterministic CSV test-fixture generator

`csvgen` produces a documented corpus of `.csv` files for stress-testing **any**
CSV parser. It is a single, self-contained Python 3 program with **no third-party
dependencies** (standard library only), so it runs out of the box on macOS and
Linux.

The corpus is deliberately **parser-agnostic**: it is an adversarial catalog built
to exercise the CSV format itself (quoting, encodings, delimiters, line endings,
size/shape extremes, and malformations), never tailored to one implementation.

## Key properties

- **Streaming / constant memory.** Every case is generated as a stream of bounded
  byte chunks, so files up to ~10 GB are written without ever holding them in RAM.
  Peak memory stays flat (~30–40 MB, the interpreter baseline) regardless of output
  size — proven in the self-test (see below).
- **Deterministic.** Output depends only on the case, `--seed`, and (for
  size-scaling cases) the byte target. Same inputs ⇒ **byte-identical** output.
  `.csv.gz` copies are reproducible too (gzip `mtime=0`, no stored filename, fixed
  compression level).
- **Self-documenting.** A machine-readable `manifest.json` describes every case and
  the exact properties each fixture must parse to. Every generated file is **exactly**
  what the manifest claims — for size/large cases the byte size is guaranteed by
  construction and asserted after writing; for the small cases it is measured.

## Requirements

Python 3.6+ (developed and tested on 3.14). No packages to install.

## Usage

```
python3 gen.py --out <dir> [--case <name> ... | --all] [--size <target>] [--seed <n>] [--gzip]
python3 gen.py --list                     # print the whole catalog
python3 gen.py --out <dir> --manifest-only # write only manifest.json
```

| Flag | Meaning |
| --- | --- |
| `--out DIR` | Output directory (created if missing). Required except with `--list`. |
| `--case NAME` | Generate one case. Repeatable (`--case a --case b`). |
| `--all` | Generate the whole catalog **except heavy cases** (> 8 MiB), which are listed with the command to produce them on demand. |
| `--size TARGET` | Byte target for the size-scaling cases. Accepts `1KB`, `100MB`, `10GB`, or a raw byte count. Binary units (1 KB = 1024 B). |
| `--seed N` | PRNG seed (default `1337`). |
| `--gzip` | Also emit a reproducible `<case>.csv.gz` next to each file. |
| `--manifest-only` | Write `manifest.json` only (no fixtures). |
| `--list` | Print the catalog (name, byte size, malformed?, delimiter, encoding). |

`gen.py` writes `manifest.json` into `--out` on every run so a downstream harness
always has an accurate description of the files present.

### Examples

```bash
# Whole light catalog + gzip copies + manifest, into ./corpus
python3 gen.py --out corpus --all --gzip

# A single 10 GB streamed fixture (on demand; nothing buffered in RAM)
python3 gen.py --out big --case size_10gb

# A custom size via the generic size-scaling case
python3 gen.py --out big --case size_scaling --size 2500MB

# Just the malformed fixtures
python3 gen.py --out mal --case mal_unterminated_quote --case mal_broken_utf8

# Reproducibility: identical bytes for the same seed
python3 gen.py --out a --case medium_mixed --seed 7
python3 gen.py --out b --case medium_mixed --seed 7
cmp a/medium_mixed.csv b/medium_mixed.csv   # => identical
```

## `manifest.json` schema

Top-level: `tool`, `format_version`, `seed`, `size_target_for_scalable`,
`chunk_bytes`, `all_light_max_bytes`, notes, `case_count`, and `cases[]`. Each entry:

| Field | Meaning |
| --- | --- |
| `name`, `file` | Case name and its `.csv` filename. |
| `category` | `happy`, `corner`, `bom`, `encoding`, `delimiter`, `unicode`, `malformed`, `shape`, `size`. |
| `description` | One line describing what the case exercises. |
| `malformed` | `true` if the file is intentionally malformed. |
| `encoding` | e.g. `utf-8`, `utf-16le`, `utf-16be`, `latin-1`, `windows-1252` (or a `... (invalid)` note for malformed byte cases). |
| `delimiter` / `delimiter_name` | The field delimiter char (`,` `;` `\t` `\|`) and its name; `null`/`none` if not applicable. |
| `quoting` | `none`, `minimal`, `all`, or `mixed`. |
| `eol` | `LF`, `CRLF`, `mixed`, `none`, or `n/a`. |
| `has_header` | Whether row 1 is a header. |
| `column_count` | Integer, `"ragged"` (varies per row), or `null` (undefined for malformed input). |
| `data_row_count` | Number of data records **excluding** the header, or `null` when undefined. |
| `byte_size` | Exact file size in bytes. A harness can assert `stat(file).st_size == byte_size`. |
| `heavy` | `true` if `> 8 MiB` (skipped by `--all`; generate explicitly). |
| `scalable` / `size_target` | `true` and the effective byte target for size-scaling / large cases. |
| `notes` | Extra guidance (e.g. expected parser behavior for malformed cases). |

## What it generates (63 cases)

- **happy (6):** numeric, text, mixed, date-like, header/no-header, and a medium
  (~5000-row) table.
- **corner / well-formed but tricky (21):** quoted fields; quoted-with-delimiter;
  quoted embedded LF and CRLF; escaped doubled quotes; ragged rows; empty file;
  header-only; single column; single row; trailing newline present/absent; LF /
  CRLF / mixed line endings; leading/trailing and whitespace-only fields; blank
  lines interspersed; duplicate and empty header names; an all-numeric first row.
- **BOMs (3):** UTF-8, UTF-16LE, UTF-16BE byte-order marks.
- **encodings (5):** UTF-8, UTF-16LE, UTF-16BE, Latin-1, Windows-1252 (with
  cp1252-only glyphs `€ ‰ ™`).
- **delimiters (4):** comma, semicolon, tab, pipe.
- **unicode (5):** multibyte scripts, combining marks / NFD, emoji (incl. ZWJ and
  skin-tone), right-to-left, and very long unicode fields.
- **malformed (8):** unterminated quote to EOF; stray unescaped quote; inconsistent
  quoting; broken/truncated UTF-8; odd-length UTF-16; embedded NUL bytes;
  delimiter-only rows; mismatched line endings inside quotes.
- **shape extremes (5):** `wide_100k_cols` (100k columns × 3 rows); `tall_3col`
  (3 columns × tens of millions of rows); `varying_rows` (row widths from 0 B to
  ~1 MB in one file); `single_big_cell` (one multi-MB quoted cell); `single_big_row`
  (one enormous wide row among small rows).
- **size scaling (6):** `size_1kb`, `size_1mb`, `size_100mb`, `size_1gb`,
  `size_10gb`, and generic `size_scaling` (target set by `--size`).

Run `python3 gen.py --list` for the exact, current list with byte sizes.

### Heavy cases (skipped by `--all`)

`size_100mb`, `size_1gb`, `size_10gb`, `tall_3col`, `varying_rows`,
`single_big_cell`, `single_big_row`. They are documented in the manifest and are
generated on demand, e.g. `python3 gen.py --out big --case size_1gb`. The
size-scaling / large cases respond to `--size`.

## Self-test

```bash
python3 selftest.py
```

Verifies, **without generating anything larger than ~100 MB**:

1. **determinism** — same seed ⇒ byte-identical `.csv` and `.csv.gz`; a different
   seed changes randomized content; `.gz` decompresses to the exact `.csv`.
2. **exact byte sizes** — every file's on-disk size equals its `manifest.byte_size`
   (all light cases plus the heavy shape cases that fit under 100 MB, plus a scaled
   size target).
3. **round-trip** — every well-formed case parses through Python's stdlib `csv`
   reader to exactly the manifest's row and column counts (decoding per the declared
   encoding/delimiter first).
4. **malformed** — each malformed case is flagged in the manifest **and** the
   pathology is genuinely present in the bytes (not silently repaired); the
   decode-breaking cases (broken UTF-8, odd UTF-16) raise as expected.
5. **streaming memory** — peak RSS is measured (in fresh subprocesses) as output
   grows 1 MB → 100 MB and asserted to stay flat, demonstrating constant memory and
   hence that generation scales to 10 GB.

The exact-size arithmetic for the size-scaling core is also validated analytically
up to 10 GB without writing multi-GB files.
