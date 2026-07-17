#!/usr/bin/env python3
"""
less-sheet backend benchmark — plain python3, stdlib only (no pip installs).

Generates CSV test files IN THE CURRENT DIRECTORY (so you can benchmark different
disks by cd-ing onto each one), opens them through the frozen C ABI, runs the
main backend operations, times them, prints + saves a report, then deletes the
test files.

  cd /some/disk/under/test
  python3 /path/to/repo/tools/bench/less_sheet_bench.py            # default sizes
  python3 .../less_sheet_bench.py --sizes 100,1000,4000 --cold     # bigger + cold-cache
  python3 .../less_sheet_bench.py --repo /path/to/less-sheet       # if auto-locate fails

How it works: the script (1) finds the repo, (2) builds the backend static lib
with `zig build -Doptimize=ReleaseFast` (or uses --lib), (3) compiles a tiny C
harness that #includes api/lesssheet.h and links the lib (needs `cc`/`clang`),
(4) generates fixtures in CWD, (5) runs the harness (warm; also cold with --cold),
(6) reports, (7) cleans up. Build artifacts live in the repo / a temp dir; only
the fixtures touch CWD (the disk under test).

Requirements on each machine: python3, zig 0.16.0 (unless --lib), a C compiler.
No python packages.
"""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# The C harness. #includes the real frozen header (via -I <repo>/api), so it
# uses the ABI types directly — no struct mirroring. argv[1] = fixture path,
# argv[2] = copy-row cap. Emits one `RESULT op=<name> ...` line per operation.
# ---------------------------------------------------------------------------
HARNESS_C = r'''
#include "lesssheet.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>

static double now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1e3 + (double)t.tv_nsec / 1e6;
}
static void nap_us(long us) { struct timespec t = {0, us * 1000L}; nanosleep(&t, NULL); }

static void emit(const char *op, double ms, uint64_t bytes, uint64_t rows) {
    if (bytes > 0)
        printf("RESULT op=%s ms=%.3f bytes=%llu rows=%llu gbps=%.4f\n",
               op, ms, (unsigned long long)bytes, (unsigned long long)rows,
               ((double)bytes / 1e9) / (ms / 1e3));
    else
        printf("RESULT op=%s ms=%.3f bytes=0 rows=%llu gbps=0\n",
               op, ms, (unsigned long long)rows);
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <csv> [copy_row_cap]\n", argv[0]); return 2; }
    const char *path = argv[1];
    uint64_t copy_cap_rows = (argc > 2) ? strtoull(argv[2], NULL, 10) : 1000000ULL;

    struct stat st; uint64_t fbytes = (stat(path, &st) == 0) ? (uint64_t)st.st_size : 0;

    /* open — O(head): disk seek + head parse (cold-start proxy). */
    double t = now_ms();
    ls_doc *doc = NULL;
    if (ls_open(path, NULL, &doc) != LS_OK || !doc) { fprintf(stderr, "open failed\n"); return 1; }
    emit("open", now_ms() - t, 0, 0);

    /* first_window — materialize the first viewport (time-to-first-rows). */
    t = now_ms();
    ls_window_set(doc, 0, 100);
    emit("first_window", now_ms() - t, 0, 0);

    /* index_scan — full-file index sweep (disk bandwidth + lexer). */
    t = now_ms();
    for (;;) { if (ls_index_poll(doc).complete) break; nap_us(500); }
    emit("index_scan", now_ms() - t, fbytes, ls_row_count_get(doc).count);

    ls_row_count rc = ls_row_count_get(doc);
    uint64_t count = rc.count;
    uint32_t cols = ls_column_count(doc);

    /* search_scan — full scan applying the matcher to every cell (no match). */
    ls_search_request nreq; memset(&nreq, 0, sizeof nreq);
    nreq.kind = LS_SEARCH_TEXT;
    static const char *NQ = "ZQZ_no_such_token_ZQZ";
    nreq.value_ptr = (const uint8_t *)NQ; nreq.value_len = strlen(NQ);
    t = now_ms();
    if (ls_search_start(doc, &nreq)) {
        for (;;) { if (ls_search_poll(doc).total_exact) break; nap_us(500); }
    }
    emit("search_scan", now_ms() - t, fbytes, count);

    /* filter_scan — full filter sweep (same no-match predicate). */
    t = now_ms();
    if (ls_filter_set(doc, &nreq)) {
        for (;;) { ls_filter_status f = ls_filter_poll(doc);
                   if (f.total_exact || f.state == LS_FILTER_DONE || f.state == LS_FILTER_CANCELLED) break;
                   nap_us(500); }
    }
    emit("filter_scan", now_ms() - t, fbytes, count);
    ls_filter_clear(doc);

    /* jump_last — seek/scan to the final row. */
    if (count > 0) {
        t = now_ms();
        ls_jump_start(doc, count - 1);
        for (;;) { if (ls_jump_poll(doc).state == LS_JUMP_DONE) break; nap_us(500); }
        emit("jump_last", now_ms() - t, 0, 0);
    }

    /* copy_all — streaming TSV copy of up to copy_cap_rows rows (the new ls_copy_*). */
    if (count > 0) {
        uint64_t crows = count < copy_cap_rows ? count : copy_cap_rows;
        ls_copy_rect rect; memset(&rect, 0, sizeof rect);
        rect.first_row = 0; rect.row_count = crows; rect.first_col = 0; rect.col_count = cols;
        static uint8_t buf[65536];
        uint64_t total = 0;
        t = now_ms();
        ls_copy_job *job = ls_copy_open(doc, &rect);
        if (job) {
            for (;;) {
                ls_copy_progress p = ls_copy_next(job, buf, sizeof buf);
                total += (uint64_t)p.written;
                if (p.step == LS_COPY_STEP_DONE) break;
                if (p.step == LS_COPY_STEP_STALLED) {   /* fully indexed here, so rare */
                    ls_jump_start(doc, p.stalled_row);
                    for (;;) { if (ls_jump_poll(doc).state == LS_JUMP_DONE) break; nap_us(500); }
                }
            }
            ls_copy_close(job);
        }
        emit("copy_rows", now_ms() - t, total, crows);
    }

    /* random_window — 200 random viewport materializations (random-access latency). */
    if (count > 0) {
        unsigned int seed = 2654435761u;
        uint32_t vis = 50;
        int N = 200;
        t = now_ms();
        for (int i = 0; i < N; i++) {
            seed = seed * 1664525u + 1013904223u;
            uint64_t r = (count > vis) ? (seed % (count - vis)) : 0;
            ls_window_set(doc, r, vis);
        }
        double per = (now_ms() - t) / (double)N;
        emit("random_window_avg", per, 0, (uint64_t)N);
    }

    ls_close(doc);
    return 0;
}
'''

