# ARCH — pre-launch security hardening

**Program (not one feature):** a bounded set of memory-safety and untrusted-input hardening work to
complete before less-sheet ships as a **free, public, closed-source** desktop utility that opens
**arbitrary local files and network URLs** — i.e. it ingests untrusted bytes from anyone. Spans the
Zig `backend/` core, the frozen `api/`, and both frontends (`apps/macos`, `apps/gtk`). Decisions in
this document were made interactively with the author on 2026-07-23 (two decision batches, all recorded
below). This document **prioritizes and bounds** the program: a **PRE-LAUNCH MUST** set and a
**DEFERRED** set. It does not write code, tests, or contracts — the planner freezes the acceptance
criteria below.

## Threat model (the frame every decision serves)

- **CSV is safe-by-format and less-sheet is a VIEWER** — no in-app formula/macro execution, so a
  `=cmd|…` cell is shown as literal text, never run. The CSV *content* is not the RCE risk.
- **The real RCE risk is memory-safety in OUR own Zig parser / decompressor / sources.** A crafted
  CSV / gzip / network byte-stream that trips an out-of-bounds read, integer overflow, or
  use-after-free is the actual code-execution path. Today the shipped core is **`ReleaseFast`
  (safety checks OFF)**, so such a bug is undefined behavior, not a clean panic. This is the single
  largest exploit-surface item and drives MUST item (a).
- **Secondary surfaces:** gzip-decompression work amplification (a "bomb"); network TLS/redirect/
  timeout behavior; the COPY feature propagating formula-injection into Excel/Sheets on paste; and
  adversarial-input outlier blowups.
- **What is NOT in the RCE frame:** rendering is text-only (Cairo/CoreText, no HTML/JS) → no
  XSS-class risk; the network spool is our own `O_EXCL`, immediately-unlinked file → it cannot be
  truncated by another process.

## Problem & scope

### In scope — the PRE-LAUNCH MUST set (approved, this document)
- **(a) Ship `ReleaseSafe`, and make the gate certify the shipped mode.** Whole core in `ReleaseSafe`;
  MEASURE `ReleaseSafe`-vs-`ReleaseFast` on the differential C-ABI scan bench; carve out
  `@setRuntimeSafety(false)` **only** on loops the bench proves miss budget (those become the most-fuzzed
  code). The gate today builds/tests a **Debug** core but ships **`ReleaseFast`** — the gate must build
  **and** test the exact mode we ship.
- **(b) Fix #40** — guard the `std.compress.flate` feed at fetch boundaries so a mid-DEFLATE-symbol
  truncation cannot underflow `peekBitsEnding` (a `ReleaseFast` UB crash) before the resumable `.budget`
  stop fires.
- **(c) One-time pre-launch fuzz campaign** — coverage-guided fuzzing over the C ABI (parser + gz +
  net-source reducer).
- **(d) gzip-bomb cap** — sliding-window sustained-ratio cap, **cap + warn** (never hard-refuse, never
  absolute-size), so a legit 10 GB `.csv.gz` still opens.
- **(e) Network hardening** — connect + idle-read timeouts; block `https→http` redirect downgrade;
  fix the silent zero-fill (a short/zero range body served as document content).
- **(f) Copy formula-injection neutralization** — in the core `frameCell` output, always-on.
- **(g) SIGBUS / mmap-TOCTOU** — the core installs a scoped, chained `SIGBUS` handler.
- **(h) The two outlier-cap gaps** — a max-columns overflow backstop and a network-only cumulative
  download cap.

### Explicit non-goals / DEFERRED (post-launch)
- **Control-character / RTL-override display sanitizing** (bidi-spoofing, minor) — deferred.
- **CI-integrated continuous fuzzing** — the campaign is a one-time pre-launch pass; a CI fuzz smoke is
  deferred.
- **Outlier-cap tightening beyond the two gaps in (h)** — the existing caps (cell 4 KiB, per-row scan
  1 MiB, window 8 MiB, copy 10 M cells, …) are accepted as-is.
