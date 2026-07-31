# Task #14 — silent row-count DRIFT at span boundaries

**Status: reviewer-PASS at `95cd3ae` (round 3).** Branch `feat/kbdnav-a11y`.
Filed forward by `REVIEW-net-peek-mutex.md`; ruled merge-blocking ahead of the remaining
security-hardening waves because it is the silent-wrong-data class — requesting row T served
file row T+k.

| | |
|---|---|
| Freeze | `1360216` (four boundary tests + `NetFixture.fetch_attempts`), `d1f361b` (`drift2`) |
| Build | `9edeeec` (r1), `5936132` (r2), `95cd3ae` (r3) |
| Final footprint | **one file**: `backend/src/csv_reader.zig`, +136/−40 |
| Byte-identical | `api/lesssheet.h`, `backend/contracts/`, `backend/tests/`, `backend/src/source.zig` |
| Gate at close | PASS `--require-frozen` — 278/278, csvgen 142/0, `zig fmt`, native ReleaseSafe + aarch64/x86_64-musl |
| Perf | local `.csv.gz` index scan 1058.2 → 997.7 ms median (~5.7% **faster**), mmap control flat 300.4 |

## The defect, and why it was two defects

`scanUtf8Rows` carried a pending-LF flag (`skip_lf`) that was wrong in opposite directions:

- **`drift1` — UNDERcount.** `if (b == '\r' and i + 1 == bytes.len) skip_lf = true;` re-tested
  `i + 1` against an `i` the preceding CRLF branch had already incremented, so a CRLF pair ending
  exactly at a span end set the flag spuriously and the next span's leading lone `\n` was swallowed
  as a CRLF's second byte.
- **`drift2` — OVERcount, +1 per batch.** The flag did not survive the *return*: `index.scanChunk`
  calls the walk once per checkpoint batch, so a batch ending on a span-ending bare CR published a
  position between the CR and its LF, and the next call — plus every re-lex from that checkpoint —
  counted the LF as its own empty row. Unguarded sources only; `commitGuarded` is false for `.gzip`,
  network or not.

The planner measured all four cells before any fix, which is what made the two locks independent:
no fix → RED/RED; cross-call state only → RED/GREEN; `else if` only → GREEN/RED; both → GREEN/GREEN.

## The fix: three rounds, three deletions

**Round 1 (`9edeeec`) — delete `skip_lf`.** One rule replaces it: *a terminator is consumed whole,
or not at all*, so every position the walk publishes is a row START and both drift directions become
inexpressible rather than separately patched. The span-ending CR — the only terminator a span cannot
settle from its own bytes — is settled at the boundary; `bytes`/`i` are dead after a peek, because a
gzip peek can re-fill the lane buffer `bytes` points into (the rule the quoted-field escape already
followed).

This round also corrected the freeze's stated approach: threading the state through `ScanRowsResult`
would **not** have sufficed, because `index.scanChunk` stores `checkpoint = {row, pos}` with that same
between-CR-and-LF position and re-lex has no access to any flag. Settling forward was the only sound
option — `seekTo` asserts `commitGuarded`, so a gzip cursor cannot be rewound.

**Round 2 (`5936132`) — two reviewer findings the green gate could not see.**

1. `peek(2)` AT the CR cannot settle a terminator on a network Source.
   `ensureSliceSequentialLocked` (`net_source.zig:851-865`) waits for the byte at `internal` and
   **ignores `want`**, so with the drain high-water at CR+1 the peek returns 1 byte immediately,
   `term` froze at 1, and `commitBound` then **demanded** past `row_end` rather than refusing it — it
   secures the reach, it does not decline it — committing a between-CR-and-LF frontier. Meanwhile
   `finishTerminator` peeks at CR+1 and *does* force the drain, so the two lexers disagreed at exactly
   the position the frozen locks exist to pin. **Strictly worse than pre-fix on that path**, since the
   old `!skip_lf` gating never committed a boundary-CR row at all. Invisible to the suite: both locks
   are gzip/`force_chunk` fixtures and `fcg1`'s 256-byte rows put the LF, not the CR, at the span end.

   Fixed by asking the question at the offset it is about: consume the CR, `peek(1)` at the successor
   (the only demand the sequential arm honors, the shape `commitBound` uses for its far byte), and
   `spanTerminal` then answers the true-end question about the successor. Four arms, and the `guarded`
   special case disappears: LF → CRLF; other byte → bare CR; nothing + terminal → bare CR at the true
   end; nothing + not terminal → withhold.

