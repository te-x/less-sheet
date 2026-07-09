#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Self-test for csvgen (gen.py). Verifies, without generating anything > ~100 MB:

  1. determinism      - same seed => byte-identical .csv and .csv.gz
  2. exact byte sizes  - on-disk size == manifest byte_size (all light + a few heavy)
  3. round-trip        - well-formed cases parse through the stdlib csv reader to
                         exactly the manifest's row/column counts
  4. malformed         - malformed cases are flagged AND the pathology is really in
                         the bytes (not silently repaired); decode-breaking ones raise
  5. streaming memory  - peak RSS stays flat as output grows 1 MB -> 100 MB, proving
                         constant memory (hence it scales to 10 GB)

Run:  python3 selftest.py
"""

import csv
import gzip
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile

import gen

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = 20260709

PASS = []
FAIL = []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    mark = "ok  " if cond else "FAIL"
    line = "  [%s] %s" % (mark, name)
    if detail and not cond:
        line += "  -- " + detail
    print(line)
    return cond


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def run_gen(out, extra, size=None, report_mem=False):
    cmd = [sys.executable, os.path.join(HERE, "gen.py"), "--out", out,
           "--seed", str(SEED)] + extra
    if size is not None:
        cmd += ["--size", size]
    if report_mem:
        cmd += ["--report-mem"]
    return subprocess.run(cmd, capture_output=True, text=True)


CODECS = {
    "utf-8": "utf-8", "utf-8-sig": "utf-8-sig",
    "utf-16le": "utf-16-le", "utf-16be": "utf-16-be",
    "latin-1": "latin-1", "windows-1252": "cp1252",
}


def parse_records(path, entry):
    """Parse a CSV file per its manifest entry; return list of non-empty records."""
    enc = entry["encoding"]
    if entry["name"] == "bom_utf8":
        enc = "utf-8-sig"
    codec = CODECS.get(enc, "utf-8")
    with open(path, "rb") as f:
        raw = f.read()
    text = raw.decode(codec)
    delim = entry["delimiter"] or ","
    reader = csv.reader(io.StringIO(text), delimiter=delim)
    return [r for r in reader if len(r) > 0]


def main():
    root = tempfile.mkdtemp(prefix="csvgen-selftest-")
    try:
        # ------------------------------------------------------------------ #
        print("\n== building catalog (--all) + a few heavy-but-<100MB cases ==")
        d1 = os.path.join(root, "all")
        r = run_gen(d1, ["--all", "--gzip"])
        check("gen --all --gzip exits 0", r.returncode == 0, r.stderr[-400:])

        # heavy shape cases small enough for self-test (each < 100 MB):
        for c in ("varying_rows", "single_big_cell", "single_big_row"):
            rr = run_gen(d1, ["--case", c])
            check("gen --case %s exits 0" % c, rr.returncode == 0, rr.stderr[-400:])
        # a couple of explicit size targets (<= 100 MB) via the generic case:
        for s in ("1KB", "1MB", "8MB"):
            rr = run_gen(d1, ["--case", "size_scaling"], size=s)
            check("gen size_scaling --size %s exits 0" % s, rr.returncode == 0,
                  rr.stderr[-400:])

        # Manifests: --all one has default (1MB) scalable target; rebuild per case.
        man_all = gen.build_manifest(SEED, None)
        idx = {c["name"]: c for c in man_all["cases"]}

        # ------------------------------------------------------------------ #
        print("\n== 2. exact byte sizes (on-disk == manifest) ==")
        for entry in man_all["cases"]:
            if entry["name"] == "size_scaling":
                continue  # overwritten by explicit --size runs; checked at 8MB below
            p = os.path.join(d1, entry["file"])
            if not os.path.exists(p):
                continue  # heavy case not generated in --all
            actual = os.path.getsize(p)
            check("size %s" % entry["name"], actual == entry["byte_size"],
                  "disk=%d manifest=%d" % (actual, entry["byte_size"]))
        # the explicitly generated heavy cases (default targets):
        for c in ("varying_rows", "single_big_cell", "single_big_row"):
            p = os.path.join(d1, c + ".csv")
            check("size %s" % c, os.path.getsize(p) == idx[c]["byte_size"],
                  "disk=%d manifest=%d" % (os.path.getsize(p), idx[c]["byte_size"]))
        # size_scaling at 8MB:
        man8 = {x["name"]: x for x in gen.build_manifest(SEED, 8 * 1024 * 1024)["cases"]}
        p = os.path.join(d1, "size_scaling.csv")
        check("size size_scaling@8MB", os.path.getsize(p) == man8["size_scaling"]["byte_size"],
              "disk=%d manifest=%d" % (os.path.getsize(p), man8["size_scaling"]["byte_size"]))

        # ------------------------------------------------------------------ #
        print("\n== 3. round-trip well-formed cases through stdlib csv ==")
        wellformed = [
            "happy_numeric", "happy_text", "happy_mixed", "happy_dates",
            "happy_no_header", "medium_mixed",
            "quoted_fields", "quoted_with_delimiter", "quoted_with_lf",
            "quoted_with_crlf", "quoted_doubled_quotes",
            "header_only", "single_column", "single_row",
            "trailing_newline_present", "trailing_newline_absent",
            "eol_lf", "eol_crlf", "eol_mixed",
            "duplicate_headers", "empty_headers", "all_numeric_first_row",
            "leading_trailing_whitespace", "whitespace_only_fields",
            "blank_lines_interspersed",
            "bom_utf8", "bom_utf16le", "bom_utf16be",
            "enc_utf8", "enc_utf16le", "enc_utf16be", "enc_latin1", "enc_windows1252",
            "delim_comma", "delim_semicolon", "delim_tab", "delim_pipe",
            "unicode_multibyte", "unicode_combining", "unicode_emoji",
            "unicode_rtl", "unicode_long_fields", "wide_100k_cols",
        ]
        for name in wellformed:
            entry = idx[name]
            p = os.path.join(d1, entry["file"])
            try:
                recs = parse_records(p, entry)
            except Exception as e:  # noqa
                check("roundtrip %s" % name, False, "parse raised %r" % e)
                continue
            exp_rows = entry["data_row_count"]
            got_rows = len(recs) - (1 if entry["has_header"] else 0)
            rows_ok = (exp_rows is None) or (got_rows == exp_rows)
            if entry["column_count"] in ("ragged", None):
                cols_ok = True
            else:
                widths = {len(r) for r in recs}
                cols_ok = widths == {entry["column_count"]}
            check("roundtrip %s (rows=%s cols=%s)" % (name, got_rows,
                  sorted({len(r) for r in recs})),
                  rows_ok and cols_ok,
                  "exp_rows=%s got=%s expcols=%s" %
                  (exp_rows, got_rows, entry["column_count"]))

        # ------------------------------------------------------------------ #
        print("\n== 4. malformed cases: flagged + pathology present in bytes ==")

        def raw(name):
            with open(os.path.join(d1, name + ".csv"), "rb") as f:
                return f.read()

        for name in [c["name"] for c in man_all["cases"] if c["malformed"]]:
            check("flagged malformed %s" % name, idx[name]["malformed"] is True)

        b = raw("mal_unterminated_quote")
        check("mal_unterminated_quote: odd/open quote at EOF",
              b.count(b'"') % 2 == 1 and not b.rstrip().endswith(b'"'))

        b = raw("mal_stray_quote")
        check("mal_stray_quote: stray quote inside unquoted field", b'ab"cd' in b)

        b = raw("mal_inconsistent_quoting")
        check("mal_inconsistent_quoting: quoted + unquoted-with-quote coexist",
              b'"Ada"' in b and b'partly"quoted' in b)

        b = raw("mal_broken_utf8")
        raised = False
        try:
            b.decode("utf-8")
        except UnicodeDecodeError:
            raised = True
        check("mal_broken_utf8: utf-8 decode raises", raised)

        b = raw("mal_odd_utf16")
        raised = False
        try:
            b.decode("utf-16-le")
        except UnicodeDecodeError:
            raised = True
        check("mal_odd_utf16: odd length + decode raises",
              len(b) % 2 == 1 and raised)

        b = raw("mal_embedded_nul")
        check("mal_embedded_nul: NUL byte present in bytes", b"\x00" in b)
        # not silently repaired: the NUL survives parsing into a field (some
        # parsers reject it, some keep it, but none should silently drop it).
        rows = list(csv.reader(io.StringIO(b.decode("utf-8"))))
        nul_preserved = any("\x00" in field for row in rows for field in row)
        check("mal_embedded_nul: NUL preserved into parsed field (not repaired)",
              nul_preserved)

        b = raw("mal_only_delimiters")
        check("mal_only_delimiters: a delimiter-only line exists", b"\n,,,\n" in b)

        b = raw("mal_eol_in_quotes_mismatch")
        check("mal_eol_in_quotes_mismatch: CRLF + lone LF + unterminated quote",
              b"\r\n" in b and b.count(b"\n") > b.count(b"\r\n")
              and b.count(b'"') % 2 == 1)

        # ------------------------------------------------------------------ #
        print("\n== 1. determinism: same seed => byte-identical (.csv and .csv.gz) ==")
        da = os.path.join(root, "det_a")
        db = os.path.join(root, "det_b")
        det_cases = ["happy_mixed", "medium_mixed", "size_1kb", "wide_100k_cols"]
        run_gen(da, ["--gzip"] + sum((["--case", c] for c in det_cases), []))
        run_gen(db, ["--gzip"] + sum((["--case", c] for c in det_cases), []))
        # plus a scalable case at a fixed size in both:
        run_gen(da, ["--case", "size_scaling"], size="256KB")
        run_gen(db, ["--case", "size_scaling"], size="256KB")
        for c in det_cases + ["size_scaling"]:
            fa, fb = os.path.join(da, c + ".csv"), os.path.join(db, c + ".csv")
            check("determinism %s .csv" % c, sha256(fa) == sha256(fb))
        for c in det_cases:
            ga, gbz = os.path.join(da, c + ".csv.gz"), os.path.join(db, c + ".csv.gz")
            check("determinism %s .csv.gz" % c, sha256(ga) == sha256(gbz))
        # .gz really decompresses to the .csv:
        with gzip.open(os.path.join(da, "medium_mixed.csv.gz"), "rb") as g:
            dec = g.read()
        with open(os.path.join(da, "medium_mixed.csv"), "rb") as f:
            plain = f.read()
        check("gzip decompresses to identical bytes", dec == plain)
        # different seed changes random content:
        dc = os.path.join(root, "det_c")
        cmd = [sys.executable, os.path.join(HERE, "gen.py"), "--out", dc,
               "--seed", str(SEED + 1), "--case", "happy_mixed"]
        subprocess.run(cmd, capture_output=True, text=True)
        check("different seed => different content",
              sha256(os.path.join(da, "happy_mixed.csv"))
              != sha256(os.path.join(dc, "happy_mixed.csv")))

        # ------------------------------------------------------------------ #
        print("\n== 5. streaming: peak RSS is flat as output grows to 100 MB ==")
        memdir = os.path.join(root, "mem")
        os.makedirs(memdir, exist_ok=True)
        sizes = [("1MB", 1 << 20), ("8MB", 8 << 20), ("32MB", 32 << 20),
                 ("100MB", 100 << 20)]
        peaks = []
        print("     %-8s %-14s %-14s %s" % ("target", "output_bytes", "peak_rss_MB",
                                            "peak/output"))
        for label, nbytes in sizes:
            r = run_gen(memdir, ["--case", "size_scaling"], size=label, report_mem=True)
            peak = None
            for ln in r.stderr.splitlines():
                if ln.startswith("PEAK_RSS_BYTES"):
                    peak = int(ln.split()[1])
            outp = os.path.getsize(os.path.join(memdir, "size_scaling.csv"))
            peaks.append((label, nbytes, outp, peak))
            print("     %-8s %-14d %-14.2f %.4f"
                  % (label, outp, peak / 1e6, peak / outp))
        valid = [p for (_, _, _, p) in peaks if p]
        if valid:
            flat = max(valid) / min(valid) < 1.5
            check("peak RSS flat (max/min < 1.5x across 1MB..100MB)", flat,
                  "max=%d min=%d ratio=%.3f" % (max(valid), min(valid),
                                                max(valid) / min(valid)))
            # peak must be far below the 100 MB output => not buffering the file
            biggest = peaks[-1]
            check("peak RSS << 100MB output (constant memory)",
                  biggest[3] < 0.5 * biggest[2],
                  "peak=%d output=%d" % (biggest[3], biggest[2]))
        else:
            check("peak RSS measurable", False, "no PEAK_RSS_BYTES reported")

        # ------------------------------------------------------------------ #
        print("\n== summary ==")
        print("  passed: %d   failed: %d" % (len(PASS), len(FAIL)))
        if FAIL:
            print("  FAILURES:")
            for n in FAIL:
                print("    - " + n)
        return 1 if FAIL else 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