- **TLS truncation-attack strictness** — Zig 0.16 `std.http.Client` defaults to
  `allow_truncation_attacks = true` (relies on `Content-Length`). For a viewer of public data a
  truncated response is an availability/short-body case already covered by (e)'s short-body handling, not
  a confidentiality break — accepted as a known, documented risk; deferred unless the fuzz campaign
  surfaces a concrete problem.
- No change to the read-only-core invariant, the `<500 ms` cold-start budget, the O(viewport) / never-
  full-download invariants, or the thin-frontend split. Hardening must preserve all of them.

## Inputs / Outputs (what changes observably)

- **Build/ship:** the distributed core binary is `ReleaseSafe`. No behavior change to correct inputs;
  malformed inputs that were UB become clean, defined errors or panics.
- **Copy output:** any cell value whose first byte is `=`, `+`, `-`, or `@` is emitted with a single
  leading `'` (apostrophe) prefix, in both streaming copy and single-cell copy. All other cells are
  byte-identical to today. This is a documented change to the frozen copy-output contract (see External
  interfaces).
- **Network errors:** new distinct, retryable error states for connect/idle timeout, `https→http`
  redirect downgrade, short/zero range body, and the cumulative download-cap trip. A failed fetch fails
  **only that fetch** — the document stays open and interactive.
- **gzip-bomb trip:** decompression indexing stops at the ratio threshold; already-decompressed rows
  stay viewable; a "stream expands abnormally" state is exposed for the frontends to surface as a
  non-blocking banner.
- **Adversarial open:** a record-1 declaring more than the column backstop is rejected with a clean
  error; `wide_100k_cols` (a supported wide document) still opens fully.

## Functional requirements

1. Every untrusted-input path (CSV lex/index/window, encoding transcode, gzip inflate + checkpoints,
   the HTTP range-fetch reducer, copy framing) executes with runtime safety checks ON in the shipped
   binary, except at explicitly enumerated, bench-justified `@setRuntimeSafety(false)` loops.
2. A truncated / partial compressed stream never drives the inflater into undefined behavior; it
   resolves to correct-rows-so-far plus a clean "damaged/truncated" or "await-more-bytes" outcome.
3. A high-ratio gzip stream is bounded by work (not just memory), degrading to cap + warn while staying
   interactive; a legitimate high-*absolute*-size but normal-ratio `.csv.gz` is unaffected.
4. Network fetches cannot hang the fetch thread indefinitely, cannot be silently downgraded off TLS by a
   redirect, and cannot serve un-fetched bytes as zero-filled document content.
5. Copied cells cannot carry a live formula prefix into a downstream spreadsheet.
6. A local source file truncated/removed under our mmap cannot crash the process; it surfaces a clean
   faulted-source error.
7. Pathological column counts and unbounded network streams are bounded without violating
   responsiveness (relax memory/time, never responsiveness — per the outlier-budget policy).

## Non-functional constraints

- **Cold-start `<500 ms`** (launch → first rows) holds with the shipped `ReleaseSafe` binary, carve-outs
  included. Open is O(head), so `ReleaseSafe` is expected to be noise here; this is a gate check.
- **Scan-throughput budget** (search / filter / count / deep-jump — the CPU-bound full-file family) is
  the place `ReleaseSafe` bounds-checks could bite. The `ReleaseSafe`-vs-`ReleaseFast` delta is
  measured on the differential C-ABI bench (warm runs, matcher-independent control, per the
  perf-before/after policy) and reported as NFR evidence; carve-outs are justified only by a recorded
  delta.
- **Single-source-of-truth for knobs:** every new limit/threshold (ratio cap, timeouts, redirect
  policy, column backstop, download cap) is ONE named constant with ONE resolver; every consumer reads
  the one value. Changing a knob is one line, one place.
- **Thin-frontend split preserved:** copy neutralization, the gzip-ratio trip, and network error
  classification are decided in the core; the frontends only surface/present them.

