# Contract Change Request — security-hardening (b) / `expectTruncationHandled` @ tests/all_tests.zig vs `gz_ac10`

(The previous CR — sec_w2b2, ARCH AC-e1/AC-e2 — was ADJUDICATED 2026-07-28 and APPROVED, and is
recorded in full in `docs/architecture/ARCH-security-hardening.md`, "Amendment — 2026-07-28",
with decision records at `review/REVIEW-security-w2b-net.md` and `review/REVIEW-net-close-hang.md`.
This supersedes the file contents; it does not reopen anything adjudicated there.)

Signed:  [x] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the numbers below were independently re-checked)

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
