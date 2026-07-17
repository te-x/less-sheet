# ARCH — backend-linux-portability (Linux now, Windows-ready; pure portability, zero ABI/behavior change)

Status: APPROVED — signed off by the author 2026-07-17.
Branch: `feat/backend-linux-portability`. Component: `backend/` (Zig 0.16.0 static library).
Feature kind: **pure portability**. Not a contract amendment — `api/lesssheet.h` is untouched.

## Problem & scope

The Zig core cross-compiles today only to macOS. A prebuilt **fully-static** binary must run on
Linux — a 64-bit ARM board (`aarch64`) and an `x86_64` Linux desktop — with **no zig, compiler,
or libc install** on the target. This is the concrete unblock for `tools/bench/bench_lesssheet_on`
(the remote benchmark runner, which already cross-compiles + ships a musl-static binary and fails
today only because the core won't cross-build) and the first prerequisite for roadmap #2 (a GTK
frontend) and, later, a Windows frontend.

**Verified blocker.** `backend/src` binds libc via `const c = std.c` and uses macOS-leaning
stat-family bindings. `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast` stops at the
FIRST error, `src/root.zig:109 c.fstat: type 'void' not a function`. The compiler halts at one
error, so the real diverging set was enumerated by inspection of every `c.*` site (below), not by a
single build.

**Scope (this feature):**
- Make `backend/` cross-compile (gate-asserted) and run correctly (human-verified) as a musl-static
  library for `aarch64-linux-musl` and `x86_64-linux-musl`, keeping macOS native.
- Port the diverging `std.c` bindings to **portable Zig std** (`std.fs.File`, `std.Thread`,
  `std.time`) — not POSIX-only `std.posix` — wherever the cost is equal, so the same work also
  serves a future Windows backend and never has to be redone.
- Keep the **mmap / madvise** acquisition behind the existing **Source seam** — the single, named
  place a future Windows file-mapping backend plugs in — without writing any Windows code now.
- Make `build.zig`'s Apple `libtool` repack **macOS-target-conditional** so a Linux target installs
  the zig-native archive (lld links it directly).