## Component decomposition & data flow

| MUST item | backend/ (Zig core) | api/ (frozen) | apps/macos + apps/gtk | dev-tooling / gate |
|---|---|---|---|---|
| (a) ReleaseSafe + carve-out | `build.zig` default → ReleaseSafe; enumerated `@setRuntimeSafety(false)` list | — | `assemble-app.sh`, GTK core cross-build, bench all build ReleaseSafe | **gate-mode fix**: every gate builds+tests ReleaseSafe; bench measures the delta |
| (b) #40 flate guard | `source.zig` / `net_source.zig` inflater feed | — | — | regression test + fuzz seed |
| (c) fuzz campaign | fuzzable entry surface | — | — | **C-ABI libFuzzer/AFL++ harness** (reuses the bench's `#include api/lesssheet.h` + link `.a` pattern) + corpus |
| (d) gzip-bomb cap | `source.zig` gz ratio guard + ABI-exposed trip flag | prose/flag (see below) | banner (reuse scan-%/filter-banner language) | — |
| (e) network hardening | `net.zig` / `net_source.zig` (timeouts, redirect scheme check, short-body error) | error-code prose | surface new network errors (reuse `NetworkOpenError`) | net fake-fixture fault paths |
| (f) copy neutralization | `root.zig` `frameCell` + single-cell copy | **frozen copy-surface delta (root planner)** | inherit for free; bridge tests assert clipboard bytes | — |
| (g) SIGBUS handler | core installs scoped chained `sigaction` at the mmap access sites | — | frontend gates stay green with the handler installed (integration) | — |
| (h) outlier caps | `open.zig` column backstop; `net_source.zig` download cap | error prose | download-cap banner | — |

**Cross-component note — frozen `api/` for (d), (e), (f):**
- **(f) is the load-bearing one.** Putting copy neutralization in the core `frameCell` changes the
  **documented copy-output contract** (what bytes a consumer receives), so `api/lesssheet.h` is a
  **frozen-surface delta** even though no signature/struct changes. The **ROOT planner** freezes the
  `api/` change, and the macOS guard
  `AmendmentContractGuardTests.frozenCAbiHeaderHasEmptyDiff` — current baseline SHA-256
  `df0436b6ea29211fd0634c40c857b626b6d85466db2a802c190d4a77c85cdd42` — **must be re-bumped in that
  same freeze**, through the change-authority process the guard provides for. No-back-compat (v1)
  applies: we own `api/` + backend + both frontends and rebuild lock-step, so change the surface to
  its simplest shape, no compat shim.
- (d)'s trip flag and (e)'s new error codes are likewise additive `api/` prose/enum changes frozen by
  the root planner and folded into the same AC23 re-bump.

## External interfaces

- **`api/lesssheet.h`** — additive/behavioral deltas only, frozen by the root planner (see cross-
  component note): (f) copy-output neutralization semantics; (d) a gzip-bomb "abnormal expansion" trip
  flag on the gz/document status surface; (e) new distinct network error codes (timeout, redirect-
  downgrade-refused, short-body, download-cap). Every existing symbol/layout stays byte-identical except
  where a v1 simplest-shape change is explicitly chosen.
- **`std.http.Client` (Zig 0.16 std)** — no new runtime dependency. Timeouts via
  `ConnectTcpOptions.timeout` + an idle-read guard; redirect scheme check added post-`redirect`; TLS
  verification stays ON (system roots, hostname check — already correct, no change).
- **Dev tooling** — a C-ABI fuzz harness (libFuzzer or AFL++, implementer's reversible choice within
  that family) and the fuzz corpus, committed but not gate-blocking (one-time cadence).

## Technology decisions

1. **Runtime safety: ship `ReleaseSafe` globally, measure, carve out only bench-proven hot loops.**
   Alternatives: pure `ReleaseFast` (status quo — UB on any parser bug); `ReleaseFast` + selective
   `@setRuntimeSafety(true)` on parse paths. Rejected because the memory-safety hotspots (unchecked
   `@intCast` on untrusted u64 positions, raw pointer math handed to the C ABI, `appendAssumeCapacity`,
   `catch unreachable`, mmap boundary handling) span essentially the whole ingest surface
   (`csv_reader`, `source`, `net_source`, `window`, `index`, `search`, `encoding`) — "only the parse
   path" is illusory. Safe-by-default with measured, enumerated exceptions is the correct posture.
   **Project-wide + durable** → PROJECT.md "Build & gate" should record "ship = `ReleaseSafe`" on
   sign-off.
2. **Fuzzer: coverage-guided libFuzzer/AFL++ over the C ABI**, built `ReleaseSafe`, seeded from the
   `csvgen` corpus + hand-crafted adversarial gz/truncation/wide/ragged inputs. Rejected: Zig's built-in
   fuzzer — less mature, and fuzzing Zig functions directly misses the cross-module hotspots reachable
   only through the real shipped entry points. The C-ABI harness fuzzes exactly what ships and reuses
   the bench's harness pattern. **One-time pre-launch** (CI-continuous deferred). Reversible dev-tool
   choice (the author delegated).
3. **gzip-bomb defense: sliding-window sustained-ratio cap, cap + warn.** Rejected: absolute-size cap
   and hard-refuse — both break the supported legit huge `.csv.gz` and contradict "10 GB opens like
   10 KB." Memory is already O(viewport); the residual risk is CPU/work, and a sustained ratio (text
   CSV ≤ ~20:1, a zeros-bomb ≫ 100:1) cleanly separates a bomb from a legit large file. Threshold is a
   single tuning knob, floor ~100:1, finalized by bench against real CSV ratios.