RESULT_RE = re.compile(r"RESULT op=(\S+) ms=([\d.]+) bytes=(\d+) rows=(\d+) gbps=([\d.]+)")

# Operation display order + one-line descriptions for the report legend.
OPS = [
    ("open",               "open (O(head): disk seek + head parse)"),
    ("first_window",       "first window materialized (time-to-first-rows)"),
    ("index_scan",         "full index scan (disk bandwidth + lexer)"),
    ("search_scan",        "full search scan (matcher over every cell)"),
    ("filter_scan",        "full filter scan"),
    ("jump_last",          "jump to the last row"),
    ("copy_rows",          "streaming TSV copy (ls_copy_*)"),
    ("random_window_avg",  "avg of 200 random-row window sets"),
]


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def find_repo(explicit):
    """Locate the repo (contains api/lesssheet.h + backend/build.zig)."""
    cands = []
    if explicit:
        cands.append(explicit)
    if os.environ.get("LESSSHEET_REPO"):
        cands.append(os.environ["LESSSHEET_REPO"])
    # Walk up from this script's location, then from CWD.
    for start in (os.path.dirname(os.path.abspath(__file__)), os.getcwd()):
        d = start
        for _ in range(8):
            cands.append(d)
            d = os.path.dirname(d)
    for c in cands:
        if c and os.path.isfile(os.path.join(c, "api", "lesssheet.h")) \
             and os.path.isfile(os.path.join(c, "backend", "build.zig")):
            return os.path.abspath(c)
    die("could not locate the less-sheet repo (need api/lesssheet.h + backend/build.zig). "
        "Pass --repo <path> or set LESSSHEET_REPO.")


