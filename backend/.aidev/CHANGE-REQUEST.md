# Contract Change Request — security-hardening (b) / `expectTruncationHandled` @ tests/all_tests.zig vs `gz_ac10`

(The previous CR — sec_w2b2, ARCH AC-e1/AC-e2 — was ADJUDICATED 2026-07-28 and APPROVED, and is
recorded in full in `docs/architecture/ARCH-security-hardening.md`, "Amendment — 2026-07-28",
with decision records at `review/REVIEW-security-w2b-net.md` and `review/REVIEW-net-close-hang.md`.
This supersedes the file contents; it does not reopen anything adjudicated there.)

Signed:  [x] implementer   [x] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

## ADJUDICATED 2026-08-03 — GRANTED on grounds A, APPLIED. Record: `review/REVIEW-flate-feed-guard.md`

The reviewer re-derived the helper arithmetic by hand and verified the `gz_ac10` half
mechanically via `open.zig:237-241` (`has_header = !all_numeric` from record 1 only, so it is
row-count independent). It also refused, on the record, an in-code escape that would have made
both fixtures green — "clamp unless clamping would leave zero data rows" — as overfitting whose
only motivation is the two fixtures.

**The remedy applied is NARROWER than either option proposed above, and is four changes, not
one.** Orchestrator probes (P1-P6) showed this request's "this needs no implementation change
(attempt 1 stands)" to be measurably FALSE: with the helper fixed, fixture A cut 50 serves row 5
as `"00000003"` where the document says `"00000005"` — a symbol decoded out of
`peekBitsShortEnding`'s zero padding, in a single final DYNAMIC block, because `tossesShort`
omitted `.protocol_header`. So `gz_ac10` collided with SOUNDNESS, not merely with a semantic
preference about partial tails.

| where | change | whose |
|---|---|---|
| frozen `expectTruncationHandled` | `if (k == 3 or row == last)` | planner |
| frozen `gz_ac10` opts | add `.header = api.header_off` | planner |
| `src/source.zig` `tossesShort` | default-deny exhaustive switch, no `else` | implementer |
| `src/source.zig` `openUsable` | drop the damaged ⇒ needs-CR/LF guard | implementer |

All four are required: the two frozen edits accomplish nothing without the two `src/` ones
(measured — P4 fails at open with `expected .ok, found .io`, P6 fails without `header_off`).

**The clamp stays OUT of this cell** and the alternative above is NOT adopted. Measurement
replaced the argument: cut 50's garbage cell is in the FINAL row of the salvage, so the clamp
would have dropped it and PASSED the cut — it would have masked the soundness hole this round
found. Whole-rows-only is a product question for the architect and the author, to be decided once
and applied uniformly to BOTH ends of a salvage (the `openUsable` guard was the same question one
salvage-end earlier), and if adopted it needs an assertion that still catches garbage at the
truncation point.

## Grounds (tick at least one)
- [x] A. Infeasible within the current contract
- [ ] B. Substantial, quantified improvement

## If A — infeasibility

Two FROZEN tests demand opposite things of the same bytes, and nothing in the data
distinguishes their cases. The disputed bytes are the fragment a damaged gzip leaves
AFTER its last row terminator.

**`flate_b1` requires it DROPPED.** `expectTruncationHandled` probes
`.{ 0, rc.count / 2, last - 1, last }` and applies `expectEqualStrings` to every index
except `k == 3`. For `rc.count` of 1 or 2, `rc.count / 2 == rc.count - 1`, so the EXACT
check lands on the final row — the row the helper's own comment says "may be cut
mid-row: a PREFIX is correct". A maximal, sound salvage of fixture A at cut 37 is
`"00000000,00000000\n0000000"`: two rows whose last is a 7-byte prefix of
`"00000001"`, and the probe fails at `k == 1`.

**`gz_ac10` requires it KEPT.** Its 6-of-18-byte deflate prefix salvages `"a,b\n1"`.
Dropping the partial `"1"` leaves ONE row, which `gz_ac10`'s own options consume as the
header (it passes only `.separator` and `.index_mode`, so header detection is SNIFFED),
so `ls_row_count_get` reports 0 and `try expect(rc.count >= 1)` fails.

