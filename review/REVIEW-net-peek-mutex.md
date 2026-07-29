# REVIEW — `net_peek_mutex`: a Document-mutex-held read could wedge the UI thread forever

Decision record written by the orchestrator at convergence. Cell: native Opus-5 implementer ⇄ native
Opus-5 reviewer, 3 rounds. Branch `feat/kbdnav-a11y`, base `108dac1`. Closes reviewer finding 1 of
`review/REVIEW-net-close-hang.md`, which the signed ARCH amendment named as "one route remains
UNBOUNDED — OPEN SHIP-BLOCKER, its own cell".

## Outcome

**Reviewer verdict: closes on Finding 1 landing** (round 3). Gate re-run by the orchestrator on the
final tree: **PASS** — zig 0.16.0, native ReleaseSafe + aarch64/x86_64-linux-musl crosses,
`zig fmt --check` clean, `zig build test -Doptimize=ReleaseSafe` **273/273**, csvgen corpus **142/0**,
flat streaming RSS. `api/`, `tests/`, `contracts/` **byte-identical** — internal fix, no ABI change.

## What was wrong, and that it was real

`Cursor.peekHttp` caps its read by `limit`/`knownEnd`/`physical_limit` but — deliberately, per its own
comment — **never by the fetched extent**, so `ensureSlice` can drive the drain past the head. But
`windowSetFiltered` holds the Document mutex for its whole call. So a re-lex at the fetch frontier
could issue a blocking ranged GET while holding that mutex: the caller thread wedges inside
`ls_window_set`, and `ls_close` then blocks at `d.lock()` before it can cancel anything. The
`b69f765` cancel cannot help — the blocked thread is the caller's, not the task's.

Reproduced deterministically (orchestrator re-ran it independently on a clean ReleaseSafe lib):

```
unguarded 310a4ff:  bytes_scanned=262144, ls_window_set NEVER RETURNED, ls_close also wedged, EXIT=3
guarded:            bytes_scanned=261888, ls_window_set 0.007s, ls_close 0.001s, EXIT=0
```

**Two conditions made it hard to reproduce, and three earlier orchestrator probes reported a false
negative before they were understood:** the row width must divide `chunk_bytes` (256 KiB) so the
boundary row lands *mid*-commit-batch rather than inside the last 2048-row batch, and the peer must
answer **short-then-silent** — a purely silent peer blocks mid-batch and commits nothing. Harness:
`probe_mutex.c` + `two_phase.py`.

## The fix: frontier-commit side, not peek side

The obvious fix — clamp `peekHttp` to the chunk boundary as `spanHttp` already does — **was rejected
as unsafe.** A clamped peek hands the decoder a truncated window; `decodeUtf16Unit`'s deferral branch
is dead on the peek path (`streamUnit` passes `bytes.len` as `limit`), so an astral character
straddling the boundary becomes `U+FFFD U+FFFD`. Trading a hang for silent wrong data fails the
standing bar. A `frontier_pos` cursor clamp was also evaluated and rejected: it makes the last counted
row report `capped = true`, dropping it from a filtered view.

**Landed instead:** a row is committed only when `row_end + max_lookahead <= present_extent`, or
`row_end` is the source's genuine end (EOF exempt). One resolver
(`HttpRange.commitBound` / `commitBoundNoFetch`), three Source arms (random → present-prefix cache,
sequential → `seq_hw`, gzip → scoped out). `max_lookahead` became the single named constant consumed
by `Cursor.look`, `streamUnit`'s peek, `root.zig`, and the guard — no bare `peek(4)` remains.

**BONUS, and the strongest user-value argument for the cell:** the guard also cures an
**already-reachable** corruption. `ensureSlice` clamps to the contiguous present prefix on an ordinary
short fetch, so the decoder already receives truncated peeks today — meaning UTF-16 astral characters
at chunk boundaries corrupt to `U+FFFD U+FFFD` in served cell text on the pre-fix tree, with no
adversarial setup.

## Two off-by-ones, both caught

1. **A fourth commit site the reviewer's own list missed** — `index.headScan` is the document's
   *first* frontier write, and for a net doc `headBudget` is exactly one chunk, so an aligned row
   committed the frontier at 262144 **at open, before any scan ran**. Unguarded, the frozen-test
   fixture would have read 262144 regardless of the scan-loop work. Guarded with a **no-fetch** bound
   (the head must not pull a second chunk — a demanding bound would have *introduced* a second GET,
   since `peekHttp` already caps by `headSourceLimit`).
