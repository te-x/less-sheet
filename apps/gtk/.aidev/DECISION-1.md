# DECISION-1 — Relax the frozen `test_bridge_find_within_filter` nav check to a poll-loop

- Component: `apps/gtk/` (C/GTK4, Meson; gate runs in `less-sheet-gtk-ci:fedora42`)
- Slice: 4 (filter) build cell
- Request kind: **contract** (two-key CHANGE-REQUEST)
- Ruling: **APPROVED** — apply the minimal test relaxation
- Frozen file amended: `tests/test_filter.c` (ONLY). `include/lsg_find.h` unchanged.

## The finding

`test_bridge_find_within_filter` (a filter-bridge test over the real Zig core) issued a search
nav (`lsg_document_search_nav(doc, lsg_search_nav_from_top())`) and then **single-polled** the
snapshot, asserting `nav == LSG_SEARCH_NAV_FOUND` off that one poll.

Under an **active filter** the core returns `nav = SEARCHING` on poll 0 and `nav = FOUND` on
poll 1 — a transient ~1-tick lag. Raw-ABI probe evidence:

```
poll 0: state=DONE nav=SEARCHING
poll 1: state=DONE nav=FOUND
```

So the single-poll observes `SEARCHING` and the assertion fails. Every OTHER async check in this
file (`wait_filter_final`, `wait_jump_done`, `wait_search_final`) polls a loop to a terminal
state; this nav check was the lone single-poll. The settled macOS reference frontend also
**poll-loops** the identical scenario — `navFound` (FilteredViewsTests.swift:69-87) issues the nav
then loops on `snap.nav`, returning only on `.found`/`.exhausted` and looping on
`.searching`/`.none`. The GTK single-poll therefore diverged from BOTH the reference frontend and
this file's own polling convention.

## Why this cleared the strict bar (Ground A — infeasible within the contract, net of cost)

Keeping the single-poll frozen forces the implementer to make `lsg_document_search_nav`
**synchronous under a filter**, and the only ways to do that inside the GTK cell's scope are:

1. a UI-thread `g_usleep` **busy-loop** in `lsg_find.c` — which VIOLATES the signed
   "never blocks the UI thread" NFR; or
2. a **core (backend/ABI) fix** so nav honors its synchronous-after-DONE promise under a filter —
   out of this cell's scope (an `api/` + backend change; a ROOT-planner two-key).

Within this cell, honoring the NFR, the single-poll frozen check is infeasible. The relaxation:

- **preserves every signature/ABI promise verbatim** — no header, no `api/` symbol, no struct
  changes; `include/lsg_find.h`'s nav doc is a FAITHFUL mirror of the ABI and is untouched;
- **preserves the assertion's full strength** — the poller stops on FOUND **or** EXHAUSTED, and
  the test still asserts `nav == FOUND` (proving it was found, not exhausted) and
  `found.row == 0` (proving the bridge lands the first filtered match, original row 0 at filtered
  index 0). It still proves the bridge lands the right row under a filter;
- has **zero caller blast radius** (a test-internal poll: single → loop); and
- **restores fidelity** to the settled macOS `navFound` pattern and this file's own `wait_*`
  helpers rather than adding a divergence.

## The resolution

1. `tests/test_filter.c` — add a `wait_search_nav_resolved(doc, &out)` poller (same bounded
   `for (i<5000) { poll; if resolved {*out=s; return TRUE;} g_usleep(2000); }` idiom as
   `wait_search_final`), stopping when `nav` leaves the pending SEARCHING/NONE state (→ FOUND or
   EXHAUSTED). In `test_bridge_find_within_filter` the single
   `g_assert_true (lsg_document_search_poll (doc, &ss));` becomes
   `g_assert_true (wait_search_nav_resolved (doc, &ss));`. The `lsg_document_search_nav(...)` call
   and the two following assertions (`nav == FOUND`, `found.row == 0`) are UNCHANGED. This is the
   ONLY contract edit.
2. `include/lsg_find.h` — **unchanged** (its nav doc correctly mirrors the ABI's
   synchronous-after-DONE guarantee; NOT a planner over-promise).
3. `src/lsg_find.c` — **implementer round-2 work, not this decision**: revert the UI-thread
   `g_usleep` busy-loop back to a plain non-blocking `ls_search_nav`. Production already resolves
   the ~1-tick lag on the next tick via `find_poll_fold` (which folds the nav every ~100 ms tick),
   so the busy-loop is dead weight that only existed to satisfy the old single-poll test.

