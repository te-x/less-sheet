# ARCH — never-full-download-streaming (lazy, demand-driven network open for every format)

**Feature:** make a network open — plain CSV *and* `.csv.gz`, on range *and* no-range servers, of known *and*
unknown length — **never fully download the resource**. Bytes are fetched STRICTLY on demand: the head at
open (columns / types / first viewport / copy the first N rows), a viewport + small buffer on scroll, up to
the next match on search, and a deep jump only when the user asks — with **no background network scan of any
kind**. Opening a 100 GB `.csv.gz` on a server to inspect its columns must fetch a few MB, not the file.
Decisions in this document were made interactively with the author on 2026-07-15.

This is a correction and generalization of the shipped `network-source` slice (`ARCH-network-source.md`),
built on the `Source` / `Cursor` seam (`ARCH-reader-interface.md`) and the checkpointed gzip Source
(`ARCH-csv-gz.md`). It touches the frozen `api/lesssheet.h` in exactly three **documentation / sentinel**
ways (byte-identical struct/enum/signature layout — the two-key root-planner amendment enumerated under
*Contract surface*, signed off by the author 2026-07-15). Every local-file behavior stays byte-identical.

## Problem & scope

The product thesis (`PROJECT.md`): *open is O(viewport), not O(file); a 10 GB file opens as fast as a 10 KB
one.* the author, verbatim (2026-07-15): **"I never want full download for any file type, that defeats the
purpose of this app."** The shipped network open violates this in two of three cases, and — more subtly —
in the third:

| Case | Server | Today | Verdict |
|------|--------|-------|---------|
| plain CSV | range (206/Content-Range) | `buildRandom` → `http_range` Source, ranged fetch on demand | streams, but the AUTO background indexer eagerly ranges the **whole file** to firm the row count → over-fetch |
| plain CSV | no-range (200) | `buildDownloadAll` → whole resource → `mmap` | FULL download; also **broken over real no-range servers** (a fresh ranged GET per 256 KiB chunk; a server that ignores `Range` returns `200` with the whole body from offset 0, so every chunk reads bytes `[0,len)`) |
| `.csv.gz` | any | `decideProbe` forces `range=false` (`net_source.zig:107`) → `buildDownloadAll` → whole resource → gzip over the complete mapping | FULL download |

The saturation culprit common to all three is precise: `index.zig:115`,
`do_index = … and doc.auto and !doc.complete` — the AUTO background indexer that advances the frontier to
EOF. `buildDocument` spawns `workerMain` for **every** source kind, so even the "good" range case
background-downloads the whole remote file to build the index.

**In scope**
- A **lazy, demand-driven** network access model for *all* network sources (range and stream): the AUTO
  background frontier indexer, the filter-scan auto-drive-to-completion, and the search match-scan's
  drive-to-EOF are all suppressed for a network source. The frontier advances only on concrete demand.
- A **sequential fill** strategy inside the existing `http_range` Source (no new `Source` union variant),
  for no-range servers: ONE forward-draining GET into a growing spool prefix; backward reads hit the spool;
  a forward demand advances the download. Serves plain CSV over no-range servers and provides the compressed
  byte stream for gzip.
- **gzip composed over the growing spool** (`Gzip`-over-`http_range`): incremental inflate over
  compressed bytes fetched so far, reusing the existing checkpoint / replay / spill machinery unchanged.
  `buildDownloadAll` is deleted; `decideProbe`'s `range = !is_gz` force is dropped.
- **Unknown-length** streams (no `Content-Length`, `Transfer-Encoding: chunked`, or `206` without a usable
  `Content-Range` total) handled first-class: a growing spool under a stable mapping, `knownEnd() == null`
  until EOF (as gzip already behaves), an `ls_scan_progress.bytes_total == UINT64_MAX` unknown-total
  sentinel, and a discovered-rows lower-bound row count.
- CSV and `.csv.gz` are the only Readers exercised; the byte source stays format-agnostic (on-paper proof
  that a future Parquet / ODS Reader composes over it).
- The three documentation/sentinel `api/lesssheet.h` amendments (byte-identical layout) so the header stays
  truthful for every present and future frontend.

**Non-goals (this slice)**
- No Parquet / ODS Reader (on-paper only — they need random fill; see the proof).
- No new authentication, no cross-open cache, no persistent spool — unchanged from `ARCH-network-source.md`.
- No wall-clock/latency guarantee for network operations (best-effort; see Non-functional).
- No louder post-open failure signal than "the document ends at the bytes received" (no ABI slot exists;
  deferred).
