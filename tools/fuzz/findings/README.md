# Findings

Open findings from the wave (c) harness. Each becomes a regression seed in the
corpus once fixed (AC-c2: "Any crash found is fixed and added as a regression seed
to the corpus, then re-run clean").

They are **not** in the seed packs as active seeds yet, on purpose: a seed that
hangs would wedge both the corpus replay and every campaign start.

---

## F1 — `ls_open` never returns: UTF-16 with an odd trailing byte on a STREAMING source

**Status: OPEN. Found by the harness on its own seed corpus, before any campaign
started. Blocks the AC-c2 campaign.**

It is a **hang**, not a crash, so nothing times it out: Zig's fuzzer has no
per-iteration watchdog, so a single hit stops a campaign silently and forever.

### What it is

`ls_open` does not return, at any timeout, when **both** hold:

1. the decoded stream is **UTF-16 ending on an odd byte** — a dangling half code
   unit at end of stream; and
2. the source is **not** the mmap'd local file — verified on **both** streaming
   sources, the local **gzip** source and the **network** source.

The identical bytes as a plain `.csv` always return cleanly, so the mmap path
resolves end-of-stream there and the streaming sources do not.

**Reachable with `encoding = auto`** — no dialect override, no user action, because
auto-detection selects UTF-16 from the BOM. Against the standing product bar
("everything either WORKS or FAILS GRACEFULLY") an unkillable open on untrusted
input is a ship-blocker: both frontends call `ls_open` and would present a frozen
window with no way out.

Three bytes are enough: `FF FE 41`.

### Evidence

Measured on `feat/kbdnav-a11y` tip `29e5d95`, native **ReleaseSafe** (the shipped
mode), macOS aarch64, zig 0.16.0. Inputs are in `F1-gz-utf16-hang/`.

**Local gzip source** (standalone driver, `F1-gz-utf16-hang/repro.zig`):

| input | inflated content | `encoding` | result |
|---|---|---|---|
| `B-bom-le-odd-1byte.csv.gz` | `FF FE 41` | **auto** | **NO RETURN** |
| `C-bom-le-odd-9bytes.csv.gz` | `FF FE` + `a,b\nx,y\n` + `A` (odd) | **auto** | **NO RETURN** |
| `A-valid-ascii-gz.csv.gz` | 127 bytes of clean ASCII CSV | `utf16le` | **NO RETURN** |
| `A-valid-ascii-gz.csv.gz` | same | `utf16be` | **NO RETURN** |
| `A-valid-ascii-gz.csv.gz` | same | `auto`/`utf8`/`latin1`/`cp1252` | ok, rows=5 |
| `D-control-bom-le-even.csv.gz` | `FF FE` + `id,name\n1,a\n` (**even**) | auto | ok, rows=0 |
| — | valid **empty** gzip (`03 00`, 0 bytes out) | auto | ok, rows=0 |
| — | gzip of `"\n"` | auto | ok, rows=0 |

`index_manual` hangs too, so it is not the background scan lane. **Even lengths are
fine; the odd trailing byte is the trigger.**

**Network source** (fake transport, `NetFixture`): `net.pack` entry 40 — body
`FF FE 41`, `honor_ranges=false`, `advertise_length=false` (unknown-length
sequential stream), **every other knob at its default, `encoding = auto`** — wedges
the open with no gzip involved.

Controlled confirmation, same corpus, one variable: with the encoding pinned to
UTF-8 the whole 70-entry `net` corpus replays clean in 21 s; without the pin it
does not finish in 240 s. Bisected to entry 40 by `-Dseed-limit`.

**Where it spins** (`sample`, one thread at 100%, identical stack across samples
7 minutes apart):

```
# local gzip source
ls_open -> open.buildDocument (open.zig:194) -> reader.Reader.boundsAfter (reader.zig:140)
        -> csv_reader.boundsFromCursor (csv_reader.zig:798) -> csv_reader.streamUnit (csv_reader.zig:759)
        -> source.Cursor.peek (source.zig:1307-1355) -> source.Gzip.byteAtLane (source.zig:1002)

# network source — same shape, different byte provider
ls_open -> open.buildDocument (open.zig:194) -> reader.Reader.boundsAfter (reader.zig:140)
        -> csv_reader.boundsFromCursor (csv_reader.zig:782) -> csv_reader.streamUnit (csv_reader.zig:759)
        -> source.Cursor.peek (source.zig:1308) -> net_source.HttpRange.ensureSlice (net_source.zig:897-901)
```

i.e. the **open head scan**, not a worker, spinning in the source's byte provider.
Samples are spread across several lines of the provider, so it is a busy loop
rather than a block on a lock.

The shape — a loop that keeps asking for bytes without terminating — is the same
*family* as the wave-(b) `inflateStep` re-entry defect
(`review/REVIEW-flate-feed-guard.md`, defect 2: "returned progress whenever
`r.end > r.seek` before consulting `dec.err`, so it re-entered forever"), but here
it is reached through the **encoding** path, with a **valid, complete** gzip member
(and with no gzip at all on the network arm), so the wave-(b) feed guard does not
apply.

The likely shared cause: end-of-stream with one byte left is not a UTF-16 code
unit, and the streaming sources appear to report "not yet at end, no progress"
rather than "end of stream" — which the mmap source, knowing its total length up
front, gets right.

### Quarantine in force

`harness.zig` sets `quarantine_utf16_streaming = true`, which **pins `encoding` to
UTF-8 on the three streaming targets** (`gz_raw`, `gz_trunc`, `net`). Pinning rather
than merely not drawing forced UTF-16 is what avoids it — auto-detection selects
UTF-16 by itself from a BOM.

Cost, stated plainly: while the quarantine holds, the `encoding` hotspot is covered
by the `csv` target only, where all five encodings are drawn and measured to
terminate. Lifting it is one line and is the intended first step of triage.

### Closing this finding

1. Fix the non-termination in `backend/src/` — the end-of-stream verdict shared by
   `source.zig` (`Gzip`/`Cursor.peek`) and `net_source.zig` (`ensureSlice`), or in
   the UTF-16 decode step that consumes from them. One fix should close both arms;
   confirm on both.
2. Set `quarantine_utf16_streaming = false`.
3. Add the inputs as regression seeds. The packs want *Smith blobs*, so frame each
   as `u32le len || bytes || 24 zero bytes || u32le 0` (zero words = the vanilla
   drive, and `encoding = auto` — which is what these need) and append:
   `./zig-out/bin/seedgen append seeds/gz_raw.pack <blob>`.
   The network arm needs no new seed: `net.pack` entry 40 already carries it and
   goes RED the moment the quarantine is lifted.
4. `zig build test` — the replay must be clean.
5. Re-run the campaign per AC-c2.

---

## F2 — `ls_sort_set` panics on a null build: `sort_build` is re-read across a lock drop

**Status: OPEN. Found by the `fuzz sort` target on its first campaign, 4 runs out
of 4, at the same instruction. Not a hang — a ReleaseSafe panic, so the campaign
reports it and stops rather than wedging.**

### What it is

```
thread N panic: attempt to use null value
backend/src/sort.zig:888:31: in setSort
        const b = d.sort_build.?;
backend/src/root.zig:368:24: in ls_sort_set
```

`setSort` decides whether it can keep the existing build, then waits, then uses
the decision:

```zig
const keeps_build = same_column and d.sort_build != null and       // :884  CHECK
    (d.sort_state == .active or d.sort_state == .building or d.sort_state == .parked);
if (keeps_build) {
    awaitScanIdle(d);                                              // :886  DROPS THE LOCK
    const b = d.sort_build.?;                                      // :888  ACT
```

`awaitScanIdle` (`:953`) spins on `while (d.sort_scan_busy) d.waitWork();`, and
`waitWork` is `cond.waitUncancelable(io, &self.mutex)` — it **releases the
document mutex**. The scan worker takes that mutex, and on a failing chunk its
`error.Storage` / `error.OutOfMemory` arms (`:1708-1709`) call `failBuild` →
`dropBuild` → `d.sort_build = null` before clearing `sort_scan_busy`. `setSort`
then wakes, re-takes the mutex, and unwraps the optional it validated **before**
the wait. Check-then-act across a lock drop.

The neighbouring call sites are already safe by shape, which is why this one
stands out: `clearSort` (`:1104`) and `startPass` (`:962-963`) both do
`awaitScanIdle(d); dropBuild(d);` and never unwrap. The worker's own
`error.Interrupted` arm even reasons about this window explicitly — *"a cancel or
a replacement is already waiting on the mutex we just re-took; it owns the
teardown"* — but the Storage/OOM arms tear the build down regardless, and
`setSort` does not re-validate.

### Why it matters

This is the AC-s7 path — *"injected temp-storage failure and injected allocation
failure during the pass each yield FAILED with the documented reason, the view
RESTORED to its pre-sort order"*. A full disk or an OOM landing in that window
while the user flips the sort direction is a **crash**, not a clean FAILED, and
against the standing bar (*works, or fails gracefully*) a ReleaseSafe panic is a
crash. The frozen `srt_failure_modes` test does not catch it because it injects
the failure and then waits for a terminal state; it never calls `ls_sort_set`
*while the failing pass is being interrupted*, which is the whole window.

### Reproducing

```sh
cd tools/fuzz && zig build --fuzz=800 -Donly="fuzz sort"
```

Hit on 4 of 4 runs here, each within a couple of minutes, always at `sort.zig:888`.
The harness reaches it because `oneSort` arms `sortTempFailAfter` /
`sortAllocFailAfter` (drawn from `w0`) and then flips the direction repeatedly on
the same column — nothing else in the harness exercises the failure arms at all.

### Closing this finding

1. Fix it in `backend/src/sort.zig`: re-validate after the wait rather than
   before it — `awaitScanIdle(d); const b = d.sort_build orelse { ...treat as a
   fresh start / return... };` — and check whether the state read at `:884` needs
   the same treatment, since the worker can also have moved `sort_state` to
   `.failed` during the drop.
2. Add a frozen backend test for the interleaving (it belongs in the `srt_*`
   suite, not only here): arm `sortTempFailAfter`, start a pass, and call
   `ls_sort_set` with the other direction while the failing chunk unwinds.
3. `cd tools/fuzz && zig build test` — the replay must stay clean.
4. Re-run the campaign per AC-c2.
