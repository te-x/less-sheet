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