- No change to any **local** (mmap / gzip) behavior, timing, or `api/lesssheet.h` struct/enum/signature
  layout.

## Governing principle: lazy, demand-driven network access (the spine)

A network-sourced document fetches **only what a concrete user action needs, and never a byte more**. There
is no background network scan. The frontier advances solely through these demands:

- **Open** → the head only. The existing O(head) open bound (`LS_OPEN_HEAD_MAX_BYTES` = 4 MiB source, plus
  the dual 4 MiB inflated bound for gzip) is the whole open cost. Enough for the effective dialect, encoding,
  column count, header decision, the first viewport, and `ls_cell_copy` of the first rows. A small remote
  file that fits the head is fully fetched → exact count + `complete` at open (the determinism pin holds); a
  100 GB one fetches a few MB.
- **Scroll** → the viewport + a small scroll buffer. When the viewport reaches the frontier the frontend
  issues a short `ls_jump_start` toward `bottom_visible_row + buffer`, which advances the frontier by a
  bounded fetch (brief "loading rows" progress), then re-issues `ls_window_set`. Never a drive to EOF.
- **Search** → up to the next match, then STOP. `ls_search_start` launches no match-scan; each
  `ls_search_nav` advances only to the next match (fetching on demand, with `ls_search_status.progress`),
  then the search parks at `LS_SEARCH_CANCELLED`. "Next" resumes it. The full match total M is never
  computed in the background.
- **Deep jump / wrap-to-start / find-last** → pay-on-demand, only on the user's explicit request, with
  visible progress and Cancel (which freezes the frontier at its gains; the frontend restores the prior
  viewport). A range-server plain CSV still lands near-target cheaply; a stream / gzip is inherently linear
  (fetch + inflate to the target).
- **Fetch-free by construction**: `ls_window_set`, column inference, and `ls_cell_copy` never fetch — they
  serve rows behind the frontier (already fetched to the spool; a RAM-cache miss reads the spool from disk,
  never the network). A copy of a row at/beyond the frontier returns `LS_COPY_PENDING`; the frontend jumps
  first. Column inference samples only the head + already-materialized windows.

### Best-effort network / strict local

the author, verbatim: *"strict timings for local csvs, best effort for everything regarding network."* The lazy
gate keys on **source kind**, so:

- **Local (mmap / gzip)** — byte-identical: the AUTO background indexer still runs, and every strict local
  budget holds and is regression-guarded: cold start < 500 ms, backward landing < 100 ms, window / search /
  filter throughput and steady RSS within their existing bounds.
- **Network** — carries **no** wall-clock / latency acceptance criterion. Its criteria are **correctness**
  and **fetch-minimality** (`netFetchCount` / bytes bounded to what the demand needs), never speed. A
  first-time fetch of never-before-seen bytes is latency-unbounded by design and only ever happens from an
  async, progress-polled, cancellable path.

## Exact access model

