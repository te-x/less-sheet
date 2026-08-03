# Task #40 — the flate feed guard (security ARCH wave (b), AC-b1 / AC-b2)

**Status: IN PROGRESS — not converged.** The adjudicated CHANGE-REQUEST is applied and the suite is
283/283, but reviewer round-1 findings 2 and 4–7 and its `beginReplay` question are still open.
Branch `feat/kbdnav-a11y`.

| | |
|---|---|
| Freeze | `e6f901a` (`flate_b1`, `flate_b2a`, `flate_b2b`) |
| Build | `87c2fa8` (rounds 1–2), then the adjudicated remedy |
| Signed design | `docs/architecture/ARCH-security-hardening.md`, wave (b); FR2 |
| Out of scope | AC-b3 `[fuzz]` — the (c) campaign (ARCH line 548: (b) precedes (c) so a known crash cannot mask campaign findings) |

## What was wrong

Three defect classes, found in this order, and the third was the worst:

1. **The crash.** A truncated compressed prefix drove `std.compress.flate` into a ReleaseSafe panic
   during the open head inflate. Far more reachable than the suite's two crash-REDs suggested — **9 of
   22 sampled fixture-A truncation offsets crashed the old feed.**
2. **The hang and phantom rows — one defect.** `streamFallible` leaves `dec.state` unmodified on
   error (deliberately, to aid diagnosis), so a step that stopped in `.dynamic_block_literal`/`_match`
   still held a saved literal/match and re-entering wrote that byte again while consuming **zero**
   input. The feed's `inflateStep` returned "progress" whenever `r.end > r.seek` *before* consulting
   `dec.err`, so it re-entered forever. Measured: `input.seek` frozen at 262142, `dec.err = ReadFailed`,
   262144 bytes emitted per produce op with `inflate_ops` flat, open head growing to 4 MiB on a 3.6 MB
   document.
3. **Silent wrong data, two paths.** `produce` used `readSliceShort`, which **discards its byte count**
   when a later read fails (`Reader.zig:688`) — cut 16891 gave `written=1035, rows=59, r0="280"`: a
   complete, exact, WRONG document. And `ensureCompressed` reported withheld bytes as fetched, so the
   inflater decoded spool **zeros** into rows.

## What review caught that a green gate could not

Reviewer round 1: **NOT PASS, 7 findings.** The headline one is why this record exists.

**`tossesShort` tested the wrong state set.** The refusal that makes the crash unreachable was gated on
`Decompress.state`, and the tags std actually *stores* are `.protocol_header` (in `init`),
`.block_header`/`.protocol_footer`, `.stored_block`, `.fixed_block_*`, `.dynamic_block_*`, `.end`.
Two consequences:

- **`.dynamic_block` is never stored.** Entry into a block is a bare `continue :sw` that assigns
  nothing, so that switch arm was dead.
- **`.protocol_header` was missing.** `Session.init`/`nextMember` call `Decompress.init` per member, so
  it is the live tag for the whole of a member's **first** block — including the dynamic-header
  code-length loop and the literal/match symbol loop. **The 15-bit refusal was inactive across all of
  fixture A.**

Compounding it, **`flate_b1` returns at its first failing assertion**, so the RED tree had exercised
only fixture A cuts 0..37 — roughly **4%** of the arm. The "whole ~1500-offset sweep passes" evidence
came from a *different* tree (round 1 plus the clamp), and the clamp discards exactly the
post-last-terminator bytes where a mid-symbol garbage decode lands. Durable lesson: **never accept
sweep evidence from a tree other than the one under review.**

## Orchestrator probes (trusted host, throwaway worktree at `87c2fa8`)

| probe | change | result |
|---|---|---|
| P3 | print BFINAL/BTYPE | fixtures A **and** B are `BFINAL=1 BTYPE=2` — a single final **dynamic** block. Fixture B's print never appeared pre-fix, independently confirming the 4% finding |
| P1 | frozen helper fix alone | advances past cut 37, fails at **cut 50** with a **garbage decode**: row 5 of 6 salvaged `"00000003"`, document says `"00000005"`. The prefix rule correctly rejected it |
| P2 | + `.protocol_header` | `flate_b1` passes **in full**, both fixtures, first time on any tree; `gz_ac10` fails |
| P4 | + `.header = api.header_off` | `gz_ac10` **still** fails — `expected .ok, found .io`, at **open**, on the new `openUsable` guard |
| P5 | + drop that guard | **283/283 green** |
| P6 | P5 minus `header_off` | fails → `header_off` **is** required |