2. The unguarded withhold published a **mid-row** position, so `(next, rows)` was untruthful: the
   checkpoint anchored a row on its own terminator, every re-lex from it served that row **empty**, and
   its content bytes belonged to no row. The count does not drift, which is why the locks stayed green.
   Fixed by deleting `commit_rows` and maintaining `commit_logical` on every Source, updated with the
   count it belongs to, so there is no shadow to fall out of step. This also cured a **pre-existing**
   case nobody had flagged: any call ending mid-row with `!eof` published that mid-row position,
   because the old rewind was gated on `guarded`.

**Round 3 (`95cd3ae`) — delete `Cursor.physicalAt`.** Round 2's new helper called `Gzip.physicalFor`
unconditionally, but `physicalPosition` reaches that resolver **only** on its head arm; past the head
it uses `op_physical[lane]` or `session.input.seek`. On the rewind path `commit_logical` is past the
head and past every checkpoint, so `physicalFor` fell through to `forward_physical` — ahead of the op
that produced those bytes. `indexPoll` derives `bytes_scanned` from `frontier_pos.physical` with
`@min(phys_total, …)` and **no floor**, so net-gz progress could tick **backward**, against
`api/lesssheet.h`'s "monotone non-decreasing over the document's lifetime".

Closed by removing the helper and publishing `cur.physicalPosition()` — literally the call `cursorPos`
makes, on the same cursor and lane. On this path both candidate formulas resolve to `op_physical[lane]`
anyway, so an op-window arm would have been a second copy of a formula with one right answer. The
guarantee now holds by construction rather than by a comment claiming it does.

## Evidence

**Orchestrator-run probe (reviewer's construction, run in a throwaway `git worktree`; source kept at
`scratchpad/probe-seq-net.zig`).** 8000 rows of 65 bytes (63 content + CRLF) so row 4032's CR lands on
262143 and its LF on 262144; `NetFixture{ .honor_ranges = false, .advertise_length = true }`; healthy
peer, no fault injection; compared against the identical bytes opened locally through mmap, with
per-row cell comparison at 4031..4034 and the last row.

```
9edeeec:  local 8000 rows | sequential net 8001 | DELTA=1   (cells also disagree)
5936132:  local 8000 rows | sequential net 8000 | DELTA=0   (279/279 incl. the probe)
```

The reviewer predicted `8001` exactly, before the run.

## Residual and filed forward

- **`bytes_scanned` monotone floor (NOT done, filed forward for the author).** The gzip physical is
  lane-dependent: a chunk served from a replay lane can publish a lower `op_physical` than a
  forward-lane chunk did. That is a property of *every* publisher on this path and is unchanged by this
  cell — what the cell owed was not to *introduce* a backward tick, and it no longer does. Both roles
  judged a monotone high-water clamp at the `frontier_pos` write or in `indexPoll` the correct home for
  the guarantee, but it hardens every writer, so it is its own change. Reviewer: worth landing before
  merge only if the ABI guarantee should be *enforced* rather than emergent; **not a blocker on this
  cell**.
- **The sequential-net arm has no frozen lock.** The probe is the only coverage of it and lives outside
  the suite. Freezing it needs a planner increment — decision pending.
- Net-gz cell remains scoped out (`Gzip.produce`'s unconditional read-ahead), per the signed ARCH.

## Process notes

- **Green is exactly as strong as the frozen tests, three times over.** Both purpose-built drift locks
  passed while a deterministic overcount sat on the plain sequential-network arm, and the mid-row
  publish never moved a count at all.
- **The gate is structurally blind to unused public declarations.** An intermediate round-3 attempt left
  `Cursor.physicalAt` in the tree as a `pub fn` with no callers, still carrying the doc rationale the
  reviewer had disproved, and the gate was green and silent — Zig does not error on an unused `pub fn`.
  The catch came from the orchestrator verifying the report against the tree (`grep -rn` +
  `git diff --stat`), not from the gate and not from the reviewer. The report asserted both "the
  function is deleted" and "`source.zig` is byte-identical to `5936132`" — the commit that added it —
  which is self-contradicting on its face. Same shape as the existing record entry: *a green build ≠
  correct*.
- **Each round's fix was a deletion**: the flag, then the `guarded` special case and the shadow count,
  then the third derivation. Removing state paid for itself in measured throughput.
- Committed at round boundaries so each round is isolatable in git (the lesson from the previous cell's
  round-4 "comment-only" claim).