4. **Copy neutralization: core `frameCell`, always-on, no opt-out.** Rejected: per-frontend
   presentation — duplicates logic across macOS + GTK + future Windows and risks divergence, against
   single-source-of-truth. Framing/quoting already lives in the core, so neutralization belongs beside
   it; both frontends inherit it for free. Cost: the frozen `api/` copy-surface delta above.
5. **SIGBUS: core-installed scoped, chained `sigaction` handler.** Rejected: `fstat`-before-access
   (TOCTOU-racy, cannot actually prevent the fault) and no-handling (a truncated local file crashes the
   in-process app). Because the core is linked *into* the frontend (no helper process), the handler must
   be self-contained: it recovers (`siglongjmp`) only for faults inside its own mmap regions and chains
   through to any previously-installed handler otherwise, so the host frontends' crash handling is
   preserved.
6. **Network timeouts / redirect policy via `std.http.Client` config** — no new dependency: connect
   timeout ~10 s, idle-read timeout ~30 s (idle, not total, so a slow-but-progressing large fetch never
   trips), 3-hop redirect cap with `https→http` downgrade refused (`http→https` and same-scheme incl.
   cross-host still allowed; std already strips privileged headers cross-origin, and opens are user-
   initiated, so no SSRF host-allowlist).

## Acceptance criteria

Each criterion is tagged **[gate]** (deterministic gate test), **[bench]** (measured via the
differential C-ABI bench, reported as NFR evidence, not gate-blocking), or **[fuzz]** (verified by the
one-time campaign). The planner turns these into frozen tests.

### PRE-LAUNCH MUST

**(a) ReleaseSafe ship + gate-certifies-shipped-mode + measure + carve-out**
- **AC-a1 [gate]** — The gate builds **and** tests the same optimize mode that ships: the backend
  conformance build, the backend behavior tests (`zig build test`), the macOS core build in
  `assemble-app.sh`, the GTK core cross-build, and the bench build all use **`ReleaseSafe`**. No
  ship/gate path builds `ReleaseFast`. (The gate asserts the mode; today it builds Debug and ships
  ReleaseFast — this is the explicit **gate-mode fix**.)