`http_range` gains a second **fill strategy**; it stays the single network `Source` union variant (no
churn to the `Cursor`'s exhaustive `switch`es). The strategy is internal state resolved once at open by the
probe:

| Fill | Server | Mechanism | Access invariant |
|------|--------|-----------|-------------------|
| `random` (existing) | 206 + `Content-Range` total | ranged GET per 256 KiB chunk into a presized spool; `present[]` bitmap | any `[start,end)`; backward/forward both direct |
| `sequential` (new) | 200, or 206 w/o usable total, or no `Content-Length` | ONE forward-draining GET; body consumed into a **contiguous** growing spool prefix; a forward demand beyond the download high-water drains more | forward-contiguous (extend the prefix) or backward-into-present; never a mid-file hole fetch — guaranteed by the reader's sequential-forward + backward-into-fetched access |

Both fills present the identical Source surface (`peek` / `span` / `ensureSlice` / `logicalLen` /
`knownEnd`) to the `Cursor`; only the "fill a not-yet-present range" step differs. The RAM chunk cache,
spool-file idiom (0600, unlinked immediately), and never-re-fetch guarantee are unchanged.

**gzip composition.** `Gzip` is composed on top of the network byte source instead of a complete mmap:
- `Gzip` gains an optional **compressed provider** (the `http_range`). Before the inflater advances past the
  present compressed high-water it calls the provider's `ensureSlice(seek, want)` to fetch the next
  compressed chunk (random fill = a ranged GET in inflater order; sequential fill = drain the body forward).
  Backward compressed seeks (checkpoint replay) only ever touch already-fetched compressed bytes.
- `Gzip`'s notion of the **physical end** comes from the provider — a present-bytes high-water is a
  resumable `.budget` stop (the *exact* mechanism already used today for the open-head bound,
  `f.init(mapping, @min(mapping.len, open_bytes))` + `finishOpen` lifting `input.end`); a
  provider stream-end signal is the clean / damaged terminal. `mapping.len` is no longer the end for a
  network gzip. For a **local** file the provider is null and `mapping.len` is the end (byte-identical).
- The checkpoint / replay / spill / member / integrity machinery is untouched — it operates on the spool
  slice, which the provider guarantees is present before it is read. This realizes `ARCH-network-source.md`
  AC1's on-paper "a gzip Source wrapping an http_range span."

**Three byte measures** (mirroring `ARCH-csv-gz.md` / `ARCH-network-source.md`): *remote bytes* (offsets the
server understands), *local spool bytes* (fetched ranges mirrored 1:1 to the private spool — the axis
behind-frontier reads resolve against, never the network), and *served UTF-8 bytes* (unchanged cell output).
For gzip the compressed spool bytes and the inflated logical bytes are the two distinct coordinate systems
`ARCH-csv-gz.md` already defines.

### The lazy frontier (background-scan suppression) — internal seam

A `net` (demand-driven) flag on the `Document`, set for any `http_range` source, gates the worker
(`index.zig` `workerMain`) — **local is byte-identical because the flag is false for mmap/gzip-local**:

- `do_index` (the AUTO frontier indexer, `index.zig:115`) is forced **false** for a `net` doc. Nothing
  advances the frontier over the wire in the background.
- The filter-scan's AUTO drive-to-completion clause (`filter_state == .cancelled and doc.auto`,
  `index.zig:109`) is gated off for a `net` doc. A network filter advances only while serving a demand
  (first screen of matches / a filtered jump), then parks `LS_FILTER_CANCELLED` (mode persists; view stays
  filtered; counts firm only as the user navigates).
- The search match-scan is demand-bounded for a `net` doc: `ls_search_start` starts no scan; each
  `ls_search_nav` scans forward only to the next match then parks `LS_SEARCH_CANCELLED`; "Next" resumes —
  reusing the existing CANCELLED→resume state machine verbatim (**no new states**). `total_exact` becomes
  true only if a nav genuinely reaches EOF.

The frontier still advances only through demand jumps, search navs, and filter demands — all on the async,
progress-polled, cancellable paths, never the "never blocks" window lane.

### Unknown-length streaming

- **Spool.** Cannot be presized. The spool file grows by `ftruncate` under a **stable, generous virtual
  reservation** so the mapping base never moves and outstanding spool slices (handed transiently to the
  lexer mid-operation) never dangle; access never touches beyond the ftruncated size. (A remap-on-growth
  would be a use-after-free — this invariant is load-bearing.)
- **End knowledge.** `knownEnd()` returns `null` until stream EOF — exactly as `gzip.terminalLogical()`
  behaves today — so the reader's existing end vocabulary (`sourceEndAt` → `.inflating` when
  `knownEnd()==null`) already covers it. At EOF the end is fixed (clean, or damaged on a mid-stream drop).
- **Probe.** `Probe` / `decideProbe` gain an internal `length_known` bit to distinguish
  `Content-Length: 0` (a genuinely empty resource) from an absent length (unknown-length stream) — today
  both collapse to `total = 0`. (Internal; unit-tested — not ABI.)

## Inputs / Outputs / Error cases

- **Open ABI (`ls_open_url_*`) unchanged.** Known length → `progress`/`bytes_total` as today. Unknown length
  → the existing `LS_NET_PROGRESS_UNKNOWN` + `bytes_total = 0` open-job slots (they exist for exactly this).
  At `LS_NET_OPEN_DONE`, `bytes_fetched` reports the actual head bytes and `bytes_total` the known total or
  0 (not today's `publish()` white lie of `fetched = total = file_size`, which for a streaming doc would
  falsely imply a full download); `progress = 1.0` still means "open complete," not "downloaded."