def build_lib(repo, prebuilt):
    if prebuilt:
        if not os.path.isfile(prebuilt):
            die("--lib path does not exist: " + prebuilt)
        return os.path.abspath(prebuilt)
    if not shutil.which("zig"):
        die("zig not found on PATH (needed to build the backend). Install zig 0.16.0, "
            "or pass --lib <prebuilt liblesssheet.a>.")
    print("[build] zig build -Doptimize=ReleaseFast (backend) ...", flush=True)
    r = run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=os.path.join(repo, "backend"))
    if r.returncode != 0:
        die("backend build failed:\n" + r.stderr[-2000:])
    lib = os.path.join(repo, "backend", "zig-out", "lib", "liblesssheet.a")
    if not os.path.isfile(lib):
        die("built, but liblesssheet.a not found at " + lib)
    return lib


def compile_harness(repo, lib, workdir):
    cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("clang") or shutil.which("gcc")
    if not cc:
        die("no C compiler found (cc/clang/gcc). Set $CC.")
    src = os.path.join(workdir, "ls_bench_harness.c")
    with open(src, "w") as f:
        f.write(HARNESS_C)
    out = os.path.join(workdir, "ls_bench_harness")
    cmd = [cc, "-O2", "-I", os.path.join(repo, "api"), "-o", out, src, lib]
    sysname = platform.system()
    if sysname == "Darwin":
        cmd += ["-framework", "Security", "-framework", "CoreFoundation"]
    else:  # Linux (incl. ARM board) and friends
        cmd += ["-lm", "-lpthread"]
    print("[build] compiling C harness ...", flush=True)
    r = run(cmd)
    if r.returncode != 0:
        die("harness compile failed:\n" + " ".join(cmd) + "\n" + r.stderr[-2000:])
    return out


# A ~4 KiB-ish repeating block of realistic rows (id,value,payload). Repeating
# content is fine — we measure I/O + parse/scan cost, not entropy. No search
# token collides with the harness's no-match query.
_PAYLOADS = ["A1b2C3d4E5f6G7h8", "Zx9Yw8Vu7Ts6Rq5", "mNbVcXsWqA0zL1kP",
             "7f3e9a1c5d8b2604", "Qwerty12Asdfgh34", "delta-echo-foxtrot"]


def gen_fixture(path, target_bytes):
    """Write a valid CSV of ~target_bytes to `path`, in CWD, buffered + fast."""
    header = b"id,value,payload\n"
    # Build one block of many rows once, then write it repeatedly.
    rows = []
    for i in range(20000):
        pid = i * 2654435761 & 0xFFFFFFFFFFFF
        val = (i * 40503) & 0xFFFFFFFF
        pay = _PAYLOADS[i % len(_PAYLOADS)]
        rows.append(b"%012d,%d,%s\n" % (pid, val, pay.encode()))
    block = b"".join(rows)
    written = 0
    with open(path, "wb", buffering=1 << 20) as f:
        f.write(header); written += len(header)
        while written < target_bytes:
            f.write(block); written += len(block)
    return written


def drop_caches():
    """Best-effort page-cache drop for a cold read. Returns (ok, note)."""
    sysname = platform.system()
    try:
        subprocess.run(["sync"], check=False)
        if sysname == "Darwin":
            r = subprocess.run(["purge"], capture_output=True)
            if r.returncode == 0:
                return True, "purge"
            return False, "purge failed (try `sudo purge`)"
        elif sysname == "Linux":
            # Needs root. Try direct, then sudo -n (non-interactive).
            for cmd in (["sh", "-c", "echo 3 > /proc/sys/vm/drop_caches"],
                        ["sudo", "-n", "sh", "-c", "echo 3 > /proc/sys/vm/drop_caches"]):
                r = subprocess.run(cmd, capture_output=True)
                if r.returncode == 0:
                    return True, "drop_caches"
            return False, "drop_caches needs root (run as root or with passwordless sudo)"
    except Exception as e:  # noqa
        return False, "cache-drop error: %r" % e
    return False, "unsupported OS for cache drop"


def parse_run(stdout):
    out = {}
    for line in stdout.splitlines():
        m = RESULT_RE.match(line.strip())
        if m:
            op, ms, b, rows, gbps = m.groups()
            out[op] = {"ms": float(ms), "bytes": int(b), "rows": int(rows), "gbps": float(gbps)}
    return out