Both tails are structurally identical — bytes after the final terminator in a stream
known to be truncated — so no predicate separates them and no implementation satisfies
both.

- Attempts (>=2), each with the specific reason it failed under the current signature:
  1. **KEEP the partial tail** (report the salvage's true end). This is the tree as
     handed over. `gz_ac9`, `gz_ac10`, `gz_ac11` pass; `flate_b1` fails at every cut
     whose salvage is 1-2 rows with a partial last row (fixture A cuts 31, 32 and 37
     observed directly).
  2. **DROP the partial tail** — clamp a damaged end to the last row terminator.
     Implemented, measured, then reverted; the mechanism (`Gzip.last_row_end`,
     `noteRowEnd`) and its full reasoning are left wired and documented in
     `src/source.zig`'s `terminalLogical` note so the adjudicated answer is one line to
     apply either way. The whole ~1500-offset `flate_b1` sweep passes, both fixtures;
     `gz_ac10` then fails.
  3. **Salvage FURTHER into the tail** so cut 37's last row completes — not available.
     That salvage already ends at the last bit the stream can spell: the pre-change feed
     stops at the same byte (`"0000000"`, measured through the C ABI against both
     libraries), and going further means decoding symbols from bits that are not there,
     which is exactly the silent wrong data this cell exists to remove.

- Failing gate / compiler / type-checker output:

  With attempt 1 (the tree as handed over):

      [flate/b1/A cut=37] row 1 col 0: salvaged "0000000", undamaged "00000001"
      [flate/b1/A cut=37] salvaged 2 rows (undamaged document has 180)
      +- run test 281 pass, 2 fail (283 total)

  With attempt 2:

      error: 'all_tests.test.gz_ac10: a salvaged prefix has a deterministic immutable
      end (exact count, terminal poll, stable)' failed without output
      +- run test 281 pass, 2 fail (283 total)

  and, measured directly on the same fixture through the C ABI with `gz_ac10`'s own
  options (sniffed header), which is what makes the cause unambiguous:

      ac10.csv.gz at-open: complete=1 scanned=16 total=16 rows=0 exact=1

## Minimal change (as a diff)

Preferred — let the helper honour its own documented rule, so the final row is only
ever prefix-checked (`tests/all_tests.zig`, `expectTruncationHandled`):

    -        if (k == 3) {
    +        // The final row may be a partial tail whatever its INDEX: for a 1- or
    +        // 2-row salvage `rc.count / 2` IS `last`.
    +        if (k == 3 or row == last) {
                 try std.testing.expect(std.mem.startsWith(u8, expect_buf[0..want.len], got));
             } else {
                 try std.testing.expectEqualStrings(expect_buf[0..want.len], got);
             }

This needs no implementation change (attempt 1 stands) and weakens nothing: complete
rows are still compared byte-for-byte, and the only row treated as a prefix is the one
the helper already documents as possibly partial.

Alternative, if complete-rows-only is the intended product semantics: keep the clamp
(attempt 2) and relax `gz_ac10`'s `rc.count >= 1` to accept a salvage whose single row
was taken as the header — e.g. open it with `header_off`, or assert on
`ls_dialect_get(...).header`. That changes what a damaged document reports to every
frontend (row count, `complete`, `exact`, `bytes_scanned`), so it is the architect's
call rather than the planner's.

## Cost / blast radius
- Other contract items / tests / modules affected: `flate_b1` only, under the preferred
  change. Under the alternative: `gz_ac10`, plus the reported row count, `complete`,
  `exact` and `bytes_scanned` of every damaged gzip document.
- Changes EXTERNAL I/O?   [x] no    [ ] yes → this goes to the ARCHITECT, not the planner.
  `api/lesssheet.h` is byte-identical and no terminal classification was added.

## Scope note
This request concerns ONLY the partial-tail question. The rest of the cell landed
without it: the ReleaseSafe `integer overflow` panic (AC-b1), the complete/exact/WRONG
document, and the resumable-vs-terminal classification are fixed, with the salvage
matching the pre-change feed byte-for-byte wherever the pre-change feed did not crash.
