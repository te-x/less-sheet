# REVIEW — backend-linux-portability

**Verdict: PASS (converged in 1 round).** Feature branch `feat/backend-linux-portability`.
Component: `backend/` (Zig 0.16.0 static library). Signed ARCH:
`docs/architecture/ARCH-backend-linux-portability.md`. Pure portability — **zero ABI change**
(`api/lesssheet.h` byte-identical), **zero behavior change** (`zig build test` 142/0 throughout).

## What shipped
Ported the diverging macOS-leaning `std.c` libc bindings in `backend/src/` to portable Zig-std
equivalents so the core cross-compiles to `aarch64-linux-musl` + `x86_64-linux-musl` while staying
byte-identical on macOS. Diff: `base/index/net/net_source/open/root/source.zig` modified + one new
leaf module `src/sysio.zig`. `build.zig`, `contracts/`, `tests/`, `api/`, `.aidev/` untouched.

- New `src/sysio.zig` centralizes the portable primitives on `std.Io.Threaded.global_single_threaded`
  (a process-global, allocator-free, worker-pool-free blocking `Io`): `File`/`Mutex`/`Condition`,
  `io()`, `file(fd)`, `close`, `unlinkAbsolute`, `sleepMs`, `uniqueToken`.
- Port map: `c.fstat`/`c.Stat` → `std.Io.File.stat`; `c.close` → `File.close`;
  `c.pwrite`/`c.pread` → `File.writePositionalAll`/`readPositionalAll`; `c.ftruncate` → `File.setLength`;
  `c.timespec`/`c.nanosleep` → `Io.sleep` (CLOCK_MONOTONIC blocking); `c.pthread_mutex_t`/`cond_t`
  → `std.Io.Mutex`/`Condition`; `c.getpid`/`c.unlink` → `uniqueToken`/`unlinkAbsolute`;
  `c.MADV.DONTNEED` → `posix.MADV.DONTNEED` (constant-source swap).
- **Source seam (ARCH group C) intact:** `posix.mmap`/`munmap`/`madvise` + `posix.openatZ`/`AT.FDCWD`
  untouched, still behind the `Source`/`Cursor` union — the named Windows plug-in point.