- **Error taxonomy unchanged** (`ls_net_status`): scheme / option → `INVALID_ARGUMENT`; DNS/TCP/TLS →
  `UNREACHABLE`; stall → `TIMEOUT`; non-2xx → `HTTP_STATUS` (+ numeric); redirects → `TOO_MANY_REDIRECTS`;
  spool create/write → `IO`; cancel → `CANCELLED`.
- **Post-open stream drop.** A stream that drops or stalls mid-demand-fetch **terminates the document at the
  bytes received**, the gzip damaged-EOF analog: the rows that arrived are servable, index / search / filter
  reach their normal terminal states over the received prefix, and `ls_index_poll` reports
  `{received, received, true}` (or the unknown-total sentinel collapses to the received size). No louder
  signal (no ABI slot; deferred). Real-host drop behavior is a human probe.
- **Cancellation** (`ls_net_open_cancel` at open; `ls_jump_cancel` / `ls_search_cancel` post-open) stops the
  fetch at its next bounded chunk boundary and releases all resources (spool included); no dangling `ls_doc`.

## Functional requirements

**Core — `backend/src/net_source.zig`**
1. `HttpRange` gains a `sequential` fill strategy alongside `random` (keyed by `range_mode`). `ensureSlice`
   / `ensureChunkLocked` for sequential: serve a present (contiguous-prefix) range directly; a forward
   demand beyond the download high-water drains the single body reader forward into the spool (advancing the
   high-water); a mid-file hole is never requested (invariant above). `random` fill is unchanged.
2. Unknown-length spool: grow by `ftruncate` under a stable reservation; `total` unknown until EOF;
   `logicalLen()` reports the current known extent; `knownEnd()` is `null` until the body reader signals EOF,
   then the final size.
3. `Transport` gains a **sequential body reader** (real): ONE GET whose response body is drained forward
   across chunk reads (the connection is *not* re-opened per chunk — fixing the current per-chunk re-GET
   bug). The `fake` transport gains sequential + unknown-length + withhold-then-release behaviors for the
   gate (below).
4. `decideProbe` drops `range = !is_gz` (gzip no longer forces download-all) and gains `length_known`
   (empty vs unknown). `parseContentRangeTotal` + `decideProbe` are pure and unit-tested.
5. Delete `buildDownloadAll`. Its two cases become: no-range plain CSV → `http_range` sequential fill;
   `.csv.gz` → the gzip Source composed over the (random- or sequential-filled) `http_range` spool.
   `buildRandom` (range plain CSV) is unchanged.

**Core — `backend/src/source.zig`**
6. `Gzip` gains an optional compressed provider (`*HttpRange`), calls `ensureSlice` before advancing the
   inflater past the present compressed high-water, and derives its physical end from the provider
   (present high-water = resumable `.budget`; stream-end = clean/damaged terminal) rather than `mapping.len`.
   Local gzip passes a null provider — byte-identical. Checkpoint / replay / spill / member / integrity code
   is untouched.

**Core — `backend/src/index.zig`, `search.zig`, `filter.zig`, `open.zig`**
7. A `net` flag on the `Document` (set for `http_range` sources) forces `do_index` false and gates off the
   filter-scan AUTO drive and the search drive-to-EOF (the demand-bounded search above). `buildDocument`
   still spawns `workerMain` (jumps / searches / filters run on demand through it); it simply never runs the
   background frontier indexer for a `net` doc.
8. `rowCount`: known-total network keeps the existing free projection (`content_len × frontier_rows /
   scanned_data`, `exact=false`) — no fetch; unknown-total network returns `{frontier_rows, exact=false}` (a
   discovered-rows lower bound). Both firm only as the user navigates; `exact` true only if navigation
   reaches EOF.
9. `indexPoll`: `bytes_scanned` = frontier physical high-water; `bytes_total` = the known total, or
   `UINT64_MAX` for an unknown-length stream; `complete` true only when navigation has reached EOF (or a
   small file was fully fetched at open).

**Frontend — macOS**
10. On a network document, scrolling the viewport to/through the frontier issues a short `ls_jump_start`
    toward `bottom_visible + buffer` (brief "loading rows" affordance, reusing `JumpControlView`), then
    re-windows. No new surface beyond this flash.