def run_harness(harness, fixture, copy_cap):
    r = run([harness, fixture, str(copy_cap)], timeout=3600)
    if r.returncode != 0:
        die("harness run failed on %s:\n%s" % (fixture, r.stderr[-1500:]))
    return parse_run(r.stdout)


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%.0f %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def machine_info(cwd):
    info = {
        "host": platform.node(),
        "os": "%s %s" % (platform.system(), platform.release()),
        "arch": platform.machine(),
        "cpus": os.cpu_count(),
        "python": platform.python_version(),
        "cwd (disk under test)": cwd,
    }
    # Best-effort RAM + CPU model (Linux /proc; macOS sysctl).
    try:
        if platform.system() == "Linux":
            with open("/proc/meminfo") as f:
                for ln in f:
                    if ln.startswith("MemTotal:"):
                        info["ram"] = human_bytes(int(ln.split()[1]) * 1024); break
            with open("/proc/cpuinfo") as f:
                for ln in f:
                    if "model name" in ln or "Model" in ln:
                        info["cpu"] = ln.split(":", 1)[1].strip(); break
        elif platform.system() == "Darwin":
            r = run(["sysctl", "-n", "hw.memsize"])
            if r.returncode == 0 and r.stdout.strip().isdigit():
                info["ram"] = human_bytes(int(r.stdout.strip()))
            r = run(["sysctl", "-n", "machdep.cpu.brand_string"])
            if r.returncode == 0 and r.stdout.strip():
                info["cpu"] = r.stdout.strip()
    except Exception:  # noqa
        pass
    return info


def fmt_table(rows):
    """rows: list of tuples; first row is the header. Returns aligned text."""
    widths = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    out = []
    for ri, r in enumerate(rows):
        cells = []
        for i, c in enumerate(r):
            s = str(c)
            cells.append(s.ljust(widths[i]) if i == 0 else s.rjust(widths[i]))
        out.append("  ".join(cells))
        if ri == 0:
            out.append("  ".join("-" * w for w in widths))
    return "\n".join(out)


