# REVIEW-1 — walking-skeleton (round 1)

Reviewer ran the root gate independently: **GATE: PASS** (api/ integrity + backend
`zig build`/`zig build test` + apps/macos conformance + 11 swift-testing tests, all green).
Green is necessary, not sufficient — findings below.

## Contract conformance
- No frozen-path drift: `git status` touches only implementer-owned files
  (`backend/src/`, `backend/build.zig`, `apps/macos/Sources/LessSheet{Kit,App}/`,
  `Bundle/`, `scripts/`). `api/lesssheet.h`, `backend/contracts|tests`,
  `apps/macos/Sources/Contracts|Tests|Package.swift` untouched.
- C ABI: exports match the header exactly (comptime pins in `contracts/api.zig` +
  the extern-linkage test both compile); the header is single-sourced via the
  checked-in symlink `Sources/CLessSheet/include/lesssheet.h`.
- Zig 0.16.0 idioms verified against `/opt/homebrew/opt/zig/lib/zig/std/`:
  `std.heap.smp_allocator` (heap.zig:353) and `posix.openatZ` (posix.zig:457) exist as used;
  unmanaged `ArrayList` usage is current-idiom. `zig version` = 0.16.0.
- Memory safety at the boundary: mmap is parsed then munmapped inside `ls_open`
  (cell text lives in an owned, unmoving-after-open store); Swift copies every cell
  (`String(decoding:)`, U+FFFD at the boundary) and `ls_close`s before returning —
  no borrowed pointer outlives the call. Zero-allocation accessors confirmed by code
  inspection and the frozen counting-allocator test.

## Non-functional constraints — MEASURED (release, Apple Silicon, 1,000,002,260-byte CSV)
| Constraint | Budget | Measured | Verdict |
|---|---|---|---|
| Core open + first-window (C probe, 3 runs) | < 50 ms | 7.95 / 5.26 / 4.63 ms | PASS |
| Core probe peak RSS (proves O(viewport)) | — | 1.7 MB | PASS |
| Cold start `open -a`, marker, 3 cold launches | < 500 ms | 236 / 165 / 177 ms → median 177 ms | PASS |
| App RSS after opening the 1 GB fixture | < 100 MB | ~91.4 MB (tiny-file baseline ~87.7 MB → file contributes ~4 MB) | PASS — close to budget; headroom is framework baseline, not file data |
| `.app` bundle size | single-digit MB | 280 KB | PASS |

## Findings

1. **[impl] BLOCKING — CLI path argument never renders (acceptance criterion 19; functional req. 1).**
   Measured, reproducible: launching with a path argument — both direct exec
   (`LessSheet.app/Contents/MacOS/LessSheet /tmp/lsprobe/tiny.csv`) and
   `open -n -a LessSheet.app --args /tmp/lsprobe/tiny.csv` (argv delivery confirmed via
   `ps -o command=`) — produces **no window at all** after 10 s, no timing marker, and
   `sample` shows the main thread idle in the AppKit run loop. The identical doc-launch
   (`open -a LessSheet.app tiny.csv`) works (window present, marker 187 ms). Likely cause:
   AppKit treats a bare non-`-` argv token as a launch-time document open and suppresses the
   default scene, so ContentView (and its `.task` hook in `AppUI.swift`) never attaches —
   chicken-and-egg. Consequence: criterion 19's "CLI arg path renders it" fails, and its
   "missing path shows the in-window error panel" is unreachable through any real user path
   (LaunchServices refuses unreadable/missing docs itself with error -5000 before the app runs).
   Solvable within the contract (UI shell is implementer-owned): e.g. route launch argv through
   an `NSApplicationDelegateAdaptor` (`application(_:open:)` / `applicationDidFinishLaunching`)
   into the same `model.open`, or otherwise guarantee scene materialization; re-verify with
   `open -n -a … --args <path>` emitting the marker.

2. **[impl] minor — argv filter picks up flag values.** `openLaunchArgumentIfPresent` takes the
   first argument not starting with `-`; a flag *value* (e.g. the `YES` of
   `-NSDocumentRevisionsDebugMode YES` under Xcode) would be treated as a document path and
   surface a spurious error panel. Fix together with finding 1.

3. **[impl] minor — marker timing fidelity.** `LaunchTiming.markFirstRowsVisible()` fires in
   `DocumentModel.apply()` at state-mutation time, not at the first rendered frame; the contract
   wording is "first frame that shows document data". At 177 ms median vs a 500 ms budget the
   1–2-frame undercount is immaterial for this slice, but tighten (e.g. hook the first post-data
   draw) before slice 2 turns this into an enforced budget.

4. **Observation (no action) — lone-CR terminator.** The lexer also treats a bare `\r` outside
   quotes as a record terminator; the pinned dialect defines only LF/CRLF and leaves lone CR
   undefined. Behavior is a reasonable superset; the planner may want to pin it in slice 3.

5. **Observation (no action) — degenerate record 1.** A file whose record 1 spans the whole file
   (no newline) is materialized entirely (contract defines the head to include all of record 1),
   and > 4 GiB of cell text would trip the `u32` `@intCast` on offsets. Contract-consistent;
   worth a bound in a later slice.

6. **Observation — RSS headroom.** 91.4 of 100 MB is consumed, ~87.7 MB of it SwiftUI/AppKit
   baseline. Slice 2 work should not assume spare memory budget.

## Criteria check (beyond "tests pass")
- 1–11 (backend): covered by frozen tests AND re-inspected in `src/root.zig` — quote-aware
  boundaries, `""` escape, CRLF/LF equivalence, BOM strip (incl. BOM-only file), head cap counts
  data rows not the header, truncate/pad on both header and headerless shapes, pinned numeric
  grammar (incl. `.5`, `5.`, signed exponents, rejections), empty file 0×0, three distinct error
  codes with directory→`io`, extern-linkage symbol proof, counting-allocator zero-alloc. Sound.
- 12–15 (Kit): frozen swift-testing suite runs against the real linked core; green.
- 16–18: measured above — PASS.
- 19: File›Open… and launch-with-file funnel correctly (doc-launch verified live); **CLI path
  and the error panel FAIL per finding 1**.

## Verdict
**FAIL** — finding 1 is blocking (`[impl]`, fix within the contract). Everything else is green
or advisory; the performance story is excellent (core open ~5 ms, cold start ~177 ms, 280 KB app).