11. Deep jump, wrap-to-start, and find-last on a network document run as explicit on-demand scans with the
    existing progress + Cancel affordance (Cancel restores the prior viewport; frontier gains kept).
12. Row-count / index display: `~N rows` for a known-total network doc (projection), `≥N rows` for an
    unknown-total one, with indeterminate scan feedback on the `bytes_total == UINT64_MAX` sentinel — reusing
    the open-job UNKNOWN affordance. Search shows "match N" + count-so-far + "more may exist" while
    `total_exact` is false; "Next" resumes.

## Non-functional constraints

- **Local strict, network best-effort.** Local budgets (cold start < 500 ms, landing < 100 ms, throughput /
  RSS bounds) are unchanged and regression-guarded; the lazy gate keys on source kind. Network operations
  carry no latency AC — only correctness + fetch-minimality.
- **No full download, ever.** Opening and inspecting a document fetches only the head; no background scan
  grows the fetched set. Reaching EOF only happens if the user explicitly navigates there.
- **Memory.** Network resident RAM stays bounded: the `http_range` compressed RAM cache within its ceiling
  (kept modest — the OS page cache backs the spool mmap), plus, for network gzip, the gzip Source's ≤ 16 MiB
  decompressed-side budget. The spool is disk-resident, grows only as the frontier advances, and is never
  O(file) in RAM. Steady RSS is not proportional to resource size.
- **Read-only, private, ephemeral.** Remote resource only ever GET; spool mode 0600, unlinked immediately,
  gone after `ls_close` / process exit; no cross-open reuse.
- **Dependencies & size.** Zig std only (`std.http.Client` / `std.crypto.tls`); single-digit-MB app.
- **Frozen boundary.** `api/lesssheet.h` struct/enum/signature layout is byte-identical (see Contract
  surface); the root integrity gate passes.

## Contract surface / ABI change

**`api/lesssheet.h` — three documentation/sentinel amendments; struct/enum/signature layout BYTE-IDENTICAL;
two-key root-planner freeze; the author's sign-off relayed 2026-07-15.** (The header must stay truthful for every
frontend, including future Linux / TUI, so the network carve-outs are documented, not left implicit.)

1. **Unknown-total sentinel.** `ls_scan_progress.bytes_total == UINT64_MAX` means "unknown-length network
   stream, total not yet known" (`complete` stays false; `bytes_scanned` is the fetched/indexed high-water;
   at stream EOF `bytes_total` becomes the final size and `complete` follows the normal rule). Mirrors the
   existing `LS_NO_ROW` / `LS_NET_PROGRESS_UNKNOWN` sentinel style; disambiguates from the empty-file
   `{0,0,true}`. A named constant (e.g. `LS_BYTES_TOTAL_UNKNOWN`) is the planner's call.
2. **Network demand-driven carve-out** (NETWORK block): under `LS_INDEX_AUTO`, a network-sourced document
   does NOT background-advance the frontier over the wire; the frontier advances only via viewport jumps,
   searches, and filters. `ls_row_count` is a converging lower bound (unknown-total) or a free projection
   (known-total) that firms only as the user navigates; `ls_index_poll.complete` / `ls_row_count.exact`
   become true only if navigation reaches EOF (or a small resource was fully fetched at open).
3. **Network search demand-bounded** (SEARCH / NETWORK block): on a network source the match-scan advances
   only to serve a navigation and then parks (`LS_SEARCH_CANCELLED`); `total` is the count over the scanned
   prefix; `total_exact` becomes true only if a navigation reaches EOF; the full match total M is never
   computed in the background.

**`backend/contracts/api.zig` — backend-planner freeze (not the C ABI):** `NetFixture` gains sequential /
unknown-length / withhold-then-release fields; `NetRangeMode.sequential_fallback` is re-documented as
*streamed, not downloaded*; `decideProbe` / `parseContentRangeTotal` are exposed for unit tests; the existing
`netFetchCount` / `netResidentBytes` / `netForceCacheBytes` / `netSpoolStore` seams carry the
fetch-minimality proofs. No `Source` union variant or transport vtable is exposed (the af83db9 ownership
boundary holds).

## Component decomposition & data flow