2. **BLOCKING: `need` had to be `max_lookahead` (4), not `max_lookahead - 1` (3)** — the reviewer's
   own round-1 constraint was off by one, and it owned the error. `finishTerminator` advances *past*
   a **bare CR** to `row_end`, then `streamUnit` peeks 4 bytes **at** `row_end`, so the deepest
   demanded byte is `row_end + 3`. Under `need = 3` a row ending at `extent - 3` still committed and
   its peek crossed into the absent chunk under the mutex — the wedge, still live on CR-terminated
   network documents. Verified independently by the orchestrator before relaying.
   **The repro probe is structurally blind to this**: with 256-byte aligned rows both `need` values
   withhold at the same row, so both print `1023 / 261888`. Code reading caught it; the probe could
   not have.

## Also landed

- **`navSearch` degraded-arm net gate** (`search.zig`): that loop calls `searchScanChunk` under the
  Document mutex and is *supposed* to touch absent bytes, so a commit-side guard structurally cannot
  help it — and the guard's demand would have made it worse. Gated like the two sibling degraded
  loops.
- **Corollary fix:** on a short fetch the bulk span walk left the frontier **mid-row** while counting
  only whole rows — an untruthful `(pos, rows)` pair *and* a second wedge route. Now always returns
  the last committable row boundary.

## Scope-out, recorded honestly

**Network gzip is NOT covered.** `Gzip.produce` calls `ensureCompressed(seek + chunk_bytes)`
unconditionally on every inflate op — a fixed 256 KiB *read-ahead*, not a read the row needs — so it
demands un-fetched chunks however far behind the frontier a mutex-held re-lex sits, and where the
frontier commits is irrelevant. Its fix is `produce`-side (demand-only `ensureCompressed` on replay
lanes) and belongs with `column.zig`'s mutex-held gzip-lane acquire (`waitUncancelable`) in a net-gz
cell. Deviation 2's mid-row frontier also stays uncured there (`commitGuarded` is false).
**AC-e1 is therefore closed for plain net CSV only** — corrected in the ARCH as a statement of fact.

## Deviation from the reviewer's constraints

The search/filter withhold reports `stalled = true` unconditionally rather than only on zero progress.
Forced: `commitSearch` appends exactly one `block_counts` entry per call against a block index of
`search_rows / checkpoint_interval`, so a re-entered partial chunk would double-append and misalign
block↔count — wrong nav positions, i.e. silent wrong data. Reviewer confirmed it is genuinely forced
and does not conflict with "withhold the row, never stall the scan": healthy documents cannot reach it
because `commitBound` demands on the caller's thread.

## Performance — no regression

Implementer's interleaved A,B,B,A median (500 MB, ReleaseSafe, M2 Pro warm): `search_scan` **+0.5%**,
`filter_scan` **+0.8%**, against an untouched `index_scan` control at **−0.1%** and within-variant
spread of ±1.0–1.7%. At/below the noise floor. 50 MB was *faster* on all four ops.

The orchestrator's independent single-shot run was **weaker and said so**: +0.7–1.4% on the guarded
ops, but the untouched `copy_rows` control moved **−3.2%** — more than any guarded delta — so that run
is noise-dominated and cannot resolve a sub-2% effect. Deferred to the interleaved measurement. Both
agree there is no meaningful regression. Round 3 (a threshold constant) adds zero instructions, so it
was not re-benched, explicitly rather than silently.

## Filed forward

- **Silent row-count DRIFT at span boundaries** (`csv_reader.zig`, spurious `skip_lf` after a CRLF
  pair ending exactly at a span end). The reviewer escalated it: not one dropped row, but the scan
  count and every checkpoint-anchored re-lex disagreeing by one **from that boundary onward**, so
  requesting row T serves file row T+k. Hits **local `.csv.gz`** as well as network. Ruled to its own
  cell **before this branch merges** — this is the silent-wrong-data class.
- **Frozen tests (planner, one bundled pass — all need the same CRLF/boundary `NetFixture`):**
  (a) guard invariant `bytes_scanned == 261888` (`short_body_at = 262144`, **256-byte rows** — the
  default 18-byte rows make it vacuous); (b) UTF-16LE astral char straddling 262144 served
  byte-exact; (c) the `need = 4` discriminator — 1023×256 B rows then a 253-byte row ending in a
  **bare `\r`** at 262140, asserting on the fake transport's `fetch_count` that **no mutex-held path
  increases it** (deterministic, and stronger than any timing-based freeze test); (d) the row-drift
  bug's lexer-vs-lexer count equality, net *and* local gz.
- Net-gz cell (scope-out above).

## Process notes

- Three orchestrator probes reported "no freeze" before the alignment conditions were understood. A
  negative probe result is not evidence of absence — the alignment self-check in the final probe
  exists precisely so a vacuous pass is visible.
- The reviewer's `fetch_count` invariant is a better lock than a timing-based freeze test: hermetic,
  deterministic, and it catches the case the timing probe is blind to.
