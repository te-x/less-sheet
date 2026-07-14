# ARCH — network-source (pluggable HTTP range-fetch byte Source)

**Feature:** open a CSV / `.csv.gz` served over HTTP(S) through the same document, Reader, window,
search, filter, navigation, and copy behavior as a local file — via a new **third Source kind**,
`http_range`, that sits beside the existing `mmap` and `gzip` Sources at the `reader-interface` seam
(`backend/src/source.zig`, commit `af83db9`). Decisions in this document were made interactively with
the author on 2026-07-14.

This is additive to the frozen `api/lesssheet.h`: a **new** entry-point family (`ls_open_url_*`)
parallel to (never replacing) `ls_open`. Every existing local-file behavior, symbol, and struct layout
is untouched.

## Problem & scope

`ls_open` assumes a byte-addressable, instantly-seekable local file (mmap). A URL is not that: bytes
must be fetched, fetch latency is unbounded and can stall or fail mid-transfer, and there is no "just
mmap it" shortcut. the author's explicit product requirement (2026-07-14) is that this must be **useful work
for future non-CSV formats** (Parquet, and — per today's roadmap change below — ODS), not a CSV-only
bolt-on. That rules out "sequential-download-to-temp-file-then-open," which only ever serves top-to-
bottom access: Parquet's footer-first / row-group access and ODS's ZIP-central-directory-then-per-entry
access both need **genuine, out-of-order byte-range reads**, not a monolithic prefix scan.

**In scope**
- A new `http_range` Source: fetches arbitrary `[start, end)` byte ranges on demand over HTTP(S) via
  `std.http.Client` (Zig 0.16 std — zero new runtime dependency), backed by a bounded in-RAM chunk cache
  **plus an unbounded local spool file** that persists every byte range ever fetched (see "Exact access
  model" below) so a byte, once fetched, is forever after served from local disk, never re-fetched over
  the network.
- Graceful, per-open detection: if the server advertises range support (a `206 Partial Content` /
  `Content-Range` response to a probe `Range` request) the Source runs in true random-access mode; if
  not (`200 OK` ignoring the `Range` header, or no `Content-Length`), it falls back to a full sequential
  download into the same local spool file, then opens that file exactly like a local `mmap` document —
  correct either way, just without early-view-before-full-download on non-range servers.
- A new **async, pollable, cancellable open-job** ABI family (`ls_open_url_start` / `_poll` / `_cancel` /
  `_release`), mirroring the existing `ls_jump_start`/`_poll`/`_cancel` idiom, because a network open is
  never instant and must never silently stall.
- CSV and `.csv.gz` as the only Readers exercised over this Source in this slice (`.csv.gz` falls out for
  free: gzip detection is by magic bytes on whatever bytes the Source serves, network or local — see
  `ARCH-csv-gz.md`).
- macOS frontend: a **File → Open URL…** entry, an always-visible progress/Cancel affordance reusing
  `JumpControlView`'s determinate-%-plus-Cancel visual language (not gated behind the existing 500 ms
  `DelayedProgressIndicator` threshold — network latency is unpredictable even for a small file), the
  URL shown as-is in the window title, and no cold-start (`first_rows_visible_ms`) marker emitted for a
  network open (see Non-functional constraints).
- A design-note "on-paper" proof (Acceptance Criterion 1) that this exact Source shape serves Parquet's
  and ODS's access patterns unchanged — mirroring how `ARCH-reader-interface.md`'s AC5 acid-tested the
  original Source seam.

**Non-goals (this slice)**
- No Parquet or ODS Reader implementation (deferred to their own dedicated feature interviews, per
  `docs/architecture/BACKLOG-review.md`).
- No authentication (no credentials UI, no cookie jar — public URLs only).
- No persistent cache across opens or app restarts: re-opening the same URL always re-fetches from
  scratch. The local spool file is private to one live document and is unlinked immediately after
  creation (mirroring the existing `gzip` Source's checkpoint-spill file), so it never survives past
  `ls_close`/process exit.
- No application-imposed size cap on the download/spool — matches the existing csv-gz checkpoint-store
  precedent ("no application-imposed size cap and grows only as the frontier naturally advances"); the
  user's own Cancel is the only guard.
- No drag-and-drop URL entry, no "recent URLs" list, no window-title prettification (the URL is shown
  as-is) — all simplest-for-v1 choices consistent with "no caching, no staleness assumptions."
- No cold-start budget applies to a network open — the `first_rows_visible_ms` marker is not emitted at
  all for one (see Non-functional constraints for the rationale).
- No change to any existing local-file behavior, symbol, or the meaning of `ls_open`'s `path` argument.

## Exact access model (three Source kinds, their access patterns)

| Source   | Random access?                              | Mechanism                                             |
|----------|----------------------------------------------|--------------------------------------------------------|
| `mmap`   | True — any offset, zero-copy, instant         | page fault                                             |
| `gzip`   | Sequential-only, with **bounded replay**      | DEFLATE is inherently sequential; a jump backward past the checkpoint interval restores the nearest checkpoint and replays ≤ 32 MiB (see `ARCH-csv-gz.md` §6) |
| `http_range` (new) | **True** — any `[start, end)`, fetched once, cached forever after | ranged HTTP GET; once-fetched bytes persist in the local spool (disk-bound replay, not network-bound) |

`http_range` is therefore the **second genuinely random-access Source** (like `mmap`, unlike `gzip`) —
this is precisely the property that makes it reusable for Parquet's footer-first reads and ODS's
ZIP-central-directory-then-per-entry reads without inventing anything new at that layer: those Readers
just ask the Source for arbitrary ranges, exactly as the mmap Source already permits, and the Source
decides whether that range needs a fresh network fetch or is already on local disk.

Three byte measures, mirroring `ARCH-csv-gz.md`'s "Exact byte model" (the two documents share the same
axis-discipline):
- **Remote bytes** — offsets into the URL's resource, as the server understands them (`Range:
  bytes=start-end`, `Content-Range`, `Content-Length`).
- **Local spool bytes** — the same offsets, mirrored 1:1 into the private local spool file as they are
  fetched (sparse: only ranges actually requested are present). This is the axis behind-frontier reads
  resolve against — never the network.
- **Served UTF-8 bytes** — unchanged: CSV/`.csv.gz` cell output after quote removal, encoding conversion,
  and the existing `LS_CELL_MAX_BYTES` display cap. The CSV Reader is completely unaware its Source is
  remote.

The scan frontier concept already in `PROJECT.md` / `lesssheet.h` ("everything behind the scan frontier
is permanently instant") extends unchanged: for `http_range`, "behind the frontier" means "already
fetched at least once, therefore on local disk" — the existing jump-scan machinery (`ls_jump_start`)
is reused verbatim to advance the frontier, except that for this Source advancing the frontier means
issuing a ranged HTTP fetch instead of reading further into an mmap. No new frontier/index/jump concept
is introduced; only the frontier's *cost model* differs (network latency vs. a page fault).

## Inputs / Outputs / Error cases

### New ABI: `ls_open_url_*` (additive; `ls_open` is untouched)

A network open is never instant, so — unlike `ls_open` — it cannot be a single blocking call that
returns an `ls_doc`. It follows the existing async-job idiom (`ls_jump_start`/`_poll`/`_cancel`), plus an
explicit release call since (unlike a jump) the job handle is not owned by an existing document:

- `ls_open_url_start(url, url_len, options: ls_open_options) -> ls_net_open_job` — validates the URL
  scheme is `http` or `https` (anything else is a synchronous `LS_NET_ERROR_INVALID_ARGUMENT`, no network
  touched) and starts the fetch in the background. `options` is the *same* `ls_open_options` struct
  `ls_open` takes (forced separator/quote/header/encoding/index_mode) — a network document supports every
  existing dialect override.
- `ls_net_open_poll(job) -> ls_net_open_status` — zero-alloc, total, never blocks:
  - `state`: `PENDING` (probing range support) / `FETCHING` (head bytes in flight) / `DONE` / `FAILED` /
    `CANCELLED`.
  - `progress`: fraction in `[0,1]` of the head-fetch when `Content-Length` is known; a sentinel
    (`-1.0`) when unknown (frontend falls back to the indeterminate spinner + live byte counter, per
    the author's batch-1 answer).
  - `bytes_fetched` / `bytes_total` (`0` = unknown).
  - `doc`: a valid, fully-formed `ls_doc*` — usable through every existing accessor exactly like a local
    open — once `state == DONE`. Row-count/index/dialect semantics for that `doc` are otherwise
    IDENTICAL to a local open of the same bytes (e.g. the same O(head) determinism pin, measured against
    the fetched head rather than a mmap'd head).
  - `error`: an `ls_net_status` (below), valid only when `state == FAILED`.
- `ls_net_open_cancel(job)` — cancels an in-flight fetch (no-op once terminal); the fetch stops at its
  next bounded chunk boundary, exactly like `ls_close` stopping a gzip inflate.
- `ls_net_open_release(job)` — releases the job handle itself (idempotent); does **not** close the `doc`
  a `DONE` job produced — that follows the normal, independent `ls_close` lifecycle like any other
  document.

### `ls_net_status` (new enum; distinct from `ls_status` because network failures are a materially
different taxonomy from local file failures)

- `LS_NET_ERROR_INVALID_ARGUMENT` — URL scheme is not `http`/`https`, or an `ls_open_options` field is
  out of its documented domain (mirrors `ls_open`'s `LS_ERROR_INVALID_ARGUMENT`).
- `LS_NET_ERROR_UNREACHABLE` — DNS resolution or TCP/TLS connection failure.
- `LS_NET_ERROR_TIMEOUT` — no forward progress within the implementation's connect/read timeout.
- `LS_NET_ERROR_HTTP_STATUS` — the server returned a non-2xx status after following redirects (the
  numeric status is carried alongside for the frontend to render, e.g. "404 Not Found").
- `LS_NET_ERROR_TOO_MANY_REDIRECTS` — exceeded the fixed redirect cap (Zig std's built-in bounded
  `RedirectBehavior`; a small fixed constant, no user-facing configuration).
- `LS_NET_ERROR_IO` — local spool-file creation/write failure (mirrors `ls_open`'s `LS_ERROR_IO`; matches
  the existing csv-gz precedent that a spill-file failure degrades rather than silently corrupting state
  — here, since the spool is load-bearing (not merely a checkpoint optimization), its failure fails the
  open with this code).
- `LS_NET_ERROR_CANCELLED` — the job was cancelled before reaching `DONE`.

### Range-support probe & fallback (functional detail, not planner-frozen exact mechanics)

1. `ls_open_url_start` issues one `GET` with `Range: bytes=0-<head_bound-1>` (the same
   `LS_OPEN_HEAD_MAX_BYTES` bound `ls_open` already uses).
2. **`206 Partial Content` with a `Content-Range` total** → range support confirmed; `http_range` Source
   runs in true random-access mode for the document's lifetime.
3. **`200 OK`** (server ignored `Range`) **or** a `206`/`200` **without a usable `Content-Length`/
   `Content-Range` total** → treated identically: continue reading the already-open connection's body
   sequentially into the local spool file until EOF (no wasted extra request), then open that completed
   spool file exactly as a local `mmap` document. (A server that supports ranges but omits a total length
   is deliberately *not* special-cased — it is simplest and safest to fall back exactly as if it doesn't
   support ranges at all.)
4. **Non-2xx/206 status**, **redirect-cap exceeded**, or a **connect/DNS/TLS/timeout failure** → the open
   job fails with the corresponding `ls_net_status` and touches no local file.
5. Redirects are followed automatically up to Zig std's small fixed cap; there is no user-facing redirect
   configuration (explicit non-goal).

### Security posture (explicit, deliberate choices — not silent defaults)

- **Both `http://` and `https://` are allowed.** the author explicitly did not want an HTTPS-only
  restriction: the stated rationale is real-world use against local/LAN test servers that don't run TLS.
  This is a considered choice, not an oversight — flagged here precisely so it reads that way.
- **No authentication** — no credentials prompt, no cookie jar, no header injection beyond what `Range`/
  redirect-following require. A URL requiring auth surfaces as `LS_NET_ERROR_HTTP_STATUS` (401/403).
- **No URL scheme allowlist beyond `http`/`https`** — anything else (e.g. `file://`, `ftp://`) is rejected
  synchronously as `LS_NET_ERROR_INVALID_ARGUMENT`, never touched.
- No SSRF-style confirmation dialog: this is a local desktop viewer fetching a URL the user themselves
  typed, functionally identical to pasting it into a browser — a confirmation step would add friction
  without a credible corresponding threat model for this product.

## Functional requirements

**Core — `backend/src/source.zig`**
1. Add `SourceKind.http_range` (peer to `.mmap`/`.gzip`) with its own opaque state struct (mirroring how
   `Gzip` is a separate struct behind the `Source` union today): the `std.http.Client` connection(s), the
   bounded RAM chunk cache, the local spool file descriptor (opened, then `unlink`ed immediately — the
   exact idiom already used by the gzip Source's checkpoint spill file), and range-support/fallback state.
2. `Source.slice`/cursor operations for `http_range` serve **any** requested `[start, end)`: if fully
   present in the RAM cache or the local spool, return immediately (bounded local-disk cost, same landing
   budget the existing frontier guarantee already promises); otherwise issue a new ranged fetch, persist
   the result to the spool as it arrives, and only then return — this synchronous-from-the-Reader's-view
   call is what `ls_jump_start`'s asynchronous scan wraps for the window/index/nav lane, exactly as the
   gzip Source's checkpoint replay is wrapped today. A **first-time** fetch of a never-before-seen range
   is therefore latency-unbounded by design (matches "skip latency metrics — obviously more network
   dependent") and must only ever happen from an async, progress-polled, cancellable path (the jump-scan
   machinery, or the initial `ls_open_url_*` head fetch) — **never** from a caller documented as
   "zero-alloc, never blocks" (`ls_window_set`, `ls_cell`, etc.) touching genuinely new territory; those
   accessors' existing "may be estimate / not yet servable" behavior for beyond-frontier rows already
   covers this without any change.
3. RAM cache ceiling: **16 MiB** resident per open document (matching the existing gzip Source budget,
   for consistency, not a new number to justify independently), plus the local spool file (unbounded,
   grows only as the frontier advances, mode 0600, unlinked immediately — identical precedent to
   `ARCH-csv-gz.md`'s checkpoint store).
4. Fetch chunk granularity mirrors the gzip Source's existing `chunk_bytes` (256 KiB) for consistency
   with the rest of the codebase's tuning, not because HTTP requires it.

**Core — `backend/src/root.zig`**
5. New exported functions `ls_open_url_start` / `ls_net_open_poll` / `ls_net_open_cancel` /
   `ls_net_open_release`, implementing the job lifecycle above. Once a job reaches `DONE`, the resulting
   `ls_doc` is constructed through the *same* internal open path `ls_open` uses (dialect sniff, header
   rule, encoding detection, initial frontier) — just fed by an `http_range` Source's `openHead()`
   instead of an `mmap`'s. Every existing accessor, jump, search, and filter behaves identically
   regardless of Source kind (this is the whole point of the `reader-interface` seam).
6. `.csv.gz` over the network falls out with zero extra code: `root.zig`'s existing magic-byte check
   (`1f 8b`) runs against whatever bytes the `http_range` Source's `openHead()` returns, selecting the
   `gzip` Source **wrapping** the fetched/spooled bytes exactly as it does for a local file today.

**Frontend — macOS**
7. `Contracts/DocumentSession.swift`: add `DocumentSessionOpening.openURL(_:forcing:) async throws(NetworkOpenError) -> any DocumentSession`, alongside the existing `open(path:forcing:)` (additive, not replacing).
8. New `Contracts/NetworkOpenError.swift`: a distinct enum mirroring `ls_net_status` 1:1 (`invalidArgument`, `unreachable`, `timeout`, `httpStatus(Int)`, `tooManyRedirects`, `io`, `cancelled`), exactly as `DocumentOpenError` mirrors `ls_status`.
9. `AppUI.swift`: a new **File → Open URL…** menu item (shortcut **⌘⇧O** — ⌘O remains the local file panel) presenting a small sheet with a URL text field + Open/Cancel, funneling into a new `DocumentModel.openURL(_:)` parallel to the existing `open(path:forcing:)`.
10. Progress UI: an always-visible (no 500 ms gate) determinate-%-plus-Cancel affordance, visually reusing `JumpControlView`'s existing bar — driven by polling `ls_net_open_poll` (open phase) and, after open, the existing `jumpStatus()` polling loop already in place for any jump beyond the frontier (a network-Source "scan" is a jump-scan like any other; the UI does not need to know the difference). One combined progress presentation covers both phases, per the author's explicit pick.
11. Window title shows the URL as-is (no prettification, no filename extraction). No recents entry for a network open.
12. `LaunchTiming.markFirstRowsVisible()` is **not called** for a network-sourced open: the marker exists solely to gate/measure the local cold-start budget, which explicitly does not apply here (emitting an unmeasured, unbudgeted marker would be dead instrumentation, not a real signal) — a network open's own progress affordance is its "the user knows we're working" mechanism instead.

## Non-functional constraints

- **No cold-start budget applies.** A network open explicitly skips the <500 ms budget and its timing
  marker (requirement 12 above) — this is the author's literal instruction ("skip all latency metrics").
- **No silent stalls, still enforced.** Every phase of a network open — the initial head fetch and any
  later jump-scan that must reach never-before-fetched territory — shows visible, cancellable progress
  from the first moment (no threshold gate), per the author's batch-1 sign-off.
- **Memory:** `http_range` Source resident RAM state capped at 16 MiB per open document (matching the
  existing `gzip` Source budget); the local spool file is unbounded but disk-resident, mode 0600,
  unlinked immediately, and never survives past `ls_close`/process exit.
- **Dependencies & size:** Zig standard library only (`std.http.Client`, `std.crypto.tls` for HTTPS) — no
  new runtime dependency; the assembled app stays in its existing single-digit-MB budget.
- **Read-only & private:** identical guarantee to every other Source — the remote resource is never
  written to (only ever `GET`); the local spool is a private, ephemeral mirror of fetched bytes, never a
  persistent cache, never reused across opens.
- **Concurrency:** the job's background fetch thread(s) never block the caller's poll/control/window
  lane calls, mirroring the existing gzip Source's "background worker cannot evict a chunk leased by
  window/copy work" discipline.
- **Frozen boundary:** `api/lesssheet.h`'s EXISTING content (every symbol used by `ls_open` and its
  accessors) is byte-identical; this feature is purely additive (new functions/types only). The root
  integrity gate must still pass.

## Component decomposition & data flow

**Changed/new backend components**
- `backend/src/source.zig` — new `http_range` Source kind (§ Functional requirements 1–4).
- `backend/src/root.zig` — new `ls_open_url_start`/`_poll`/`_cancel`/`_release` exports (§ 5–6); reuses
  the existing internal open path unchanged for the CSV/gzip Readers.
- `api/lesssheet.h` — additive only: the four new functions, `ls_net_open_job`, `ls_net_open_status`,
  `ls_net_status`. Nothing existing is touched. **Frozen by the root planner; implementers on either side
  may not change existing entries.**

**Reused unchanged backend components**
- `backend/src/reader.zig`, `backend/src/csv_reader.zig`, `backend/src/lexer.zig`, `backend/src/matcher.zig`,
  `backend/src/window.zig`, `backend/src/index.zig`, `backend/src/nav.zig`, `backend/src/search.zig`,
  `backend/src/filter.zig`, `backend/src/encoding.zig`, `backend/src/sniff.zig` — every one of these
  already operates against the `Source`/`Reader` interfaces with opaque positions; none inspects "is this
  bytes-from-mmap or bytes-from-network." This is the direct payoff of the `reader-interface` reorg.

**New/changed macOS components**
- `Contracts/DocumentSession.swift` (new `openURL` protocol requirement), `Contracts/NetworkOpenError.swift`
  (new), `LessSheetKit/CoreDocumentSession.swift` / `CoreSessionOpener` (new URL-opening + poll-loop
  implementation), `LessSheetApp/AppUI.swift` (menu item + sheet), `LessSheetApp/DocumentModel.swift` /
  `ViewerModel.swift` (`openURL` funnel, parallel to `open(path:forcing:)`), a small new progress view
  reusing `JumpControlView`'s visual language, `LessSheetApp/LaunchTiming.swift` (no call site added for
  network opens — requirement 12).

### Open data flow

```text
URL + options
      │
      ▼
ls_open_url_start ──► ls_net_open_job
      │
      ▼
probe Range request
      │
      ├── 206 + Content-Range ──► http_range Source (true random access) ───┐
      │                                                                     │
      └── 200 / no usable length ──► sequential download → local spool ────┤
                                       (then opened as a local mmap doc)    │
                                                                            ▼
                                            encoding resolve → dialect sniff → CSV Reader
                                            (magic 1f 8b → gzip Source wraps the fetched bytes)
                                                                            │
                                                                            ▼
                                                       ls_net_open_poll → DONE → ls_doc
                                                       (identical accessor surface from here on)
```

### Behind-frontier range flow (http_range Source)

```text
requested byte range
      │
      ▼
present in RAM chunk cache? ──yes──► return (instant)
      │no
      ▼
present in local spool file? ──yes──► read from disk (bounded, landing-budget fast)
      │no
      ▼
NEW range: ranged HTTP GET (latency-unbounded by design)
      │
      ▼
persist to spool + RAM cache → return
(only reachable from an async, progress-polled, cancellable path — never a "never blocks" accessor)
```

## On-paper proof: Parquet & ODS over the same Source (Acceptance Criterion 1)

This mirrors `ARCH-reader-interface.md`'s AC5 acid test, applied to the network case specifically, per
the author's explicit request.

- **Parquet** is footer-first: the file's footer (row-group/column-chunk offsets, schema) sits at EOF.
  Over `http_range`, this is one `[len-N, len)` range request (once `len` is known from the initial probe's
  `Content-Range` total) — no different in kind from any other range request the Source already serves. A
  later column-chunk read is a `[start, end)` request against offsets recovered from the footer — again,
  nothing the Source hasn't already been asked to do for CSV's own scan-frontier reads. Every such range,
  once fetched, is spooled and never re-fetched. **No Source/interface change required.**
- **ODS / a ZIP-of-XML container** (per the roadmap change below, ODS is the planned future spreadsheet
  format): a ZIP's central directory also sits at/near EOF; each worksheet is a separate compressed ZIP
  entry at an offset the central directory reveals. Over `http_range` this is: one tail-range fetch for the
  central directory, then one range-per-entry fetch, each optionally wrapped by a `gzip`/DEFLATE Source
  the same way today's `.csv.gz` wraps an `http_range`-or-`mmap` byte span — a straightforward composition
  of Sources, not a new one. **No Source/interface change required.**
- Conversely, CSV's own top-to-bottom scan-frontier access is simply the *degenerate, sequential-only*
  case of the same general "ask the Source for any `[start, end)`" primitive — proving the shape is
  general rather than shaped around CSV's access pattern.

## Related roadmap changes

`docs/architecture/PROJECT.md`'s feature-slice list (item 6) previously read "**XLSX** (read-only)." Per
the author's explicit decision in this interview (2026-07-14), **ODS (OpenDocument Spreadsheet) replaces
XLSX** as the planned future spreadsheet format — edited in this same commit as this ARCH doc, per his
instruction to land the roadmap change together with this sign-off.

## External interfaces

**New C ABI** (additive to `api/lesssheet.h`; exact struct/enum layout is the root planner's freeze, not
prescribed byte-for-byte here): `ls_net_status`, `ls_net_open_state`, `ls_net_open_status`,
`ls_net_open_job` (opaque), `ls_open_url_start`, `ls_net_open_poll`, `ls_net_open_cancel`,
`ls_net_open_release`.

**New Swift protocol surface**: `DocumentSessionOpening.openURL(_:forcing:)`, `NetworkOpenError`.

## Acceptance criteria (each testable)

1. **On-paper Source-shape proof.** The design note above (Parquet footer-first, ODS ZIP-central-
   directory) is present in this document and reviewed; if either would require a Source/interface
   change, this criterion fails and the shape must be revised before implementation.
2. **Frozen boundary.** Every existing symbol, struct layout, and behavior in `api/lesssheet.h` is
   byte-identical before/after; only new, additive symbols appear. The root integrity gate passes.
3. **Range-support path.** Against a fixture HTTP server that honors `Range`/`Accept-Ranges`, opening a
   URL whose first-window rows are servable **before** the full remote resource has been fetched proves
   true partial/random access (not full-download-first) — e.g. a jump near EOF completes without the
   Source having fetched the whole file.
4. **Fallback path.** Against a fixture server that ignores `Range` (always `200 OK`), or omits a usable
   `Content-Length`, the open falls back to full sequential download → local spool → opened exactly as a
   local file, with correct rows/dialect/counts, and never claims partial-access behavior it can't back.
5. **`.csv.gz` over the network.** A gzip-compressed CSV served over either path (range or fallback)
   opens through the same `gzip` Source wrapping logic as a local `.csv.gz`, producing byte-identical
   dialect/rows/counts to the equivalent local file.
6. **Never-re-fetch guarantee.** Instrumentation proves that once a byte range has been fetched, every
   subsequent access to it (including after RAM-cache eviction) is served from the local spool file, with
   zero additional network requests for already-visited ranges.
7. **Error taxonomy.** Each `ls_net_status` value is independently reproducible against a fixture (DNS
   failure, TCP refuse, TLS failure, timeout, 404, redirect-loop past the cap, disallowed scheme) and
   surfaces as the corresponding distinct `NetworkOpenError` case in the frontend, with no case silently
   collapsing into another.
8. **Cancellation.** Cancelling mid-open (before `DONE`) via `ls_net_open_cancel` / the UI's Cancel button
   stops the fetch within one chunk boundary, releases all resources (spool file included), and leaves no
   dangling `ls_doc`.
9. **No silent stalls.** From the instant `ls_open_url_start`/`openURL` is called, a visible progress
   affordance is present with no threshold delay (unlike the existing 500 ms-gated `DelayedProgressIndicator`),
   determinate when `Content-Length`/`Content-Range` is known, indeterminate + live byte counter
   otherwise, with Cancel always available — verified for both the open phase and a post-open jump into
   never-before-fetched territory (reusing the existing jump-scan progress UI).
10. **No cold-start marker for network opens.** `lesssheet.first_rows_visible_ms` is never emitted for a
    URL open (grep/instrumentation check on stderr output), while it continues to fire correctly for
    local-file opens (regression guard).
11. **HTTP and HTTPS both work; scheme allowlist enforced.** A plain `http://` fixture and an `https://`
    fixture both open successfully; a `ftp://`/`file://`/malformed URL is rejected synchronously as
    `LS_NET_ERROR_INVALID_ARGUMENT` with zero network activity.
12. **No auth, bounded redirects.** A URL requiring authentication surfaces `LS_NET_ERROR_HTTP_STATUS`
    (401/403) rather than any credential prompt; a redirect chain within the cap succeeds, one exceeding
    it fails with `LS_NET_ERROR_TOO_MANY_REDIRECTS`.
13. **No cross-open caching.** Re-opening the same URL after `ls_close` always re-fetches from scratch
    (network call count instrumentation proves no reuse of a prior open's spool).
14. **Spool file hygiene.** The local spool file is created mode 0600, is unlinked immediately (never
    visible in its directory while open), and is fully gone (no fd leak, no residual bytes) after
    `ls_close` or process exit, mirroring the existing gzip checkpoint-spill guarantee.
15. **Memory bound.** `http_range` Source RAM state stays within its 16 MiB ceiling per open document
    across a sustained scroll/jump exercise against a large fixture; steady-state RSS does not grow
    unbounded with spool size (the spool is disk-resident, not RAM-resident).
16. **Dependencies & size.** No new runtime dependency is introduced (`std.http.Client`/`std.crypto.tls`
    only); the assembled app remains in its existing single-digit-MB budget; backend, macOS, and root
    gates pass.
17. **Frontend entry point.** File → Open URL… (⌘⇧O) presents a URL sheet; a successful open shows the
    URL as-is in the window title with no recents entry; ⌘O's local file panel is unaffected.

## Open Questions

None. Every decision above was interactively reviewed and signed off by the author on 2026-07-14.