- Verify the **Linux network/TLS path now** (human, real host): a real HTTPS CSV open via
  `ls_open_url_*` succeeds — the Linux system CA/cert store loads and TLS verifies. (This overrides
  the architect's initial "defer" recommendation, per the human.)

## Non-goals (explicit)

- **No Windows code is written or built now.** Windows is a genuinely larger lift than Linux: it has
  **no POSIX libc and no `mmap`** — `std.posix.mmap`/`munmap`/`madvise` are `@compileError`/absent on
  `x86_64-windows-gnu` (verified in the installed 0.16.0 std). A Windows port therefore needs a real
  **Source-layer backend** (`CreateFileMapping`/`MapViewOfFile`, or a `pread`-into-buffer fallback),
  not a binding swap. This ARCH names exactly where it plugs in (the Source seam) and prefers
  portable std APIs so the non-mmap surface is already Windows-ready — but ships nothing for Windows.
  Windows is **out of the gate target set** (its seam has no implementation yet — expected).
- **No 32-bit target.** `arm-linux-musleabihf` cross-compiles, but a 32-bit address space cannot
  `mmap` a multi-GB file, so the product's headline "open a 10 GB CSV instantly" is physically
  impossible there without a windowed-mmap redesign that does not belong in a portability pass. The
  human's ARM board runs a 64-bit OS, so 32-bit is moot and excluded.
- **No ABI change.** `api/lesssheet.h` is byte-identical; this is not a two-key contract amendment.
- **No behavior change on macOS.** The macOS native build, every existing `zig build test`, and the
  macOS app gate stay green; local (mmap/gzip) behavior is byte-identical.
- **No new file format, no net-model change.** The lazy/demand-driven network model
  (ARCH-never-full-download-streaming) is unchanged; this feature only makes it *compile and run* on
  Linux and verifies its TLS there.

## The binding port (exact map)

`const c = std.c` diverges from Linux/musl (and from Windows) only for the sites below. The port
target is chosen per-site to be **portable across macOS + Linux + (future) Windows** where equal-cost;
the two genuinely platform-specific primitives stay behind the Source seam.

**A. Linux-blocking (must change for the cross-build to compile):**

| Current (`src/…`) | Uses | Port to (portable std) |
|---|---|---|
| `root.zig:108–111` | `c.Stat`, `c.fstat`, `posix.S.ISREG(st.mode)`, `st.size` | `std.fs.File.stat()` → `Stat.size`; regular-file check via `Stat.kind == .file` |
| `index.zig:419` | `c.MADV.DONTNEED` (constant) | `std.posix.MADV.DONTNEED` (POSIX works on macOS+Linux); `madvise` stays behind the Source/index seam (see C) |
| `net_source.zig:26–27` | `c.timespec`, `c.nanosleep` | `std.time` (e.g. `std.Thread.sleep(ns)`) |

**B. Windows-ready portable swaps (accepted now — equal-cost, keep all tests green, so the Linux
work is not redone when Windows lands):**

| Current (`src/…`) | Uses | Port to (portable std) |
|---|---|---|
| `base.zig:154–155,569–579,677–678`; `source.zig:101–102,150–153,219–220,649,1002,1049`; `net.zig`; `net_source.zig` | `c.pthread_mutex_t`/`cond_t`, `pthread_mutex_lock`/`unlock`/`destroy`, `pthread_cond_wait`/`broadcast`/`destroy` | `std.Thread.Mutex`, `std.Thread.Condition` (cross-platform incl. Windows). Semantically identical; the macOS locking primitive is re-touched — accepted. |
| `source.zig:396,413`; (`net_source.zig` file I/O) | `c.pwrite`, `c.pread` | `std.fs.File.pwrite`/`pread` |
| `net_source.zig:426,476` | `c.ftruncate` | `std.fs.File.setEndPos` |
| `root.zig:106`; `source.zig:213`; `net_source.zig:427,…` | `c.close` | `std.fs.File.close` (wrap/obtain the fd as a `File`) |
| `source.zig:381`; `net_source.zig:461` | `c.unlink` | `std.fs` delete (e.g. `Dir.deleteFile`) |
| `source.zig:379`; `net_source.zig:459` | `c.getpid` (temp-name uniqueness only) | a portable uniqueness source (thread id / counter / random) — not `getpid` |

The exact std signatures/wrappers are the planner's (contracts) and implementer's (src) call — this
table fixes the **direction and rationale**, not code.

**C. Stays platform-specific behind the Source seam (NOT ported now — the Windows plug-in point):**

- `posix.mmap` / `posix.munmap` — used at `root.zig:117,124,129` (file-head map) and
  `net_source.zig:430,446,478` (net spool map). POSIX; **compiles and works on Linux and macOS**, so
  Linux needs no change here. These acquisition points, plus the `Source`/`Cursor` union in
  `source.zig` that already abstracts `.mmap` vs `.gzip`, are the **named seam** where a future
  Windows backend substitutes `CreateFileMapping`/`MapViewOfFile` (or a `pread`-into-buffer Source).
- `posix.madvise` + `MADV` — a hint; POSIX on macOS+Linux. On a future Windows backend it becomes a
  no-op (or `PrefetchVirtualMemory`). Confined to `index.zig`'s `madviseDontNeed`.
- `posix.openatZ`/`posix.AT.FDCWD` — POSIX open; works on Linux+macOS. (A future Windows backend
  would open via `std.fs`; not required now.)

## build.zig: per-target archive production (architecture-significant)

`build.zig` lines ~44–55 unconditionally run Apple `ar` + `libtool` to re-pack the archive to
Apple ld64's 8-byte member alignment. That is a **macOS-only** step: for a Linux target it must be
**skipped**, and the zig-native archive installed directly (lld links musl-static archives fine).
Make the repack conditional on the resolved target being macOS
(`target.result.os.tag == .macos`); otherwise `b.addInstallArtifact`/install the library artifact as
produced. `build.zig` is a `DEPENDENCY_PATH` in `backend/.aidev/profile.sh` — **planner-owned**; this
change is assigned to the planner, not the implementer.

## Gate: cross-compile assertion (deterministic, in-gate)

The backend gate gains a **cross-compile assertion**: after the native `zig build`, assert
`zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast` and
`zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast` both succeed (compile + archive the
full static library, `net.zig` included). This is the exact build step `bench_lesssheet_on` already
performs, so a green gate means the bench runner's build phase is green. **Compile-only:** cross tests
cannot run in-gate (`zig build test` for a Linux triple would produce a non-executable-on-host
binary), and Linux TLS cannot be exercised headlessly — those are human-runtime ACs. The assertion
lives in the gate/profile layer (orchestrator/planner-owned `.aidev/`), never in `src/`.

## Linux network/TLS verification (human, real host — in scope now)

The benchmark never touches the net path, and real HTTP is a fake-seam-only path in the gate on every
OS (unchanged). Linux `std.http.Client` + `std.crypto.tls` read the system CA bundle differently than
macOS, so this is verified **at runtime by the human on a real Linux host**, not in the gate. Because
no net-capable Linux harness exists today (the bench binary is CSV-local only), this feature must
**deliver a minimal, cross-compilable net-probe** — a tiny host program that calls `ls_open_url_*`
against a real HTTPS range-serving host and prints the first rows — shipped/run via the same
cross-compile-and-ship mechanism as `bench_lesssheet_on` (e.g. `tools/`). Without it the "verify
Linux net now" criterion is not human-runnable. Placement/reuse (extend the bench runner vs a
sibling tool) is the planner's call; the requirement is that H3 below is runnable.