**Changed backend:** `net_source.zig` (sequential fill, unknown-length spool, sequential transport,
`decideProbe`/`length_known`, delete `buildDownloadAll`), `source.zig` (`Gzip` compressed provider + physical
end from the provider), `index.zig` (`net` flag gates `do_index` + filter/search auto-drive; row-count /
index-poll sentinel + lower bound), `search.zig` / `filter.zig` (demand-bounded via CANCELLED-resume),
`open.zig` / `net.zig` (route gzip + no-range plain to the streaming builders; set the `net` flag; honest
DONE bytes), `root.zig` (net instrumentation seams).

**Reused unchanged:** `csv_reader.zig`, `lexer.zig`, `matcher.zig`, `window.zig`, `nav.zig`, `encoding.zig`,
`sniff.zig` — all already operate through the `Source` / `Cursor` / `Reader` seams with opaque positions and
never inspect where bytes came from.

```text
URL + options
   └─ ls_open_url_start ─ probe (one GET) ─ decideProbe(status, content_length, content_range_total, is_gz)
        ├─ 206 + Content-Range total ───────────────► http_range  RANDOM fill  (known total)
        ├─ 200 + Content-Length ────────────────────► http_range  SEQUENTIAL fill (known total)
        └─ 200 no length / 206 no total / chunked ──► http_range  SEQUENTIAL fill (UNKNOWN total)
                                                          │
                        1f 8b magic on the fetched head? ─┤
                                                          ├─ no  ─► CSV Reader reads the spool directly
                                                          └─ yes ─► Gzip Source (compressed provider = the
                                                                     http_range) → CSV Reader reads inflated
                                                          │
                                       head only → dialect / encoding / columns / first viewport / copy-first-N
                                                          │
                                       ls_net_open_poll → DONE → ls_doc  (identical accessor surface)
```

```text
demand (jump / search-nav / filter / scroll-past-frontier)   [never ls_window_set / cell / copy]
   └─ advance frontier ─ Cursor.peek/span ─ ensureSlice(range)
        ├─ present in spool? ─ yes ─► read (RAM cache or disk; NO network)
        └─ no ─► RANDOM: ranged GET │ SEQUENTIAL: drain body forward   (progress-polled, cancellable)
                   └─ persist to spool → advance high-water → return
   (gzip: ensureSlice fetches COMPRESSED bytes; the inflater then produces; backward = checkpoint replay
    into already-fetched compressed bytes, zero new fetch)
NO background loop advances the frontier for a network doc.
```

## On-paper proof: Parquet & ODS over the same byte source (Acceptance Criterion)

The spool + fill byte source is format-agnostic; the fill strategy (random / sequential) is orthogonal to the
Reader (CSV / gzip / future Parquet / ODS).

- **Parquet** is footer-first: read `[len-N, len)` for the footer (offsets/schema), then `[start,end)`
  per column chunk. These are arbitrary ranges → the **random** fill (range server) serves them exactly as
  `ARCH-network-source.md` AC1 proved for the `http_range` Source; each range is spooled and never
  re-fetched, and under the lazy spine nothing pre-fetches beyond the ranges the reader asks for. **No
  Source/interface change.**
- **ODS** (ZIP-of-XML): a tail range for the central directory, then one range per worksheet entry, each
  optionally wrapped by a DEFLATE Source — the same composition as gzip-over-`http_range` here. **No
  Source/interface change.**
- **No-range degradation is inherent, not a seam defect.** Footer-first formats need random access; over a
  no-range server the sequential fill can only reach the tail by draining forward (a deep, on-demand,
  progress+Cancel scan — consistent with the deep-jump principle). CSV's top-to-bottom access is the
  degenerate sequential case of the same "ask for any `[start,end)`" primitive, proving the shape is general.

This cycle ships CSV + `.csv.gz` streaming only; Parquet / ODS are proven-compatible on paper (their Readers
are separate future interviews).

## Acceptance criteria (each testable; "fake" = hermetic fake transport in the gate; "unit" = pure unit test; "probe" = human real-host)

1. **Frozen boundary + amendments.** `api/lesssheet.h` struct/enum/signature layout is byte-identical
   before/after; exactly the three documented amendments (unknown-total sentinel; network demand-driven
   carve-out; network search demand-bounded) appear. The root integrity gate passes. (root gate)
2. **No full download — plain CSV, no-range.** Opening a no-range fixture fetches only the head
   (`netFetchCount` bounded to head chunks); the first window is servable; the whole body is NOT fetched.
   `netRangeMode == sequential`. (fake)