## Key ARCH deviation (recorded — NOT a `[design]` change)
The ARCH's §"binding port" named `std.fs.File`, `std.Thread.Mutex`/`Condition`, `std.Thread.sleep`.
**Those APIs do not exist in Zig 0.16.0** — the Io refactor moved file syscalls behind `std.Io.File`
(each takes an `Io`) and removed `std.Thread.{Mutex,Condition,sleep}`; `std.Io.*` are the canonical
successors. The implementer used `std.Io.*` (verified against the installed 0.16.0 std, not memory).
The reviewer independently confirmed the named APIs are absent (grep count 0 in `std/Thread.zig`;
`std/fs/` has only `path.zig`/`test.zig`) and ruled this **within the exact-signature latitude the ARCH
delegated to the implementer** + faithful to the recorded direction ("portable std, not POSIX-only,
Windows-ready"). No architect/human re-sign-off required. **Follow-up (non-blocking):** the ARCH's
port table is now stale (names the nonexistent APIs); recommend a doc refresh to the shipped names.

## Reviewer's independent verification (against `/opt/homebrew/opt/zig/lib/zig/std/`)
1. **Concurrency correctness — the load-bearing claim — CONFIRMED GENUINE.** `std.Io.Mutex`/`Condition`
   are implemented on `futexWait`/`futexWake` only; for the `Threaded` backend those resolve to real
   syscalls (Linux `futex`, macOS `__ulock_wait2`/`__ulock_wake`). Every no-op/`unreachable` path is
   gated on the **comptime** `builtin.single_threaded` (false here → dead code). `global_single_threaded`
   disables only the async executor (no worker pool), not the locks — the futex functions operate on the
   futex word and never dereference the `Threaded` instance. `Io.Condition.waitInner` is lost-wakeup-safe
   (epoch read before registering). All changed wait sites sit in predicate `while` loops. Dropping
   `pthread_*_destroy` is correct (the primitives own no resources; `.init` = zeroed/unlocked).
2. **Windows-readiness HOLDS** — `Io.Mutex`/`Condition`/`sleep`/`File` all have real Windows backends
   (`NtWaitForAlertByThreadId`, `NtReadFile`/`NtWriteFile` with explicit byte offset, `NtSetInformationFile`);
   only mmap/madvise lack Windows — exactly the piece left behind the seam.
3. **Positional spill/spool I/O byte-identical + thread-safe** (offset-carrying `pwritev`/`preadv`, no
   shared cursor; short-read guard preserved). `uniqueToken()` sound (system-unique tid + monotonic
   counter + golden-ratio mix, `O_CREAT|O_EXCL` backstop → collision degrades to graceful `null`, never
   corruption). `sleepMs` is a real blocking `clock_nanosleep`, not a CPU spin.

## Objective gate (run by the orchestrator, this exact tree — hash `0652e9c9…`)
`bash ~/.claude/aidev/gate.sh --require-frozen <repo>` → **exit 0, GATE: PASS** (root), nested PASS for
the backend gate and the macOS app gate. Integrity OK; conformance = zig-0.16.0 pin + native `zig build`
+ `-Dtarget=aarch64-linux-musl` + `-Dtarget=x86_64-linux-musl` (all ReleaseFast) green; backend behavior
`zig build test` = 142/0; macOS app gate = swift build + swift test (incl. conformance pins) PASS.
`git diff -- api/` empty (byte-identical). Post-review tree-hash re-checked identical (read-only reviewer,
no tampering).

## NFR evidence — macOS perf differential (before/after, on record)
Working tree (ported) vs pre-port parent `816ab69`, native ReleaseFast, identical deterministic fixture
(8.8 MB / 220k-row CSV), warm, medians over 3 samples (macOS / Apple silicon dev box):

| op | before (ms) | after (ms) | Δ |
|---|--:|--:|--:|
| open | 6.86 | 6.82 | −0.6% |
| index_scan | 7.56 | 7.57 | +0.1% |
| search_scan | 26.46 | 27.13 | +2.5% |
| filter_scan | 26.50 | 26.50 | 0% |
| copy_rows | 82.97 | 80.17 | −3.4% |

All within a ±3% noise band → **no measurable macOS regression** (as predicted: the hot mmap window-scan
path is untouched; only a once-per-open `fstat`, the gz/net spill/spool positional I/O, and the locking
primitive changed). A first single-run pass showed `index_scan` +7.8%, which vanished under stable medians
(a one-off outlier). Note: the static `.a` grew ~200 KB (7.07 → 7.27 MB) from the pulled-in `std.Io`
machinery — a link-input size delta, not a runtime cost (link-time DCE trims unused Io code; the macOS app
still built, linked, and passed).

## Human-runtime acceptance criteria — VERIFIED on real hardware (the author, 2026-07-17)
The gate can't exercise a Linux binary or real TLS; these were run on real hardware and PASS.
- **H1 (aarch64) — PASS.** `bench_lesssheet_on` ran correctly on a ARM board 4B (Cortex-A72,
  Linux 6.18, aarch64), warm + cold, at 8/100/500 MB, on both a USB-SSD and a USB-HDD.
- **H2 (x86_64) — PASS.** Same on an i7-12700 box (Arch, Linux 7.0, x86_64), warm + cold, on NVMe and HDD.
- **H3 (real Linux TLS) — PASS on both arches.** `netprobe_on` opened
  `https://samplelib.com/csv/sample-30mb.csv` over real HTTPS on the ARM board AND the x86_64 box: the system
  cert store loaded, TLS verified, 31,457,327 bytes fetched, 8 columns + first rows parsed correctly,
  state PENDING→FETCHING→DONE, exit OK. (Not a fake seam — a real socket + real certificate.)

### Cross-platform performance (recorded)
The same core, cross-compiled once on the Mac, runs correctly + performantly on macOS/arm64,
Linux/x86_64, and Linux/aarch64. Highlights (cold cache, 500 MB / 12.5M-row CSV):
- **User-facing open→first-paint is disk-independent.** Worst case (ARM board + USB-HDD, cold) opens in
  52 ms with a 0.19 ms first window — vs the <500 ms budget. This is the O(head) open + O(viewport)
  first-window design holding on the slowest hardware/disk combination.
- **Disk only bottlenecks when its bandwidth is below the CPU lexer rate** (warm index: mac 0.67 /
  arch 0.57 / ARM board 0.13 GB/s). A fast CPU + HDD (arch) shows a +158% cold index-scan penalty; the
  ARM board is CPU-bound, so its USB-HDD ≈ USB-SSD. Full-file scans are CPU-bound (the deferred SIMD-scan work
  is the lever, not faster disk).

**All acceptance criteria satisfied (GATE + H1 + H2 + H3). Merged to master 2026-07-17.**
