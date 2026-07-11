# REVIEW — stream-copy (decision record)

**Verdict: DONE.** Gate green at every level (root chain: `api/` integrity + backend + macOS),
verified by the orchestrator's own `bash .aidev/gate.sh` runs each round — backend **142/0**,
macOS **102 tests / 8 suites**, `zig fmt` clean. Reviewer = Claude `claude-opus-5` (file bridge).

**Headline (AC7, GATING):** end-to-end 100k × 10 (1,000,000-cell) full-selection copy through the
real `TSVCopyBuilder` + `copyCell` + `ls_cell_copy` completes in **~2.6 s** (ceiling 5 s) — vs the
**~140 s** from-scratch path it replaces (~54× faster). The O(rows) forward copy cursor lands behind
the byte-identical `ls_cell_copy` ABI (no `api/` change).

## Build cell — backend ∥ frontend, 5 rounds
Parallel cells on one tree (disjoint: `backend/src` vs `apps/macos/Sources`), per the ARCH isolation
note. Implementers = Claude `sonnet @ max`.

- **R1 (build):** backend cursor (`base.zig` cursor state + `window.cellCopy`/`cellCopyFiltered` +
  `copy_advances` counter in both cursor-OFF/ON and identity/filtered; nav resume helpers) → backend
  gate green (sc1–sc5). Frontend `DelayedProgressGate.indication` + reusable Reduce-Motion spinner +
  copy/index/jump/filter wiring + AC9 audit note (`docs/architecture/ARCH-stream-copy-audit.md`).
- **R2 (review fixes):** [impl] ×4, all verified real before relaying, none [contract]:
  1. frontend — stale delayed-reveal task showed progress for a *superseded* copy → fixed with a
     monotonic `copyGeneration` token.
  2. backend — filtered re-anchor **double-counted** (forward-walk *then* cold-locate) → FR3 "never
     slower" violation → redesigned to decide upfront (block-count lookup) and do forward XOR cold,
     never both.
  3. backend — `nthMatchForwardFrom` off-by-one cap → removed by the R2 redesign.
  4. backend — cursor RMW not linearizable under concurrent copies → guarded forward-only commit +
     corrected the "serialize" wording to "lock-free walk + guarded commit."
- **R3 (deeper review):** [impl] ×2, both real:
  A. identity cursor could be *slower* than a closer checkpoint on a forward non-row-major jump (FR3)
     → gate the cursor on `copy_cursor_row >= bestCheckpoint(row).row`.
  B. filtered cross-block resume re-scanned `filter_block_counts` from block 0 → O(m²) for sparse
     sweeps → resume the cumulative scan from the cursor's block (`start_block`/`start_cum`).
- **R4–R5 (pre-existing UAF — fixed at the user's request before shipping select-copy):** see below.

## Pre-existing UAF fixed (select-copy `3731617`, NOT introduced by stream-copy)
Reopen/close during an in-flight copy could call core fns on a freed handle (violates the ABI rule
"`ls_cell_copy` … not concurrently with `ls_close`"). The user chose "fix now, then ship."
- **R4:** `cancelCopy()` moved before `session.close()` in `open()`/`closeDocument()`; `copyCell`
  guards `isClosed` under `copyBufferLock`, which `close()` now also holds around `isClosed = true;
  ls_close(doc)` (race-free; deadlock-free; no AC4 regression). Review found this **incomplete**.
- **R5 (final):** the orphaned copy task also calls `startJump`/`jumpStatus` via `advanceFrontier`
  before the build loop — both now guarded the same way. All three core calls the copy task can make
  (`startJump`/`jumpStatus`/`copyCell`) sit behind the close barrier → nothing touches `doc` after
  `ls_close`. Lock order audited (`close()` the only dual holder, `lock`→`copyBufferLock`).

## Residual reviewer findings — adjudicated NON-blockers (not stream-copy defects)
The cold whole-diff reviewer re-raises these each round; the orchestrator classified them:
1. **Filtered `ls_cell_copy` may allocate/fail via `nav_scratch`** — PRE-EXISTING and **explicitly
   sanctioned by the ARCH** ("the one exception, mirroring `windowSetFiltered`"). Degrades safely
   (`.no_cell` on OOM, no UB). BACKLOG: reconcile the `api/lesssheet.h` "zero-alloc/never-fail"
   wording with the filtered path (pre-size `nav_scratch`, or amend the header note).
2. **`cellCopy` reads `filter_state` outside `d.lock()`** — PRE-EXISTING (byte-identical routing in
   the pre-stream-copy `cellCopy`); cursor `(view,gen)` tagging re-anchors on a mismatch. BACKLOG:
   route the identity/filtered decision under the lock.
3. **Gap-1 step on a checkpoint boundary costs 1 advance, not 0** — CONTRACT-MANDATED: frozen `sc3`
   asserts `cursor >= n-1` (a row-major step IS 1 advance). "Fixing" to 0 breaks the frozen test.
   WON'T FIX (would require a planner amendment for a ≤1-advance theoretical delta vs the ~1024/row
   the cursor saves).

## Ship
`.app` reassembled (`apps/macos/scripts/assemble-app.sh`) so **select-copy finally ships** to the
bundle — now crash-free on reopen-during-copy.