3. **No full download — `.csv.gz`, any server.** Opening a gzip fixture fetches only enough compressed bytes
   for the dual 4 MiB head bound (`netFetchCount` bounded); the whole compressed body is NOT fetched; a
   high-expansion small-compressed gzip is not fully inflated at open. (fake)
4. **No background growth (anti-saturation headline).** After open with NO navigation, `netFetchCount` and
   the frontier are unchanged across a poll–wait–poll; `ls_index_poll.complete` stays false and
   `ls_row_count.exact` stays false for a large fixture. Holds for range, sequential, and gzip network docs.
   (fake)
5. **Scroll = viewport + buffer.** A scroll-driven `ls_jump_start` advances the frontier by a bounded amount
   (`netFetchCount` grows by ~one buffer per screen), never to EOF; the newly visible rows are correct. (fake)
6. **Search = up to next match.** A find fetches only up to the next match (`netFetchCount` bounded to the
   match's byte offset), then parks `LS_SEARCH_CANCELLED`; the found match has an exact `position` over the
   scanned prefix with `total == position` and `total_exact == false`; "Next" resumes and advances. (fake)
7. **Deep jump pay-on-demand + Cancel.** A jump to a far row fetches toward it with visible progress;
   `ls_jump_cancel` stops the fetch within one chunk boundary, the frontier freezes at its gains, and no
   further bytes are fetched. (fake)
8. **Wrap / find-last pay-on-demand.** Wrap-to-start / find-last runs as an explicit on-demand scan with
   progress + Cancel (not eager); when uncancelled it reaches the correct terminal match. (fake)
9. **Range-server plain CSV non-regression.** Case 1 stays random-access (`netRangeMode == random`); a jump
   near EOF lands without fetching the whole file; the ONLY behavior change is the suppressed background
   indexer (row count firms on demand, not in the background). (fake)
10. **gzip composition equivalence + bounded replay.** `.csv.gz` over range and no-range both open via the
    gzip Source over the growing spool and produce byte-identical dialect / rows / counts / source-rows /
    truncation flags to the equivalent local `.csv.gz` for any fetched region; a backward landing restores
    the nearest checkpoint and replays only into already-fetched compressed bytes with **zero** new network
    fetch. (fake)
11. **Known-total sequential streaming.** A no-range `200 + Content-Length` plain CSV streams sequentially;
    `ls_index_poll.bytes_total` equals the known total; `ls_row_count` is the free projection
    (`exact=false`). (fake)
12. **Unknown-length streaming.** A `200` with no `Content-Length` (and a chunked-style fixture) opens and
    streams: the open job reports `progress == LS_NET_PROGRESS_UNKNOWN` / `bytes_total == 0`;
    `ls_index_poll.bytes_total == UINT64_MAX` with `complete == false`; `ls_row_count` is a discovered-rows
    lower bound (`exact=false`). Navigating to EOF makes `bytes_total` the final size, `complete == true`,
    and the count exact. A `Content-Length: 0` resource opens as the empty document (distinguished from
    unknown). (fake)
13. **Withhold-then-release (frontier waits then advances).** With bytes withheld, a demand jump / search
    beyond the released prefix stays `SCANNING` with visible progress and fetches nothing past what is
    released; releasing more advances it to completion. (fake)
14. **Never-re-fetch under streaming.** After a range is fetched and the RAM cache is forced empty
    (`netForceCacheBytes(0)`), re-accessing it is served from the spool with zero new fetches
    (`netFetchCount` unchanged) — for random, sequential, and gzip-compressed spools. (fake)
15. **Sequential contiguity + backward-from-spool.** Sequential fill only extends the contiguous downloaded
    prefix or reads within it (no mid-file hole fetch); a backward landing reads the spool with zero network.
    (fake)
16. **Post-open stream drop.** A fixture that delivers a short/faulted body mid-demand terminates the
    document at the received bytes (gzip damaged-EOF analog): received rows are servable, index / search /
    filter reach terminal states, and `ls_index_poll` reports completion over the received prefix. (fake)
17. **decideProbe / parseContentRangeTotal units.** Hermetic unit tests: 206 + `Content-Range` total →
    random/known; 200 + `Content-Length` → sequential/known; 200 no length → sequential/unknown;
    `Content-Length: 0` → empty (not unknown); a gzip magic verdict no longer forces `range=false` /
    download-all. (unit)
18. **Determinism pin over the network.** A small remote resource that fits the head bound is fully fetched
    at open → exact count + `complete` immediately (both known and unknown length); a large one is not. (fake)
19. **Memory bound.** Across a sustained scroll/jump/search exercise against a large network fixture,
    `netResidentBytes` stays within the network Source's cache ceiling and (for gzip) the added ≤ 16 MiB
    decompressed budget; steady RSS does not grow with spool size (spool is disk-resident). (fake / instrumented)
20. **Spool hygiene incl. unknown-length growth.** The spool is mode 0600, unlinked immediately, and absent
    after close / process exit; the unknown-length spool grows by `ftruncate` under a stable mapping base and
    no outstanding spool slice dangles across a growth. (fake / instrumented)
21. **Local non-regression (strict).** Every existing local (mmap / gzip) test stays green; the AUTO
    background indexer still runs for local docs; local cold-start (< 500 ms) and landing (< 100 ms) probes
    and window/search/filter throughput are unregressed. The lazy gate provably keys on source kind. (existing suite + probes)
22. **Cancellation / cleanup.** Cancel mid-open and mid-demand-fetch releases all resources (spool included)
    with no dangling `ls_doc`; `ls_close` during a demand-fetch joins cleanly and unmaps once. (fake)
23. **On-paper future-formats proof.** The Parquet / ODS proof above is present and reviewed; if either would
    require a Source/interface change, this criterion fails and the shape is revised before implementation.
    (review)
24. **Dependencies, size, gates.** No new runtime dependency (`std.http.Client` / `std.crypto.tls` only); the
    assembled app stays single-digit MB; backend, macOS, and root gates pass. (gates)

## Technology decisions

- **TD1 — Lazy/demand-driven network is the spine.** Suppress the AUTO background frontier indexer (and the
  filter/search auto-drive) for ALL network sources, gated by a `net` flag keyed on source kind. No
  background network scan exists; the frontier advances only on concrete demand. Local is byte-identical.
- **TD2 — One `http_range` Source, two fill strategies.** Sequential fill is internal state, not a new
  `Source` union variant — least churn to the `Cursor`'s exhaustive switches; the RAM cache / spool / cache
  invariants are reused.
- **TD3 — Sequential fill = one forward-draining GET into a contiguous growing spool.** Forward-contiguous /
  backward-into-present invariant (guaranteed by the reader's access pattern) makes a single connection
  correct and fixes the shipped per-chunk re-GET bug over real no-range servers.
- **TD4 — gzip composed over the growing compressed spool.** Reuse the checkpoint / replay / spill machinery
  unchanged; generalize the existing `.budget` / `input.end` resumable stop from the open-head bound to the
  download high-water; delete `buildDownloadAll`; drop `decideProbe`'s `range = !is_gz`.
- **TD5 — Unknown-length is first-class.** Growing spool under a stable reservation (no remap, no dangling);
  `knownEnd() == null` until EOF (gzip-analogous); `bytes_total == UINT64_MAX` sentinel; discovered-rows
  lower-bound row count. A `length_known` probe bit splits empty from unknown.
- **TD6 — Known-total keeps the free projection; unknown-total uses a lower bound.** Neither fetches to
  produce the estimate.
- **TD7 — Search / filter demand-bounded via the existing CANCELLED-resume machinery.** No new job states.
- **TD8 — Best-effort network / strict local.** ACs split accordingly; network is judged by fetch-minimality
  (`netFetchCount`), not latency.
- **TD9 — ABI byte-identical layout.** Exactly three documentation/sentinel amendments (two-key), so the
  header stays truthful without breaking any compiled client.
- **TD10 — Post-open stream drop = terminate at bytes received** (gzip damaged-EOF analog); louder signal
  deferred (no ABI slot).
- **TD11 — Zig std only** (`std.http.Client`); no new dependency; single-digit-MB app.
- **TD12 — Testability via the extended fake transport** (sequential / unknown-length / withhold-then-release)
  with `netFetchCount` as the deterministic no-over-fetch signal, plus `decideProbe` / `parseContentRangeTotal`
  unit tests; real-host latency/failure remains a human probe.

## Open Questions

None. Every decision above was interactively reviewed and signed off by the author on 2026-07-15, including the
two-key `api/lesssheet.h` amendment (unknown-total sentinel + the two network demand-driven documentation
carve-outs).