- **AC-a2 [gate]** — Cold-start `<500 ms` (launch → first rows) holds with the shipped `ReleaseSafe`
  binary (existing cold-open probes, ReleaseSafe).
- **AC-a3 [bench]** — The differential C-ABI scan bench reports the `ReleaseSafe`-vs-`ReleaseFast`
  throughput delta for the scan family (search / filter / count / deep-jump) on a fixed fixture, warm
  runs; recorded in the review.
- **AC-a4 [bench + gate]** — Every `@setRuntimeSafety(false)` carve-out is (i) justified by a recorded
  bench delta showing that specific loop misses budget in full `ReleaseSafe`, and (ii) listed in ONE
  named enumeration. The preferred outcome is **zero carve-outs**; any carve-out keeps cold-start [gate]
  and scan-throughput [bench] within budget.

**(b) #40 flate feed guard (backend)**
- **AC-b1 [gate]** — A gz stream truncated at each byte offset spanning a DEFLATE block (not only at
  member boundaries — the current regression test's restriction is lifted) is handled without crash/UB:
  each yields either correct-rows-so-far + a clean "damaged/truncated" classification, or a resume-when-
  more-bytes state.
- **AC-b2 [gate]** — The network partial-fetch path: a fetch stopping at a 256 KiB chunk boundary that
  lands mid-DEFLATE-symbol does not drive the inflater into `peekBitsEnding` underflow (driven via the
  net fake-fixture fault path); resolves as await-more-bytes or clean-damaged.
- **AC-b3 [fuzz]** — The gz corpus includes mid-symbol truncations from partial-fetch boundaries; zero
  crashes under `ReleaseSafe`.

**(c) Fuzz campaign (dev-tooling)**
- **AC-c1 [fuzz]** — A coverage-guided C-ABI fuzz harness exercises `ls_open` + window/search/copy + the
  gz inflater + the net-source reducer, built `ReleaseSafe`, seeded from the `csvgen` corpus +
  adversarial gz/truncation/wide/ragged seeds; the coverage report shows entry into the enumerated
  hotspot modules (`csv_reader`, `source`, `net_source`, `window`, `index`, `search`, `encoding`).
- **AC-c2 [fuzz]** — The campaign runs to a defined stopping criterion (time-boxed CPU-hours or
  coverage-plateau, recorded) and terminates with **zero un-triaged crashes / OOMs / hangs**. Any crash
  found is fixed and added as a regression seed to the corpus, then re-run clean.
- **AC-c3 [gate]** — The harness + corpus + campaign log are committed as a reproducible dev tool
  (buildable from a documented command). Not gate-blocking (one-time cadence).

**(d) gzip-bomb cap (backend + apps)**
- **AC-d1 [gate]** — A synthetic high-ratio gz trips the sliding-window ratio guard (single named
  const, floor ~100:1): further indexing stops, already-decompressed rows stay viewable, and an
  "abnormal expansion" trip state is exposed via the ABI.
- **AC-d2 [gate]** — A legit-ratio `.csv.gz` (text, ≤ ~20:1) never trips; the supported large-gz fixture
  opens and fully scans.
- **AC-d3 [bench]** — The ratio threshold is validated against real CSV compression ratios so no
  legitimate corpus file trips (recorded).
- **AC-d4 [gate, apps]** — macOS and GTK surface the trip as a non-blocking banner (reusing the scan-%/
  filter-banner language); the document stays interactive.

**(e) Network hardening (backend; apps surface errors)**
- **AC-e1 [gate]** — A server that accepts the connection then sends no bytes triggers the idle-read
  timeout (~30 s, named const) and surfaces a retryable network error; a non-responding connect triggers
  the connect timeout (~10 s, named const). The fetch thread/document is not hung.
- **AC-e2 [gate]** — A redirect whose `Location` downgrades `https→http` is refused with a distinct
  error; `http→https` and same-scheme (incl. cross-host) redirects within the 3-hop cap still succeed
  (driven via fixture redirect chains).
- **AC-e3 [gate]** — A range request answered with a short body (fewer bytes than requested) or a
  zero-length body produces a **retryable error** for that range; the un-fetched tail is NOT marked
  present and is NEVER served as zero bytes of document content (corrects the current silent zero-fill).

**(f) Copy formula-injection neutralization (backend `frameCell`; frozen `api/`; apps inherit)**
- **AC-f1 [gate]** — Any cell whose first byte is `=`, `+`, `-`, or `@` is emitted with a single leading
  `'` prefix in BOTH streaming copy (`ls_copy_next`) and single-cell copy (`ls_cell_copy`); orthogonal
  to TSV quoting (a quoted cell still gets the prefix on its value).
- **AC-f2 [gate]** — Cells not starting with those bytes are byte-identical to today (no
  over-neutralization); the prefix is applied exactly once (idempotent framing).
- **AC-f3 [gate, apps]** — macOS (`.tabularText`/`.string`) and GTK (`gdk_clipboard` text) clipboard
  payloads carry the neutralized bytes end-to-end (bridge tests over the real core).
- **AC-f4 [change-authority, not an ordinary gate test]** — The frozen `api/lesssheet.h` copy-output
  contract is updated by the **ROOT planner**, and the macOS AC23 guard baseline
  (`frozenCAbiHeaderHasEmptyDiff`, currently `df0436b6…`) is re-bumped **in the same freeze**. Verified
  by the guard staying green post-freeze against the new baseline.

**(g) SIGBUS / mmap-TOCTOU (backend; apps integration)**
- **AC-g1 [gate]** — A local file, mmap'd and opened, then truncated by another process, then accessed
  beyond the new EOF: the core catches `SIGBUS` within its own mapped region, recovers, and reports a
  clean "source truncated/faulted" error; the process does not crash.
- **AC-g2 [gate]** — The handler is **chained**: a `SIGBUS` from outside any core mmap region is
  re-raised to / passed through to the previously-installed handler. Installation is idempotent and
  region-scoped.
- **AC-g3 [gate, apps]** — With the handler installed, both frontend gates stay green (the host
  frontends' own signal/crash handling is not broken) — integration check.

**(h) Outlier-cap gaps (backend; apps surface the download cap)**
- **AC-h1 [gate]** — A record-1 declaring more than the column backstop (`> 2^20` columns, a single
  named const) is rejected with a clean error and no overflow/UB; `wide_100k_cols` (100 k columns,
  supported) still opens fully. This is a memory-safety backstop, not a product limit.
- **AC-h2 [gate]** — A network stream that keeps delivering bytes past the cumulative-spool ceiling
  (~2 GiB, single named tunable const) trips **cap + warn**: spooling stops, already-fetched rows stay
  viewable, a "stream exceeds size limit" state is surfaced; **local mmap documents are never subject to
  this cap** (driven via the net fixture).

### DEFERRED (post-launch — not built in this program)
- Control-character / RTL-override display sanitizing (bidi-spoofing).
- CI-integrated continuous fuzzing (the pre-launch campaign is one-time).
- Outlier-cap tightening beyond (h)'s two gaps.
- TLS `allow_truncation_attacks` strictness (accepted known risk for a public-data viewer; covered
  operationally by AC-e3's short-body handling).

## Sequencing note (for the planner / build orchestration)
- (f) requires a **root-planner `api/` freeze + AC23 re-bump** before its build cell — it is the one
  cross-component contract change and should be sequenced first among the api-touching items so (d)/(e)
  prose deltas can fold into the same freeze.
- (a)'s carve-out decision **depends on** the (a) `ReleaseSafe`-vs-`ReleaseFast` bench (AC-a3); run the
  measurement before deciding any `@setRuntimeSafety(false)`.
- (b) is a prerequisite for a clean (c) gz corpus (a known crash would mask campaign findings); fix (b)
  first, then seed it as an (c) regression case.