`flate_b1`'s prefix check has real teeth: `"00000003"` is not a prefix of `"00000005"`, exactly as the
reviewer predicted when endorsing it.

## Adjudication — `[contract]` second key GRANTED (grounds A)

`flate_b1` and `gz_ac10` demanded opposite things of the same bytes: the fragment after a damaged
gzip's last row terminator. `expectTruncationHandled` probed `{0, rc.count/2, last-1, last}` and
exact-matched all but `k == 3`, but for `rc.count` of 1–2 **`rc.count/2 == last`** — so the exact check
landed on the row the helper's own comment, its doc comment and the freeze commit all exempt as a
possible partial tail. `gz_ac10` conversely needs that tail kept, because dropping it leaves one row
that its **sniffed** header consumes (`open.zig:237-241` decides `has_header` from record 1's
numeric-ness alone, before any index exists and independent of the row count) → `rows=0`.

The reviewer **refused on the record** an in-code escape that would have made both green — "clamp
unless clamping would leave zero data rows" — as overfitting motivated solely by the two fixtures. It
also refused re-freezing `gz_ac10` to expect `.io`: a test whose subject is that a salvaged prefix has
a deterministic immutable end has nothing left to assert if the open fails.

**Applied remedy — four changes, all required:** helper keyed on row identity (`k == 3 or row == last`);
`gz_ac10` opts gain `.header = api.header_off`; `tossesShort` becomes a **default-deny exhaustive
switch with no `else`**; `openUsable`'s damaged ⇒ needs-CR/LF guard is dropped.

Default-deny matters for a reason worth keeping: `else => false` breaks the build on a **renamed** std
tag but silently permits a **newly added** one — the likelier churn, and the direction that costs
correctness. Only the no-`else` form delivers the property the doc comment claims. On 0.16.0 both forms
are behaviorally identical, so P5's result carries.

**The clamp stays out of this cell**, and measurement replaced the argument: cut 50's garbage cell is in
the **final** row of the salvage, so the clamp would have dropped it and passed the cut — masking the
soundness hole this round found. Whole-rows-only is one product question for the architect and the author,
applied uniformly to both ends of a salvage (`openUsable` was the same question one salvage-end
earlier), and it would need an assertion that still catches garbage at the truncation point.

## Accepted unexplained one-off

One `zig build test` invocation on the P5 tree emitted a torn `+- run test w` line and a
`failed command:` with no diagnostics and no per-test report. Chased under the reviewer's bounded
protocol (`scratchpad/stability.sh`): **15 × `zig build test` and 15 × standalone binary, 30/30 clean,
all EXIT=0.** Accepted as a build-runner artifact per the reviewer's own stated criterion. **Any
recurrence blocks convergence.**

## Perf

Rounds 1–2, differential C-ABI, ReleaseSafe both arms, 9 warm interleaved reps, 168 MB / 4.71 M rows:
gz index scan **936.1 → 917.8 ms** median (−1.96%); mmap control 312.85 → 312.94 (flat); row counts
identical. The AFTER pair is still owed at convergence, with the exact command and how the ReleaseSafe
`--lib` is built, so it can be rerun independently.

## Still open (reviewer round-1 findings)

- **2** — rerun the full `flate_b1` sweep on the converged tree; the 4% coverage must become 100%.
- **4** — remove the parked clamp residue (`Gzip.last_row_end`, `noteRowEnd`, the `COMPLETE-ROWS-ONLY`
  comment). `noteRowEnd`'s `lastIndexOfAny` runs on every drained chunk in the hot path to maintain a
  value with **no consumer**.
- **5** — the 2 ms stall backoff is a bare literal in three places (`index.zig:437`,
  `net_source.zig:719`, `:875`); one named const, one home.
- **6** — duplicated boundary predicate, `index.zig:389-390` and `:424-425`.
- **7** — `sourceAwaitsBytes` is not "the one resolver": `produce` answers the same question
  differently for a local gzip. And `ensureCompressed`'s `@min(end, present_prefix.load(.monotonic))`
  re-derives `presentExtent()` with a weaker ordering than that accessor uses for the same atomic.
- **Question** — `beginReplay` starts a provider session at `input.end = 0`, so
  `@min(session.input.end, seek +| budget)` is 0 and `produce`'s provider block raises the fence to the
  fetched high-water without re-applying the lane cap; confirm the Cursor's own `physical_limit` still
  bounds it, or clamp inside the provider raise.
