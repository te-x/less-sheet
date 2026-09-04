# Contract Change Request — macOS launch performance / linkerSettings @ Package.swift:38-46

Signed:  [ ] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

DRAFTED, NOT APPLIED. Raised while optimizing cold launch; `Package.swift` is a
frozen path, so the change is described here rather than made. It is a WEAK
request: launch does not measurably benefit. It is filed because the same flag
halves the shipped binary and the decision belongs to whoever owns the manifest.

## Grounds (tick at least one)
- [ ] A. Infeasible within the current contract
- [x] B. Substantial, quantified improvement  (code-size only — NOT launch time)

## If B — improvement
- Dimension: code-size (download / disk); launch performance investigated and REJECTED
- Baseline (current contract):  release executable 5.4 MiB; launch median 187.5 ms
- Proposed:                     release executable 2.9 MiB; launch median 186.5 ms
- Magnitude:                    -46% executable size; launch unchanged within noise
- Evidence (how measured):
    Size: `swift build -c release` then `strip -x` on a COPY of the assembled
    bundle's executable, re-signed ad hoc (`codesign --force --sign -`), which is
    exactly what the linker flag below would produce. 5.4 MiB -> 2.9 MiB.
    `-Xlinker -dead_strip` was measured separately and changes NOTHING (5.4 MiB
    both ways): SwiftPM's release link already dead-strips.
    Launch: tools/bench/launch_bench_macos.sh's method, `open -n -a <bundle>` on
    ~/less-sheet-bench/c10-10KB.csv, reading the app's own
    `lesssheet.phase.first_row_pixels`; the two bundles interleaved A,B,A,B in one
    session, n=22 each. Medians 187.5 ms (unstripped) vs 186.5 ms (stripped);
    per-run spread is +-15 ms, so this is noise. The app-attributable segment
    (launch_event -> first_row_pixels) was 60.5 vs 58.0 ms — suggestive at best.
    The reason there is nothing to win: the number is measured from `main`, and
    everything a smaller binary saves (dyld, page-in, signature validation) is
    either before `main` or amortised over the whole run.
- Reviewer's independent check: <not yet re-run>

## Minimal change (as a diff)

```diff
         .executableTarget(
             name: "LessSheetApp",
-            dependencies: ["LessSheetKit", "Contracts"]
+            dependencies: ["LessSheetKit", "Contracts"],
+            linkerSettings: [
+                // Release only: drop local symbols. Halves the executable; Swift
+                // reflection lives in __swift5_* sections and is unaffected.
+                .unsafeFlags(["-Xlinker", "-x"], .when(configuration: .release))
+            ]
         ),
```

## Cost / blast radius
- Other contract items / tests / modules affected: none. The gate's debug build is
  untouched; `scripts/assemble-app.sh` re-signs after the link either way.
- Crash reports and `sample` output from a shipped build lose local symbol names,
  so a user-reported crash address becomes harder to read. That is the real cost,
  and it is the reason this is filed as a question rather than an obvious win.
- `.unsafeFlags` makes a package ineligible as a dependency of another package.
  Irrelevant here (this is a leaf executable) but the manifest owner should know;
  the existing `-L` flag already uses it.
- Changes EXTERNAL I/O?   [x] no    [ ] yes → this goes to the ARCHITECT, not the planner.