## Non-functional constraints (unchanged, must hold)

- **Cold-start < 500 ms** (launch → first rows) and **open O(viewport), not O(file)** are unchanged.
  The port touches only how bytes/fds/locks are named, never the windowed access model. No path may
  read a whole file before first paint.
- **macOS byte-identical.** Local mmap/gzip behavior, cell bytes, row/column results, and all budgets
  are identical before/after on macOS. `std.Thread.Mutex/Condition` are semantically equal to the
  pthread primitives they replace.
- **Fully-static Linux binaries.** musl targets → no runtime libc/toolchain dependency on the target.
- **Zig 0.16.0 pinned.** Every std API used is verified against `/opt/homebrew/.../lib/zig/std`
  (0.16.0), never from memory — `std.posix.mmap` Windows-unsupported and the `std.fs`/`std.Thread`/
  `std.time` targets in the port table were confirmed there.

## Technology decisions

1. **Official, gate-asserted Linux target set = `aarch64-linux-musl` + `x86_64-linux-musl`** (64-bit
   ARM board + Linux desktop). musl → fully-static, portable binaries. 32-bit ARM excluded (address-space
   cliff). macOS native retained unchanged.
2. **Prefer portable std over POSIX-only where equal-cost.** `std.fs.File` (stat/pread/pwrite/
   setEndPos/close), `std.Thread.Mutex`/`Condition`, `std.time` — chosen over `std.posix` so the port
   is Windows-ready in one pass. `std.posix` is retained only for the two genuinely platform-specific
   primitives (mmap/madvise) that stay behind the Source seam.
3. **mmap/madvise isolation = the Windows plug-in seam.** Kept behind the existing `Source`/`Cursor`
   abstraction + the named acquisition points; no Windows backend built now.
4. **Gate asserts cross-compile** for both Linux triples (compile+archive, incl. `net.zig`); Windows
   is deliberately excluded from the gate set.
5. **Linux net/TLS verified now, by the human, on real hosts** (not gate-able headlessly); a minimal
   cross-compilable net-probe is delivered so the check is runnable.
6. **`build.zig` repack made macOS-target-conditional** (planner-owned dependency file).

## Acceptance criteria

Each is testable. **GATE** = deterministic, run in-gate by the orchestrator. **HUMAN-RUNTIME** =
run by the human on real hardware (compiling ≠ running; Linux TLS is not headless-verifiable).

### GATE (automated, must stay green)

- **G1.** `zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast` succeeds — the full static
  library (including `net.zig`) compiles and archives with no error. (Proves the binding port; the
  old `c.fstat` compile error is gone.)
- **G2.** `zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast` succeeds (same).
- **G3.** macOS native conformance green: `zig version` == 0.16.0 and native `zig build` succeeds.
- **G4.** All existing backend behavior tests green: `zig build test` passes unchanged — **zero
  behavior change** (the pthread→`std.Thread` swap and file/stat swaps are semantically identical).
- **G5.** **Zero ABI change:** `api/lesssheet.h` is byte-identical to its pre-feature state (root
  gate `api/` integrity check).
- **G6.** macOS app gate stays green: the root gate (which chains `apps/macos/.aidev/gate.sh`)
  passes — the Swift frontend links and its tests pass against the unchanged ABI.
- **G7.** For a Linux target build, the Apple `libtool` repack does **not** run and the installed
  `liblesssheet.a` is the zig-native archive (implied by G1/G2 succeeding without invoking
  mac-only `libtool` on ELF objects; verifiable by inspecting the build graph / the repack's target
  guard).

### HUMAN-RUNTIME (real hardware; recorded, not gate-blocking)

- **H1.** `tools/bench/bench_lesssheet_on <host>:<dir>` (aarch64, 64-bit ARM board OS) cross-compiles, ships,
  runs, and returns a correct benchmark report — no crash, plausible row/scan results.
- **H2.** Same on an `x86_64` Linux desktop.
- **H3.** On a real Linux host (both arches reachable; verify on both, at minimum one), a real HTTPS
  CSV open via `ls_open_url_*` (the delivered net-probe) succeeds: the system cert store loads, TLS
  verifies against a real range-serving host, and the first rows are returned. This is the
  "verify-Linux-net-now" criterion.

### Non-goal marker

- **Windows:** no criterion — deliberately unbuilt. The Source seam (§ "Stays platform-specific")
  and the portable-std choices are the recorded plug-in point for the future Windows feature.

## Open Questions

None. All four scoping forks (target set, gate cross-compile assertion, net/TLS scope, runtime hosts)
were resolved with the human on 2026-07-17; the Windows scope fork resolved to "Linux now,
Windows-ready" (portable-std + named seam, nothing Windows built now).