### Gate remains GREEN across the round-2 revert

The poll-loop is satisfied by BOTH states of `lsg_find.c`:

- **Now (busy-loop still present):** nav returns already-FOUND, so the poll-loop resolves on
  iteration 0 → GREEN.
- **After the round-2 revert (plain non-blocking nav):** the loop absorbs the ~1-tick lag
  (poll 0 SEARCHING, poll 1 FOUND) → GREEN.

So the amended contract is forward-compatible; the implementer's revert removes the dead
busy-loop while this test stays GREEN.

## The two keys (evidence)

- **Key 1 — IMPLEMENTER (flag + named alternatives).** "The frozen
  `test_bridge_find_within_filter` single-polls the search nav after DONE and asserts FOUND. A
  raw-ABI probe shows that under an active filter the core returns `nav=SEARCHING` on poll 0 and
  `nav=FOUND` on poll 1 — a transient ~1-tick lag. The macOS reference `navFound` helper absorbs
  this by looping; the GTK frozen test single-polls. … the alternatives are a CHANGE-REQUEST to
  loop the frozen test's nav poll (matching macOS `navFound`) or a core fix so `ls_search_nav`
  honors its ABI 'synchronous after DONE' under a filter." Probe: `poll 0: state=DONE
  nav=SEARCHING` · `poll 1: state=DONE nav=FOUND`.

- **Key 2 — REVIEWER (`[contract]`, independently validated).** (1) The ABI explicitly and
  unconditionally promises synchronous nav after DONE (api/lesssheet.h:1242-1247; no filter
  carve-out) — so `lsg_find.h`'s wording is a faithful mirror, not an over-promise. (2) The CORE
  VIOLATES that promise under a filter (the probe) — a genuine backend ABI-conformance defect.
  (3) macOS handles it by POLLING, never blocking (`navFound` loops with `Task.sleep`; production
  `navigateSearch` is a bare non-blocking `ls_search_nav` folded over the tick). (4) GTK production
  `find_poll_fold` already polls every tick and folds nav via `lsg_find_resolved`, so the ~1-tick
  lag self-resolves next tick without any busy-loop; the main-thread `g_usleep` spin violates the
  "never blocks the UI thread" NFR and exists solely to satisfy the single-poll test. **Recommended
  resolution:** relax the frozen test to poll-for-FOUND (like macOS `navFound` and this file's own
  `wait_search_final`/`wait_jump_done`); the implementer then reverts the `lsg_find.c` busy-loop;
  the `lsg_find.h` doc stays unchanged; file the core defect separately.

Independently validated by the planner: read api/lesssheet.h:1240-1254 (unconditional
synchronous-after-DONE, no filter carve-out), lsg_find.h:421-428 (faithful mirror),
FilteredViewsTests.swift:69-87 (`navFound` poll-loop), and this file's `wait_*` conventions.

## Separate follow-up — BACKEND / `api/` ABI-conformance defect (NOT part of this GTK change)

`ls_search_nav` violates its ABI "synchronous after `LS_SEARCH_DONE`" guarantee under an active
filter: it reports `LS_SEARCH_NAV_SEARCHING` for ~1 tick before `LS_SEARCH_NAV_FOUND`, whereas the
ABI (api/lesssheet.h:1242-1247) promises the navigation completes BEFORE the call returns once the
scan is DONE, with no filter carve-out. This is a core (Zig backend) defect to reconcile later —
**either** fix the core so nav is truly synchronous-after-DONE under a filter, **or** relax the ABI
doc-comment to admit a bounded async tail under a filter. Both touch `api/` (and possibly the
backend), so this is a **ROOT-planner two-key on `api/lesssheet.h`**, out of scope for this
`apps/gtk/` cell. This GTK relaxation is correct regardless of how that defect is resolved (the
poll-loop tolerates both a synchronous and a 1-tick-async nav).

## Scope guard

Edited: `tests/test_filter.c` only. NOT edited: `include/lsg_find.h`, `src/lsg_find.c`,
`api/lesssheet.h`, any other frozen file, `meson.build`, `.ci/Dockerfile`. Not committed here
(the orchestrator commits the amended contract). Re-`freeze.sh` run to re-snapshot the protected
surface.
