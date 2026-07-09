#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
csvgen - a streaming, deterministic, dependency-free CSV test-fixture generator.

Produces a documented corpus of .csv files for stress-testing ANY CSV parser.

Design invariants
------------------
* NO third-party dependencies (Python 3 standard library only).
* STREAMING output: every case is a generator of bounded byte chunks, so a file
  of any size (up to ~10 GB) is written in constant memory. Nothing is ever held
  whole in RAM.
* DETERMINISTIC: output depends only on (case, --seed, and for size-scaling cases
  the effective byte target). Same inputs => byte-identical output. .csv.gz copies
  are made reproducible (gzip mtime=0, no stored filename, fixed compression level).
* SELF-DOCUMENTING: writes a machine-readable manifest.json describing every case
  the tool can produce and the exact properties each fixture must parse to.

Every fixture is EXACTLY what the manifest claims. For size-scaling / large cases
the byte size is guaranteed by construction (computed analytically and asserted
after writing); for the small hand-crafted cases it is measured by generation.

See README.md for usage.
"""

import argparse
import io
import json
import os
import random
import string
import sys

try:
    import gzip
except ImportError:  # pragma: no cover - gzip is always present in CPython
    gzip = None

try:
    import resource
except ImportError:  # pragma: no cover - not present on Windows; we target mac/linux
    resource = None


# --------------------------------------------------------------------------- #
# Constants                                                                     #
# --------------------------------------------------------------------------- #

CHUNK = 1 << 20                 # 1 MiB streaming chunk / flush granularity
ALL_LIGHT_MAX = 8 << 20         # --all only auto-generates cases <= 8 MiB
# Characters safe to appear unquoted in a CSV field (no delimiter/quote/CR/LF):
CLEAN_ALPHABET = (string.ascii_letters + string.digits).encode("ascii")

KB = 1 << 10
MB = 1 << 20
GB = 1 << 30


# --------------------------------------------------------------------------- #
# Small helpers                                                                 #
# --------------------------------------------------------------------------- #

def human_size(text):
    """Parse a human byte size ('1KB','100MB','1GB','2048') into an int (binary)."""
    s = str(text).strip().upper().replace("IB", "B")
    mult = 1
    for suf, m in (("KB", KB), ("MB", MB), ("GB", GB), ("K", KB), ("M", MB),
                   ("G", GB), ("B", 1)):
        if s.endswith(suf):
            s = s[: -len(suf)]
            mult = m
            break
    s = s.strip()
    if not s:
        raise ValueError("empty size")
    return int(float(s) * mult)


def peak_rss_bytes():
    """Peak resident set size of this process, in bytes (0 if unavailable)."""
    if resource is None:
        return 0
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    # macOS reports bytes; Linux reports kilobytes.
    return r if sys.platform == "darwin" else r * 1024


def make_pool(seed, n=4096):
    """Deterministic pool of 'clean' bytes (letters+digits), keyed by seed.

    random.Random(str) seeds via SHA-512 (documented, hash-randomization-proof),
    so this is stable across processes and runs."""
    rng = random.Random("pool:%d" % seed)
    return bytes(rng.choice(CLEAN_ALPHABET) for _ in range(n))


def case_rng(seed, name):
    """Per-case deterministic RNG (string seed => reproducible)."""
    return random.Random("%d:%s" % (seed, name))


def filler_bytes(pool, width):
    """Exactly `width` bytes tiled from the clean pool (letters/digits only)."""
    if width <= 0:
        return b""
    if width <= len(pool):
        return pool[:width]
    reps = width // len(pool) + 1
    return (pool * reps)[:width]


def stream_filler(pool, width, chunk=CHUNK):
    """Yield exactly `width` clean bytes in <= chunk pieces (constant memory)."""
    if width <= 0:
        return
    tile = filler_bytes(pool, min(chunk, width))
    remaining = width
    while remaining > 0:
        take = min(remaining, len(tile))
        yield tile[:take] if take != len(tile) else tile
        remaining -= take


# --------------------------------------------------------------------------- #
# Minimal RFC-4180-ish CSV encoder (full control; no stdlib csv dependency)     #
# --------------------------------------------------------------------------- #

def q(field, delim=",", always=False):
    """Quote a single field if needed (or always)."""
    need = always or (delim in field) or ('"' in field) or ("\n" in field) or ("\r" in field)
    if need:
        return '"' + field.replace('"', '""') + '"'
    return field


def csv_line(fields, delim=",", eol="\n", always=False):
    return delim.join(q(f, delim, always) for f in fields) + eol


def table_text(rows, delim=",", eol="\n", always=False, trailing=True):
    """Render a list-of-rows to CSV text. `trailing` controls a final EOL."""
    s = "".join(csv_line(r, delim, eol, always) for r in rows)
    if not trailing and s.endswith(eol):
        s = s[: -len(eol)]
    return s


# --------------------------------------------------------------------------- #
# Context passed to every case generator                                        #
# --------------------------------------------------------------------------- #

class Ctx:
    __slots__ = ("seed", "target", "pool")

    def __init__(self, seed, target):
        self.seed = seed
        self.target = target
        self.pool = make_pool(seed)


# --------------------------------------------------------------------------- #
# Size-scaling core (exact byte size by construction)                           #
# --------------------------------------------------------------------------- #

SIZE_HEADER = b"id,value,payload\n"   # 17 bytes
SIZE_MINROW = 25                      # id(12)+","+value(10)+"," + "\n"  (empty payload)
SIZE_L0 = 64                          # nominal full-row width (payload = 39)
SIZE_MINTARGET = len(SIZE_HEADER) + SIZE_MINROW  # 42


def plan_size(target):
    """Return (n_rows, nominal_payload, last_payload) for an exact-`target` file."""
    if target < SIZE_MINTARGET:
        raise ValueError(
            "size target %d too small; minimum is %d bytes" % (target, SIZE_MINTARGET))
    remaining = target - len(SIZE_HEADER)
    n = remaining // SIZE_L0
    if n < 1:
        n = 1
    last_w = remaining - (n - 1) * SIZE_L0
    last_payload = last_w - SIZE_MINROW
    assert last_payload >= 0
    return n, SIZE_L0 - SIZE_MINROW, last_payload


def gen_size(ctx):
    """3-column file whose total byte size is EXACTLY ctx.target."""
    n, p_nom, p_last = plan_size(ctx.target)
    pool = ctx.pool
    const_payload = filler_bytes(pool, p_nom)       # 39 bytes, seed-derived
    last_payload = filler_bytes(pool, p_last)
    K = 2654435761
    M = 10_000_000_000
    yield SIZE_HEADER
    buf = bytearray()
    batch = 20000
    i = 1
    while i <= n:
        end = min(n, i + batch - 1)
        hi = end if end < n else end - 1           # rows [i..hi] use const payload
        if hi >= i:
            buf += b"".join(
                b"%012d,%010d,%s\n" % (j, (j * K) % M, const_payload)
                for j in range(i, hi + 1)
            )
        if end == n:                                # the single, size-exact last row
            buf += b"%012d,%010d,%s\n" % (n, (n * K) % M, last_payload)
        if len(buf) >= CHUNK:
            yield bytes(buf)
            buf = bytearray()
        i = end + 1
    if buf:
        yield bytes(buf)


def size_dims(ctx):
    n, _, _ = plan_size(ctx.target)
    return n


# --------------------------------------------------------------------------- #
# Shape-extreme generators                                                      #
# --------------------------------------------------------------------------- #

WIDE_N = 100_000        # columns
WIDE_ROWS = 3           # data rows


def wide_size():
    hdr = sum(1 + len(str(i)) for i in range(WIDE_N)) + (WIDE_N - 1) + 1
    datarow = WIDE_N * 5 + (WIDE_N - 1) + 1
    return hdr + WIDE_ROWS * datarow


def gen_wide(ctx):
    # Header c0,c1,...  then WIDE_ROWS data rows of fixed-width (5-digit) numbers.
    header = b",".join(b"c%d" % i for i in range(WIDE_N)) + b"\n"
    yield header
    for r in range(WIDE_ROWS):
        yield b",".join(b"%05d" % ((i + r) % 100000) for i in range(WIDE_N)) + b"\n"


TALL_HEADER = b"id,x,y\n"          # 7
TALL_W = 35                        # id(12)+","+x(10)+","+y(10)+"\n"


def tall_rows(ctx):
    return max(1, (ctx.target - len(TALL_HEADER)) // TALL_W)


def tall_size(ctx):
    return len(TALL_HEADER) + tall_rows(ctx) * TALL_W


def gen_tall(ctx):
    n = tall_rows(ctx)
    K1, K2, M = 2654435761, 40503, 10_000_000_000
    yield TALL_HEADER
    buf = bytearray()
    batch = 30000
    i = 1
    while i <= n:
        end = min(n, i + batch - 1)
        buf += b"".join(
            b"%012d,%010d,%010d\n" % (j, (j * K1) % M, (j * K2) % M)
            for j in range(i, end + 1)
        )
        if len(buf) >= CHUNK:
            yield bytes(buf)
            buf = bytearray()
        i = end + 1
    if buf:
        yield bytes(buf)


VARY_WIDTHS = [0, 5, 80, 1024, 65536, 1048576]   # severe per-row variation
VARY_HEADER = b"idx,data\n"                        # 9


def vary_cycle_bytes():
    return sum(10 + w for w in VARY_WIDTHS)        # idx(8)+","+data(w)+"\n" = 10+w


def vary_reps(ctx):
    return max(1, (ctx.target - len(VARY_HEADER)) // vary_cycle_bytes())


def vary_size(ctx):
    return len(VARY_HEADER) + vary_reps(ctx) * vary_cycle_bytes()


def vary_rows(ctx):
    return vary_reps(ctx) * len(VARY_WIDTHS)


def gen_vary(ctx):
    reps = vary_reps(ctx)
    pool = ctx.pool
    yield VARY_HEADER
    counter = 0
    for _ in range(reps):
        for w in VARY_WIDTHS:
            yield b"%08d," % counter
            counter += 1
            if w:
                yield from stream_filler(pool, w)
            yield b"\n"


SBC_HEADER = b"id,note,data\n"     # 13
SBC_PRE = b'1,big,"'               # 7
SBC_SUF = b'"\n'                   # 2


def sbc_cell(ctx):
    return max(1, ctx.target - (len(SBC_HEADER) + len(SBC_PRE) + len(SBC_SUF)))


def sbc_size(ctx):
    return len(SBC_HEADER) + len(SBC_PRE) + sbc_cell(ctx) + len(SBC_SUF)


def gen_sbc(ctx):
    yield SBC_HEADER
    yield SBC_PRE
    yield from stream_filler(ctx.pool, sbc_cell(ctx))
    yield SBC_SUF


SBR_HEADER = b"x,y\n"              # 4
SBR_PRE = b"1,2\n" * 3            # 12
SBR_POST = b"8,9\n" * 2          # 8
SBR_FW = 63                       # width of each field in the big row


def sbr_k(ctx):
    avail = ctx.target - (len(SBR_HEADER) + len(SBR_PRE) + len(SBR_POST))
    return max(1, avail // (SBR_FW + 1))          # each field costs field+delim ~= 64


def sbr_size(ctx):
    return len(SBR_HEADER) + len(SBR_PRE) + len(SBR_POST) + (SBR_FW + 1) * sbr_k(ctx)


def gen_sbr(ctx):
    k = sbr_k(ctx)
    field = filler_bytes(ctx.pool, SBR_FW)
    yield SBR_HEADER
    yield SBR_PRE
    buf = bytearray()
    for j in range(k):
        if j:
            buf += b","
        buf += field
        if len(buf) >= CHUNK:
            yield bytes(buf)
            buf = bytearray()
    buf += b"\n"
    yield bytes(buf)
    yield SBR_POST


# --------------------------------------------------------------------------- #
# Hand-crafted small cases                                                      #
# --------------------------------------------------------------------------- #

BASE_ROWS = [
    ["id", "name", "category", "amount", "active"],
    ["1", "alpha", "x", "012.50", "1"],
    ["2", "bravo", "y", "034.00", "0"],
    ["3", "charlie", "x", "1005.99", "1"],
    ["4", "delta", "z", "000.00", "0"],
    ["5", "echo", "y", "77.20", "1"],
]  # 5 columns, 5 data rows

WORDS = ["alpha", "bravo", "delta", "gamma", "kappa", "sigma", "omega", "zebra"]  # len 5


def one(b):
    """Wrap a bytes blob as a single-chunk generator factory."""
    def g(ctx):
        yield b
    return g


def gen_happy_numeric(ctx):
    rng = case_rng(ctx.seed, "happy_numeric")
    out = bytearray(b"a,b,c,d\n")
    for _ in range(100):
        out += b"%06d,%06d,%06d,%06d\n" % (
            rng.randrange(1000000), rng.randrange(1000000),
            rng.randrange(1000000), rng.randrange(1000000))
    yield bytes(out)


def gen_happy_text(ctx):
    rng = case_rng(ctx.seed, "happy_text")
    out = bytearray(b"w1,w2,w3\n")
    for _ in range(100):
        out += ("%s,%s,%s\n" % (rng.choice(WORDS), rng.choice(WORDS),
                                rng.choice(WORDS))).encode("ascii")
    yield bytes(out)


def gen_happy_mixed(ctx):
    rng = case_rng(ctx.seed, "happy_mixed")
    out = bytearray(b"id,name,category,amount,active\n")
    for i in range(1, 51):
        out += ("%05d,%s,%s,%09.2f,%d\n" % (
            i, rng.choice(WORDS), rng.choice("xyz"),
            rng.uniform(0, 9999.99), rng.randrange(2))).encode("ascii")
    yield bytes(out)


def gen_happy_dates(ctx):
    rng = case_rng(ctx.seed, "happy_dates")
    out = bytearray(b"date,event\n")
    for _ in range(60):
        y = rng.randrange(2000, 2026)
        m = rng.randrange(1, 13)
        d = rng.randrange(1, 29)
        out += ("%04d-%02d-%02d,%s\n" % (y, m, d, rng.choice(WORDS))).encode("ascii")
    yield bytes(out)


def gen_happy_no_header(ctx):
    rng = case_rng(ctx.seed, "happy_no_header")
    out = bytearray()
    for i in range(1, 81):
        out += ("%05d,%s,%07.2f\n" % (
            i, rng.choice(WORDS), rng.uniform(0, 999.99))).encode("ascii")
    yield bytes(out)


def gen_medium_mixed(ctx):
    rng = case_rng(ctx.seed, "medium_mixed")
    yield b"id,ts,name,value,flag,note0\n"
    buf = bytearray()
    for i in range(1, 5001):
        buf += ("%08d,%010d,%s,%09.2f,%d,%s\n" % (
            i, 1700000000 + i, rng.choice(WORDS), rng.uniform(0, 99999.99),
            rng.randrange(2), rng.choice(WORDS))).encode("ascii")
        if len(buf) >= CHUNK:
            yield bytes(buf)
            buf = bytearray()
    if buf:
        yield bytes(buf)


# Encoding-specific tables ---------------------------------------------------
UNI_ROWS = [
    ["id", "name", "city", "note"],
    ["1", "Ada", "Zürich", "café"],
    ["2", "Grace", "São Paulo", "naïve"],
    ["3", "Lin", "Kraków", "Ångström"],
]
LATIN1_ROWS = [
    ["id", "name", "note"],
    ["1", "café", "niño"],
    ["2", "Zürich", "Ångström"],
    ["3", "Öl", "Fußball"],
]
CP1252_ROWS = [
    ["id", "price", "brand"],
    ["1", "12€", "App™"],
    ["2", "1‰", "naïve"],
    ["3", "99€", "coöp"],
]


def enc_gen(rows, encoding, bom=b""):
    text = table_text(rows, delim=",", eol="\n")
    payload = bom + text.encode(encoding)
    return one(payload)


UNICODE_ROWS = {
    "unicode_multibyte": [
        ["lang", "text"],
        ["ja", "日本語のテキスト"],
        ["ru", "Москва"],
        ["gr", "Ελλάδα"],
        ["cjk", "中文字符測試"],
    ],
    "unicode_combining": [
        ["form", "text"],
        ["nfc", "café"],
        ["nfd", "café"],          # e + combining acute
        ["multi", "à́̂"],
        ["hangul", "가가"],
    ],
    "unicode_emoji": [
        ["kind", "text"],
        ["face", "😀😃😄"],
        ["zwj", "👩‍💻"],           # woman technologist (ZWJ)
        ["flag", "🏳️‍🌈"],
        ["skin", "👍🏽"],
    ],
    "unicode_rtl": [
        ["lang", "text"],
        ["ar", "مرحبا بالعالم"],
        ["he", "שלום עולם"],
        ["mix", "abc ‫عربى‬ xyz"],
    ],
}


def gen_unicode_long(ctx):
    rows = [
        ["id", "blob"],
        ["1", "あ" * 4000],
        ["2", "🚀" * 2000],
        ["3", "é" * 3000],
    ]
    yield table_text(rows).encode("utf-8")


# Malformed generators -------------------------------------------------------

def gen_mal_unterminated(ctx):
    body = (b"id,note\n"
            b"1,fine\n"
            b'2,"this quoted cell is never closed and runs to EOF with, commas\n'
            b"and embedded newlines and no terminating quote character at all")
    yield body


def gen_mal_stray_quote(ctx):
    yield (b"id,note\n"
           b'1,ab"cd,ef\n'
           b"2,fine,ok\n"
           b"3,plain,value\n")


def gen_mal_inconsistent(ctx):
    yield (b"id,name,note\n"
           b'1,"Ada","ok"\n'
           b"2,Bob,ok\n"
           b'3,"Cy",partly"quoted\n'
           b'4,"Dee","tail",extra\n')


def gen_mal_broken_utf8(ctx):
    yield (b"id,note\n"
           b"1,valid\n"
           b"2,broken\xff\xfe\x80value\n"
           b"3,truncated\xc3\n"           # lead byte with no continuation
           b"4,\xe2\x28\xa1seq\n"         # invalid 3-byte sequence
           b"5,ok\n")


def gen_mal_odd_utf16(ctx):
    text = table_text([["id", "name"], ["1", "Ada"], ["2", "Bob"]])
    data = text.encode("utf-16-le")
    yield data + b"\x21"                    # append 1 byte => odd length => truncated unit


def gen_mal_embedded_nul(ctx):
    yield (b"id,note\n"
           b"1,a\x00b\n"
           b"2,c\x00\x00d\n"
           b"3,clean\n")


def gen_mal_only_delims(ctx):
    yield (b"a,b,c,d\n"
           b",,,\n"
           b",,,,\n"
           b"1,2,3,4\n"
           b",,,\n")


def gen_mal_eol_in_quotes(ctx):
    # Records terminated by CRLF, but quoted fields contain mismatched lone
    # LF and lone CR, and the final quoted field is never closed (runs to EOF).
    yield (b"id,note\r\n"
           b'1,"has a lone \n LF inside quotes"\r\n'
           b'2,"has a lone \r CR inside quotes"\r\n'
           b'3,"mixed \r\n and \n endings"\r\n'
           b'4,"unterminated with \n inside and CRLF record end but no closing quote\r\n')


# --------------------------------------------------------------------------- #
# Case registry                                                                 #
# --------------------------------------------------------------------------- #

CASES = []
_INDEX = {}


def register(**kw):
    kw.setdefault("delimiter", ",")
    kw.setdefault("delimiter_name", "comma")
    kw.setdefault("quoting", "none")
    kw.setdefault("eol", "LF")
    kw.setdefault("encoding", "utf-8")
    kw.setdefault("has_header", True)
    kw.setdefault("malformed", False)
    kw.setdefault("scalable", False)
    kw.setdefault("notes", "")
    CASES.append(kw)
    _INDEX[kw["name"]] = kw


# ---- common / happy ----
register(name="happy_numeric", category="happy",
         description="Typical all-numeric table with header.",
         col=4, rows=100, gen=gen_happy_numeric)
register(name="happy_text", category="happy",
         description="Typical text table (short words) with header.",
         col=3, rows=100, gen=gen_happy_text)
register(name="happy_mixed", category="happy",
         description="Mixed int/text/float/bool columns with header.",
         col=5, rows=50, gen=gen_happy_mixed)
register(name="happy_dates", category="happy",
         description="Date-like first column (YYYY-MM-DD) plus text.",
         col=2, rows=60, gen=gen_happy_dates)
register(name="happy_no_header", category="happy", has_header=False,
         description="Well-formed mixed data with NO header row.",
         col=3, rows=80, gen=gen_happy_no_header)
register(name="medium_mixed", category="happy",
         description="Medium (~5000-row) well-formed mixed table.",
         col=6, rows=5000, gen=gen_medium_mixed)

# ---- corner cases (well-formed but tricky) ----
register(name="quoted_fields", category="corner", quoting="all",
         description="Every field quoted, though quoting is not strictly required.",
         col=5, rows=5, gen=one(table_text(BASE_ROWS, always=True).encode()))
register(name="quoted_with_delimiter", category="corner", quoting="minimal",
         description="Quoted fields that contain the delimiter (comma).",
         col=3, rows=3,
         gen=one(table_text([["id", "name", "city"],
                             ["1", "Ada, Countess", "London, UK"],
                             ["2", "Bob", "Paris, France"],
                             ["3", "Cy, Jr.", "Rome"]]).encode()))
register(name="quoted_with_lf", category="corner", quoting="minimal",
         description="Quoted field containing an embedded LF newline.",
         col=2, rows=3,
         gen=one(table_text([["id", "note"],
                             ["1", "line one\nline two"],
                             ["2", "single"],
                             ["3", "a\nb\nc"]]).encode()))
register(name="quoted_with_crlf", category="corner", quoting="minimal",
         description="Quoted field containing an embedded CRLF newline.",
         col=2, rows=3,
         gen=one(table_text([["id", "note"],
                             ["1", "line one\r\nline two"],
                             ["2", "single"],
                             ["3", "x\r\ny"]]).encode()))
register(name="quoted_doubled_quotes", category="corner", quoting="minimal",
         description='Quoted field with escaped doubled quotes ("").',
         col=2, rows=3,
         gen=one(table_text([["id", "quote"],
                             ["1", 'She said "hi"'],
                             ["2", 'a "b" c "d"'],
                             ["3", '""']]).encode()))
register(name="ragged", category="corner", col="ragged", rows=5,
         description="Rows with differing field counts (ragged, well-formed).",
         notes="Column count varies per row: 3,1,5,2,4.",
         gen=one(b"a,b,c\n1,2,3\nsolo\n4,5,6,7,8\n9,10\n11,12,13,14\n"))
register(name="empty_file", category="corner", col=None, rows=0, has_header=False,
         encoding="n/a", delimiter=None, delimiter_name="none", eol="none",
         description="Zero-byte file (empty input).",
         gen=one(b""))
register(name="header_only", category="corner", col=5, rows=0,
         description="Header row present, no data rows.",
         gen=one(table_text([BASE_ROWS[0]]).encode()))
register(name="single_column", category="corner", col=1, rows=5,
         description="Single column, several rows.",
         gen=one(b"value\n10\n20\n30\n40\n50\n"))
register(name="single_row", category="corner", col=3, rows=1, has_header=False,
         description="Exactly one record, no header.",
         gen=one(b"42,hello,world\n"))
register(name="trailing_newline_present", category="corner", col=5, rows=5,
         description="Well-formed file that ends WITH a trailing newline.",
         gen=one(table_text(BASE_ROWS, trailing=True).encode()))
register(name="trailing_newline_absent", category="corner", col=5, rows=5,
         eol="LF", notes="Final record has no terminating newline.",
         description="Well-formed file that ends WITHOUT a trailing newline.",
         gen=one(table_text(BASE_ROWS, trailing=False).encode()))
register(name="eol_lf", category="corner", eol="LF", col=5, rows=5,
         description="Unix LF (\\n) line endings.",
         gen=one(table_text(BASE_ROWS, eol="\n").encode()))
register(name="eol_crlf", category="corner", eol="CRLF", col=5, rows=5,
         description="Windows CRLF (\\r\\n) line endings.",
         gen=one(table_text(BASE_ROWS, eol="\r\n").encode()))
register(name="eol_mixed", category="corner", eol="mixed", col=5, rows=5,
         description="Mixed LF and CRLF record terminators in one file.",
         notes="Rows alternate between LF and CRLF terminators.",
         gen=one((csv_line(BASE_ROWS[0], eol="\n") + csv_line(BASE_ROWS[1], eol="\r\n")
                  + csv_line(BASE_ROWS[2], eol="\n") + csv_line(BASE_ROWS[3], eol="\r\n")
                  + csv_line(BASE_ROWS[4], eol="\n") + csv_line(BASE_ROWS[5], eol="\r\n")).encode()))
register(name="leading_trailing_whitespace", category="corner", col=3, rows=3,
         description="Fields with leading/trailing spaces preserved.",
         gen=one(b"id,name,city\n 1 , Ada , London \n2,  Bob  ,Paris\n 3,Cy, Rome \n"))
register(name="whitespace_only_fields", category="corner", col=4, rows=3,
         description="Fields that are only spaces/tabs (and empty).",
         gen=one(b"a,b,c,d\n , ,\t,\n  ,,   ,\t\t\n1, ,3, \n"))
register(name="blank_lines_interspersed", category="corner", col=5, rows=5,
         description="Blank lines interspersed between data records.",
         notes="Blank lines yield empty records in strict parsers; 5 non-empty data rows.",
         gen=one((csv_line(BASE_ROWS[0]) + "\n" + csv_line(BASE_ROWS[1]) + "\n"
                  + csv_line(BASE_ROWS[2]) + "\n" + csv_line(BASE_ROWS[3])
                  + csv_line(BASE_ROWS[4]) + "\n\n" + csv_line(BASE_ROWS[5])).encode()))
register(name="duplicate_headers", category="corner", col=5, rows=2,
         description="Header with duplicate column names.",
         gen=one(b"id,name,id,name,value\n1,a,2,b,3\n4,c,5,d,6\n"))
register(name="empty_headers", category="corner", col=5, rows=2,
         description="Header with empty/blank column names.",
         gen=one(b"id,,category,,value\n1,a,x,b,10\n2,c,y,d,20\n"))
register(name="all_numeric_first_row", category="corner", has_header=False,
         col=5, rows=4,
         description="First row is all numbers (ambiguous whether it is a header).",
         notes="A parser cannot tell if row 1 is a header; treated here as data.",
         gen=one(b"1,2,3,4,5\n6,7,8,9,10\n11,12,13,14,15\n16,17,18,19,20\n"))

# ---- BOMs ----
register(name="bom_utf8", category="bom", encoding="utf-8",
         description="UTF-8 content prefixed with a UTF-8 BOM (EF BB BF).",
         notes="Leading BOM must be stripped, not treated as data.",
         col=4, rows=3, gen=enc_gen(UNI_ROWS, "utf-8", b"\xef\xbb\xbf"))
register(name="bom_utf16le", category="bom", encoding="utf-16le",
         description="UTF-16LE content with a UTF-16LE BOM (FF FE).",
         col=4, rows=3, gen=enc_gen(UNI_ROWS, "utf-16-le", b"\xff\xfe"))
register(name="bom_utf16be", category="bom", encoding="utf-16be",
         description="UTF-16BE content with a UTF-16BE BOM (FE FF).",
         col=4, rows=3, gen=enc_gen(UNI_ROWS, "utf-16-be", b"\xfe\xff"))

# ---- encodings (no BOM) ----
register(name="enc_utf8", category="encoding", encoding="utf-8",
         description="UTF-8 with multibyte content, no BOM.",
         col=4, rows=3, gen=enc_gen(UNI_ROWS, "utf-8"))
register(name="enc_utf16le", category="encoding", encoding="utf-16le",
         description="UTF-16LE with no BOM (endianness must be assumed).",
         col=4, rows=3, gen=enc_gen(UNI_ROWS, "utf-16-le"))
register(name="enc_utf16be", category="encoding", encoding="utf-16be",
         description="UTF-16BE with no BOM.",
         col=4, rows=3, gen=enc_gen(UNI_ROWS, "utf-16-be"))
register(name="enc_latin1", category="encoding", encoding="latin-1",
         description="Latin-1 (ISO-8859-1) high bytes (é, ñ, ü, …).",
         col=3, rows=3, gen=enc_gen(LATIN1_ROWS, "latin-1"))
register(name="enc_windows1252", category="encoding", encoding="windows-1252",
         description="Windows-1252 with cp1252-only glyphs (€, ‰, ™).",
         notes="Bytes 0x80/0x89/0x99 are cp1252-specific and invalid in Latin-1.",
         col=3, rows=3, gen=enc_gen(CP1252_ROWS, "cp1252"))

# ---- delimiters ----
register(name="delim_comma", category="delimiter", delimiter=",", delimiter_name="comma",
         description="Comma-delimited (baseline).",
         col=5, rows=5, gen=one(table_text(BASE_ROWS, delim=",").encode()))
register(name="delim_semicolon", category="delimiter", delimiter=";",
         delimiter_name="semicolon",
         description="Semicolon-delimited.",
         col=5, rows=5, gen=one(table_text(BASE_ROWS, delim=";").encode()))
register(name="delim_tab", category="delimiter", delimiter="\t", delimiter_name="tab",
         description="Tab-delimited (TSV).",
         col=5, rows=5, gen=one(table_text(BASE_ROWS, delim="\t").encode()))
register(name="delim_pipe", category="delimiter", delimiter="|", delimiter_name="pipe",
         description="Pipe-delimited.",
         col=5, rows=5, gen=one(table_text(BASE_ROWS, delim="|").encode()))

# ---- unicode ----
for _uname, _urows in UNICODE_ROWS.items():
    register(name=_uname, category="unicode", encoding="utf-8",
             description={
                 "unicode_multibyte": "Multibyte scripts (CJK, Cyrillic, Greek).",
                 "unicode_combining": "Combining marks / decomposed forms (NFD).",
                 "unicode_emoji": "Emoji incl. ZWJ sequences and skin-tone modifiers.",
                 "unicode_rtl": "Right-to-left scripts with directional marks.",
             }[_uname],
             col=2, rows=len(_urows) - 1,
             gen=one(table_text(_urows).encode("utf-8")))
register(name="unicode_long_fields", category="unicode", encoding="utf-8",
         description="Very long Unicode fields (thousands of code points each).",
         col=2, rows=3, gen=gen_unicode_long)

# ---- malformed ----
register(name="mal_unterminated_quote", category="malformed", malformed=True,
         has_header=True, col=2, rows=None, quoting="minimal",
         description="Open quote that is never closed (runs to EOF).",
         notes="A strict parser must error; a lenient one loses row structure.",
         gen=gen_mal_unterminated)
register(name="mal_stray_quote", category="malformed", malformed=True,
         col=2, rows=None,
         description="Stray unescaped double-quote inside an unquoted field.",
         gen=gen_mal_stray_quote)
register(name="mal_inconsistent_quoting", category="malformed", malformed=True,
         col=None, rows=None, quoting="mixed",
         description="Quoting style varies across rows; stray quote + extra field.",
         gen=gen_mal_inconsistent)
register(name="mal_broken_utf8", category="malformed", malformed=True,
         encoding="utf-8 (invalid)", col=2, rows=None,
         description="Invalid / truncated UTF-8 byte sequences.",
         notes="bytes.decode('utf-8') must raise UnicodeDecodeError.",
         gen=gen_mal_broken_utf8)
register(name="mal_odd_utf16", category="malformed", malformed=True,
         encoding="utf-16le (truncated)", col=2, rows=None,
         description="UTF-16LE with an odd byte length (truncated code unit).",
         notes="Odd length => decode('utf-16-le') must raise.",
         gen=gen_mal_odd_utf16)
register(name="mal_embedded_nul", category="malformed", malformed=True,
         encoding="utf-8 (with NUL)", col=2, rows=None,
         description="Embedded NUL (0x00) bytes inside fields.",
         gen=gen_mal_embedded_nul)
register(name="mal_only_delimiters", category="malformed", malformed=True,
         col=None, rows=None,
         description="Rows consisting solely of delimiters.",
         notes="Lenient parsers read these as rows of empty fields.",
         gen=gen_mal_only_delims)
register(name="mal_eol_in_quotes_mismatch", category="malformed", malformed=True,
         eol="mixed", col=2, rows=None, quoting="minimal",
         description="Mismatched line endings inside quotes + unterminated quote.",
         gen=gen_mal_eol_in_quotes)

# ---- shape extremes ----
register(name="wide_100k_cols", category="shape", col=WIDE_N, rows=WIDE_ROWS,
         description="Huge column count (100,000 cols) x 3 data rows.",
         gen=gen_wide, analytic_size=lambda ctx: wide_size())
register(name="tall_3col", category="shape", scalable=True,
         default_target=128 * MB, col=3, rows=tall_rows,
         description="3 columns x very many rows (scales with --size).",
         gen=gen_tall, analytic_size=tall_size)
register(name="varying_rows", category="shape", scalable=True,
         default_target=16 * MB, col=2, rows=vary_rows,
         description="Severely varying row lengths (0 B to ~1 MB) in one file.",
         notes="Row byte widths cycle through %r." % (VARY_WIDTHS,),
         gen=gen_vary, analytic_size=vary_size)
register(name="single_big_cell", category="shape", scalable=True,
         default_target=64 * MB, col=3, rows=1, quoting="minimal",
         description="One enormous quoted cell in an otherwise tiny file.",
         gen=gen_sbc, analytic_size=sbc_size)
register(name="single_big_row", category="shape", scalable=True,
         default_target=64 * MB, col="ragged", rows=6,
         description="One enormous (wide) row among small rows.",
         notes="The big row has many fields; other rows have 2 -> ragged.",
         gen=gen_sbr, analytic_size=sbr_size)

# ---- size scaling ----
for _n, _t in (("size_1kb", 1 * KB), ("size_1mb", 1 * MB), ("size_100mb", 100 * MB),
               ("size_1gb", 1 * GB), ("size_10gb", 10 * GB)):
    register(name=_n, category="size", fixed_target=_t, col=3, rows=size_dims,
             description="Size-scaling file of exactly %s (streamed)." % _n[5:].upper(),
             gen=gen_size, analytic_size=lambda ctx: ctx.target)
register(name="size_scaling", category="size", scalable=True, default_target=1 * MB,
         col=3, rows=size_dims,
         description="Generic size-scaling file; byte size set by --size.",
         gen=gen_size, analytic_size=lambda ctx: ctx.target)


# --------------------------------------------------------------------------- #
# Effective context + property resolution                                       #
# --------------------------------------------------------------------------- #

def effective_target(case, cli_size):
    if case.get("scalable"):
        return cli_size if cli_size is not None else case["default_target"]
    return case.get("fixed_target")   # size presets; None for the rest


def build_ctx(case, seed, cli_size):
    return Ctx(seed, effective_target(case, cli_size))


def resolve(v, ctx):
    return v(ctx) if callable(v) else v


_size_cache = {}


def expected_size(case, ctx):
    fn = case.get("analytic_size")
    if fn is not None:
        return fn(ctx)
    key = (case["name"], ctx.seed)
    if key in _size_cache:
        return _size_cache[key]
    n = 0
    for ch in case["gen"](ctx):
        n += len(ch)
    _size_cache[key] = n
    return n


# --------------------------------------------------------------------------- #
# Emission                                                                      #
# --------------------------------------------------------------------------- #

class _Counter:
    __slots__ = ("n",)

    def __init__(self):
        self.n = 0

    def write(self, b):
        self.n += len(b)


def emit(case, ctx, out_dir, gzip_too):
    fname = case["name"] + ".csv"
    path = os.path.join(out_dir, fname)
    total = 0
    gzf = None
    gz = None
    raw = open(path, "wb")
    try:
        if gzip_too:
            gzf = open(path + ".gz", "wb")
            gz = gzip.GzipFile(fileobj=gzf, mode="wb", compresslevel=9, mtime=0)
        for chunk in case["gen"](ctx):
            if not chunk:
                continue
            b = bytes(chunk)
            raw.write(b)
            if gz is not None:
                gz.write(b)
            total += len(b)
    finally:
        raw.close()
        if gz is not None:
            gz.close()
        if gzf is not None:
            gzf.close()
    exp = expected_size(case, ctx)
    if total != exp:
        raise AssertionError(
            "%s: wrote %d bytes but manifest expects %d" % (case["name"], total, exp))
    return total, path


# --------------------------------------------------------------------------- #
# Manifest                                                                      #
# --------------------------------------------------------------------------- #

def manifest_entry(case, ctx):
    col = resolve(case.get("col"), ctx)
    rows = resolve(case.get("rows"), ctx)
    size = expected_size(case, ctx)
    entry = {
        "name": case["name"],
        "file": case["name"] + ".csv",
        "category": case["category"],
        "description": case["description"],
        "malformed": bool(case["malformed"]),
        "encoding": case["encoding"],
        "delimiter": case["delimiter"],
        "delimiter_name": case["delimiter_name"],
        "quoting": case["quoting"],
        "eol": case["eol"],
        "has_header": bool(case["has_header"]),
        "column_count": col,
        "data_row_count": rows,
        "byte_size": size,
        "heavy": size > ALL_LIGHT_MAX,
        "scalable": bool(case.get("scalable")),
    }
    if case.get("scalable"):
        entry["size_target"] = ctx.target
    if case.get("fixed_target") is not None:
        entry["size_target"] = case["fixed_target"]
    if case.get("notes"):
        entry["notes"] = case["notes"]
    return entry


def build_manifest(seed, cli_size):
    cases = []
    for case in CASES:
        ctx = build_ctx(case, seed, cli_size)
        cases.append(manifest_entry(case, ctx))
    return {
        "tool": "csvgen",
        "format_version": 1,
        "seed": seed,
        "size_target_for_scalable": cli_size,
        "chunk_bytes": CHUNK,
        "all_light_max_bytes": ALL_LIGHT_MAX,
        "encoding_note": "delimiter/eol shown logically; UTF-16 encodes them as 2 bytes.",
        "column_count_note": "'ragged' = varies per row; null = undefined (malformed).",
        "row_count_note": "data_row_count excludes the header when has_header is true.",
        "case_count": len(cases),
        "cases": cases,
    }


def write_manifest(path, seed, cli_size):
    man = build_manifest(seed, cli_size)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(man, f, indent=2, ensure_ascii=True)
        f.write("\n")
    return man


# --------------------------------------------------------------------------- #
# CLI                                                                           #
# --------------------------------------------------------------------------- #

def cmd_list(seed, cli_size):
    print("%-30s %-9s %-4s %-8s %-14s %s" %
          ("CASE", "BYTES", "MAL", "DELIM", "ENCODING", "DESCRIPTION"))
    for case in CASES:
        ctx = build_ctx(case, seed, cli_size)
        size = expected_size(case, ctx)
        print("%-30s %-9d %-4s %-8s %-14s %s" % (
            case["name"], size, "yes" if case["malformed"] else "no",
            case["delimiter_name"], case["encoding"], case["description"]))


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="gen.py",
        description="Deterministic, streaming CSV test-fixture generator.")
    ap.add_argument("--out", help="output directory (created if missing)")
    ap.add_argument("--case", action="append", default=[],
                    help="generate one case (repeatable). Use --all for the catalog.")
    ap.add_argument("--all", action="store_true",
                    help="generate all cases up to %d bytes; heavy cases are skipped."
                         % ALL_LIGHT_MAX)
    ap.add_argument("--size", default=None,
                    help="byte target for size-scaling cases, e.g. 1KB, 100MB, 10GB.")
    ap.add_argument("--seed", type=int, default=1337, help="PRNG seed (default 1337).")
    ap.add_argument("--gzip", action="store_true",
                    help="also emit a reproducible .csv.gz copy of each file.")
    ap.add_argument("--manifest-only", action="store_true",
                    help="write only manifest.json (no fixture files).")
    ap.add_argument("--list", action="store_true", help="list the catalog and exit.")
    ap.add_argument("--report-mem", action="store_true",
                    help="print 'PEAK_RSS_BYTES <n>' to stderr at exit.")
    args = ap.parse_args(argv)

    cli_size = human_size(args.size) if args.size is not None else None

    try:
        if args.list:
            cmd_list(args.seed, cli_size)
            return 0

        if not args.out:
            ap.error("--out is required (except with --list)")
        os.makedirs(args.out, exist_ok=True)
        man_path = os.path.join(args.out, "manifest.json")

        if args.manifest_only:
            write_manifest(man_path, args.seed, cli_size)
            print("wrote %s (%d cases)" % (man_path, len(CASES)))
            return 0

        # Select cases.
        if args.case and args.all:
            ap.error("use either --case or --all, not both")
        if args.case:
            selected = []
            for name in args.case:
                if name not in _INDEX:
                    ap.error("unknown case '%s' (try --list)" % name)
                selected.append(_INDEX[name])
        elif args.all:
            selected, skipped = [], []
            for case in CASES:
                ctx = build_ctx(case, args.seed, cli_size)
                if expected_size(case, ctx) <= ALL_LIGHT_MAX:
                    selected.append(case)
                else:
                    skipped.append(case)
            if skipped:
                print("Skipped %d heavy case(s) (> %d bytes). Generate on demand, e.g.:"
                      % (len(skipped), ALL_LIGHT_MAX))
                for case in skipped:
                    print("  python3 gen.py --out %s --case %s" % (args.out, case["name"]))
        else:
            ap.error("specify --all, --case NAME, --manifest-only, or --list")

        total_bytes = 0
        for case in selected:
            ctx = build_ctx(case, args.seed, cli_size)
            n, path = emit(case, ctx, args.out, args.gzip)
            total_bytes += n
            print("  %-30s %12d bytes  %s" % (case["name"], n, os.path.basename(path)))

        write_manifest(man_path, args.seed, cli_size)
        print("Generated %d file(s), %d bytes total. Manifest: %s"
              % (len(selected), total_bytes, man_path))
        return 0
    finally:
        if args.report_mem:
            sys.stderr.write("PEAK_RSS_BYTES %d\n" % peak_rss_bytes())
            sys.stderr.flush()


if __name__ == "__main__":
    sys.exit(main())