def build_report(info, per_fixture, cold, copy_cap):
    L = []
    L.append("=" * 72)
    L.append("less-sheet backend benchmark")
    L.append(time.strftime("%Y-%m-%d %H:%M:%S %z"))
    L.append("=" * 72)
    for k, v in info.items():
        L.append("  %-22s %s" % (k + ":", v))
    L.append("  %-22s %s" % ("mode:", "COLD (page cache dropped) + warm" if cold else "warm (page cache)"))
    L.append("  %-22s %s rows" % ("copy cap:", "{:,}".format(copy_cap)))
    L.append("")
    for fx in per_fixture:
        L.append("-" * 72)
        L.append("fixture: %s  (%s, %s rows)" % (
            fx["name"], human_bytes(fx["bytes"]), "{:,}".format(fx.get("rowcount", 0))))
        L.append("-" * 72)
        header = ("operation", "warm ms", "warm GB/s")
        if cold:
            header = ("operation", "warm ms", "warm GB/s", "cold ms", "cold GB/s")
        table = [header]
        warm = fx["warm"]
        coldd = fx.get("cold", {})
        for op, desc in OPS:
            w = warm.get(op)
            if not w:
                continue
            ms = "%.2f" % w["ms"]
            gbps = ("%.3f" % w["gbps"]) if w["gbps"] > 0 else "-"
            if cold:
                c = coldd.get(op)
                cms = ("%.2f" % c["ms"]) if c else "-"
                cgbps = ("%.3f" % c["gbps"]) if (c and c["gbps"] > 0) else "-"
                table.append((op, ms, gbps, cms, cgbps))
            else:
                table.append((op, ms, gbps))
        L.append(fmt_table(table))
        L.append("")
    L.append("legend:")
    for op, desc in OPS:
        L.append("  %-18s %s" % (op, desc))
    L.append("")
    L.append("notes: warm = page-cache resident; cold = after a page-cache drop (needs")
    L.append("  root/sudo, best-effort). GB/s for scans = file bytes / time; for copy =")
    L.append("  TSV bytes / time. open/first_window/jump/random are latency (ms), no GB/s.")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description="less-sheet backend benchmark (stdlib only).")
    ap.add_argument("--sizes", default="50,500",
                    help="comma-separated fixture sizes in MB (default: 50,500). "
                         "Scale up on fast/large disks, e.g. 200,2000,8000.")
    ap.add_argument("--repo", default=None, help="path to the less-sheet repo (else auto-located)")
    ap.add_argument("--lib", default=None, help="prebuilt liblesssheet.a (skips zig build)")
    ap.add_argument("--cold", action="store_true", help="also measure cold (drop page cache; needs root)")
    ap.add_argument("--copy-cap", type=int, default=1000000, help="max rows to copy in copy_rows (default 1e6)")
    ap.add_argument("--keep", action="store_true", help="keep the generated fixtures (don't delete)")
    ap.add_argument("--out", default=None, help="report file path (default bench-<host>-<ts>.txt in CWD)")
    ap.add_argument("--harness", default=None,
                    help="use a PREBUILT harness binary (skips repo/zig/cc entirely). "
                         "This is how the remote runner works: cross-compile on a machine "
                         "that has zig, ship the binary here.")
    ap.add_argument("--print-harness", action="store_true",
                    help="print the embedded C harness source to stdout and exit "
                         "(used by the remote runner to cross-compile).")
    args = ap.parse_args()

    if args.print_harness:
        sys.stdout.write(HARNESS_C)
        return

    try:
        sizes_mb = [int(x) for x in args.sizes.split(",") if x.strip()]
    except ValueError:
        die("--sizes must be comma-separated integers (MB)")

    cwd = os.getcwd()
    if args.harness:
        # Prebuilt (e.g. cross-compiled + shipped by the remote runner): no repo,
        # no zig, no C compiler needed here.
        harness = os.path.abspath(args.harness)
        if not os.path.isfile(harness):
            die("--harness not found: " + harness)
        try:
            os.chmod(harness, 0o755)
        except OSError:
            pass
        workdir = None
        print("[info] prebuilt harness: %s" % harness)
        print("[info] disk under test (CWD): %s" % cwd)
    else:
        repo = find_repo(args.repo)
        print("[info] repo:  %s" % repo)
        print("[info] disk under test (CWD): %s" % cwd)
        lib = build_lib(repo, args.lib)
        workdir = tempfile.mkdtemp(prefix="lsbench-")
        harness = compile_harness(repo, lib, workdir)

    fixtures = []
    per_fixture = []
    try:
        for mb in sizes_mb:
            name = "lsbench_%dMB.csv" % mb
            path = os.path.join(cwd, name)
            print("[gen ] %s (~%d MB) ..." % (name, mb), flush=True)
            actual = gen_fixture(path, mb * 1024 * 1024)
            fixtures.append(path)

            entry = {"name": name, "bytes": actual}
            if args.cold:
                ok, note = drop_caches()
                if not ok:
                    print("[cold] cache drop unavailable: %s (cold numbers will equal warm)" % note)
                print("[run ] %s cold pass ..." % name, flush=True)
                entry["cold"] = run_harness(harness, path, args.copy_cap)
            # warm: run twice, keep the second (steady-state)
            print("[run ] %s warm pass ..." % name, flush=True)
            run_harness(harness, path, args.copy_cap)
            warm = run_harness(harness, path, args.copy_cap)
            entry["warm"] = warm
            entry["rowcount"] = warm.get("index_scan", {}).get("rows", 0)
            per_fixture.append(entry)

        info = machine_info(cwd)
        report = build_report(info, per_fixture, args.cold, args.copy_cap)
        print("\n" + report)

        out = args.out or os.path.join(
            cwd, "bench-%s-%s.txt" % (platform.node() or "host", time.strftime("%Y%m%d-%H%M%S")))
        with open(out, "w") as f:
            f.write(report + "\n")
        print("\n[done] report written to %s" % out)
    finally:
        if not args.keep:
            for p in fixtures:
                try:
                    os.remove(p)
                except OSError:
                    pass
            print("[clean] removed %d fixture(s) from %s" % (len(fixtures), cwd))
        else:
            print("[keep] fixtures left in %s" % cwd)
        if workdir:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
