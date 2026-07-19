# REVIEW — backend: network open-head shrink (4 MiB → 256 KiB)

**Verdict: PASS (no findings).** Bound to tree-hash `549f59d1…`, trusted gate 257/257 + both
`-*-linux-musl` cross-compiles + generator 142/142. Cuts the network file open ~7.2 s → ~1.7 s (the
4 MiB head fetch at ~0.71 MB/s was ~5.9 s of it) by fetching + indexing only 256 KiB of head. Fixes both
frontends (shared core). Frozen RED-first (`net_open_head_small` + `nfd_ac2`) at freeze `b2dd4ca`.

## Structure — SINGLE SOURCE OF TRUTH (first-class, per the author's steer [[single-source-of-truth-knobs]])
- **SIZE = one constant:** `base.net_head_budget = 256 * 1024` (beside the unchanged
  `base.head_budget = api.open_head_max_bytes` = 4 MiB local). Changing the net head is this one line.
  The other `256*1024` literals in the tree are distinct knobs (`chunk_bytes`, `encoding_sample_bytes`,
  `sniff_byte_cap`) — reviewer-verified, not copies.
- **DECISION = one accessor:** `index.headBudget(doc) = if (doc.net) base.net_head_budget else head_budget`
  — the SOLE `doc.net` head-branch; both `headScan` (the `bytes_scanned <= budget` guard) and
  `headSourceLimit` (record-1 decode) read it. No per-site branch or re-derived budget anywhere.
- `net_source.zig` reads the SIZE directly (`open_bytes = base.net_head_budget`) — it's unconditionally
  the network transport (no `Document`), so it needs the size not the decision.

## Behavior
- **Net fetches + indexes ≤ 256 KiB** (one round-trip), both range (206) and sequential (200): the open
  prefetch AND `headScan` cap at the same constant; navigation never overshoots (`spanHttp` chunk-clamps
  each `ensureSlice` to one chunk). Confirmed by `net_open_head_small` (fetch + `bytes_scanned` ≤ 512 KiB)
  + `nfd_ac2` (`netFetchCount ≤ 9`).
- **Local byte-identical:** `doc.net == false` → `head_budget` = 4 MiB; `api.open_head_max_bytes`
  untouched → the exact-count corpus + the ABI determinism-pin ACs unchanged (no net-budget leak).
- No import-cycle hazard (`net_source` → `base` closes a loop, but `net_head_budget` is a comptime literal
  with no back-dependency; the build + cross-compiles prove it).

## Notes (non-blocking, recorded)
- **Coalescing dead-branch:** with a 1-chunk (256 KiB) net head, `ensureChunkRangeLocked`'s multi-chunk run
  is now unreachable by any public op (open ≤1 chunk, `byteAt` 1 byte, `spanHttp` chunk-clamped ⇒
  `first==last`). Left in place (still correct if a future caller requests a multi-chunk span, e.g. a larger
  head or read-ahead); a one-line "spans are currently single-chunk" comment recommended. Not a bug.
- **Column-inference transitive net-safety (LANDMINE for future work):** `column.zig` caps its head sample
  at `api.open_head_max_bytes` (4 MiB) and `do_column` is NOT net-gated — yet it doesn't over-fetch on a
  net open only because it's bounded first by `frontier_rows`, which for a net doc covers just the 256 KiB
  head (`headScan` stops there + `do_index` is net-gated off, so the frontier never auto-advances). This is
  correct today but EMERGENT, not an explicit `headBudget()` use. FOLLOW-UP (low-pri, a comment): note near
  `headBudget` that any future change letting the net frontier advance past the head must also net-bound
  column sampling, else it silently pulls up to 4 MiB over the wire.

## Gate / discipline
257/257 + both cross-compiles + generator. Scope: `src/base.zig` + `src/index.zig` + `src/net_source.zig`;
no `api/`/`contracts/`/`tests/`/`build.zig` drift. Real-host open latency = the author's desktop pass.
