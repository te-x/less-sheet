---
description: Run the implementer<->reviewer build cell until the gate is green and the reviewer passes.
argument-hint: <feature name>
---
Build cell for: $ARGUMENTS.  Hard cap: 5 rounds. The cap means stop and escalate; it never lowers the
quality bar or justifies a quick fix.
(Polyglot workspaces: pass the target component to the trusted global gate driver.)

Read `.aidev/harness/ORCHESTRATOR.md` FIRST — the fixed role/enforcement invariants. Treat them as ground
truth; do not re-derive what the roles do. Derive only project specifics (paths, commands, per-role
runner/model/transport) from `.aidev/profile.sh` and `.aidev/roles.json`.

Run `bash .aidev/harness/role-runner.sh doctor` before the first mutation. If any selected assignment
fails, stop, explain the concrete reason, and ask for another runner/model. Never fall back silently.
Then run `bash .aidev/harness/gate.sh --require-frozen "$PWD"` yourself. A missing snapshot or any
protected/profile/role drift is a policy stop: this command never starts from an unfrozen contract.

**You (the orchestrator) are a SWITCHBOARD, not a participant.** You keep the cell's agents alive
across rounds and move messages between them — and that is ALL you do between roles. Hard rules:
- **Never assume a role yourself.** You do not design, plan, implement, or review — not even "one
  small fix", not even to break a stall. A stall escalates to the human.
- **Role→role handoffs are verbatim and BY REFERENCE.** You never retype, summarize, paraphrase,
  trim, reorder, or annotate one role's message when passing it to another. You hand `role-runner.sh
  relay` *pointers* to the recorded messages; the trusted runner assembles the bytes itself, ledgers
  the hashes, and `verify-relay` (chained into the gate via `--relay`) fails the build on any drift.
  Orchestration context you must add (round number, gate transcript) goes in as separate, labeled
  `--note` sections — never woven into a role's words.
- **Toward the human, be helpful.** Summarize, clarify, and contextualize freely when *reporting to*
  or *asking* the human. Human input entering the cell goes in verbatim as a `--human` section.
Do not help one role game a check, conceal uncertainty, weaken tests, or pressure another role to
accept a shortcut. Quality means the strongest maintainable delivery within the agreed scope and
constraints, not unrequested gold-plating.

**Dispatch by capabilities, not provider names.** Inspect each role with `role-runner.sh inspect`.
One run-id per cell (all roles share it — that is what links the relay ledger).
- `kind=external`: first turn `role-runner.sh run <role> start <run-id> <briefing-file>` (your
  briefing — turn 1 is the only orchestrator-authored prompt the relay chain accepts). Every later
  turn MUST be `role-runner.sh relay <role> resume <run-id> --from <src-role>:<run-id>:<turn> ...
  [--human f] [--note label f]` — never hand-author a resume prompt. Read replies from the
  normalized `message_file` (`role-runner.sh last`).
- `kind=native`: spawn the configured subagent once with your briefing; for later rounds compose with
  `role-runner.sh relay <role> resume <run-id> --from ...`, SendMessage the composed file's content
  VERBATIM, then record the full reply with `role-runner.sh journal <role> <run-id> message
  <reply-file>` so the audited chain stays unbroken. (Native handoffs are journaled+audited, not
  structurally forced — one session holds both ends; external adapters get the hard guarantee.)
Use a distinct run-id per parallel cell so sessions and audit state never mix.
That isolates conversation state, not files. Run cells in parallel only when separate nested profiles give
them disjoint `IMPLEMENTATION_PATHS` and independently runnable gates, or when an adapter supplies isolated
worktrees with validated promotion. If two cells could touch the same writable file, run them sequentially.

Loop:
  a. **Round 1:** start the configured **implementer** for this cell. Later rounds resume the SAME native
     or external run with `[impl]` findings. It may iterate locally, but its gate claim is not evidence.
  b. Run `bash .aidev/harness/gate.sh --require-frozen "$PWD"` yourself. Protected/profile/role drift is a policy stop,
     not another implementation retry. Conformance/behavior failures go back to the implementer.
  c. Once the trusted gate passes, record `bash .aidev/harness/role-runner.sh tree-hash "$PWD"`, then
     start/resume the configured **reviewer** against that exact tree: relay the implementer's own
     report by reference (`--from implementer:<run-id>:<turn>`) plus the trusted gate transcript as a
     `--note gate-transcript <file>` — never retell either.
     Its adapter must satisfy the read-only capability checked by doctor. If it
     needs a benchmark/profile command it cannot safely execute, it requests the measurement; YOU run the
     controlled command and resume the same reviewer with the raw output file as a `--note` section.
     It reports PASS or tagged findings.
  d. **Verify again — never take the cell's word for it.** Re-run `role-runner.sh tree-hash`; reject a verdict
     if it differs from the pre-review digest (external responses are also bound to that digest). Only
     reviewer PASS plus a fresh trusted global gate
     `bash .aidev/harness/gate.sh --require-frozen --relay <run-id> "$PWD"` PASS on that same tree means
     DONE — the `--relay` check proves every handoff in the cell was a verbatim, ledgered relay.
  e. `[impl]` findings → relay to the implementer by reference
     (`relay implementer resume <run-id> --from reviewer:<run-id>:<turn>`); next round.
  f. Joint **Contract Change Request** (implementer drafted it AND reviewer tagged `[contract]` or `[design]`):
     - `[contract]` → dispatch the configured **planner** (Mode B). On reject, continue with its reasoning.
     - `[design]`, external I/O, or a technology/dependency change → return to the **architect + human**.
       Dispatch the configured architect, amend ARCH/PROJECT, and get explicit human sign-off. Only then
       does the configured planner apply dependency/build + contract/test changes and refreeze.
     On any approval, COMMIT the amended signed design and protected surface (git repos:
     `aidev: amend contract — DECISION-<n>`) before resuming.

The gate settles everything objective (conformance + behavior); the reviewer only judges the
subjective residue (acceptance criteria, NFR evidence, `[impl]` vs `[contract]`) — so most rounds
carry little or no negotiation. **On DONE, write ONE decision record** to `review/REVIEW-<feature>.md`
(final verdict + the rounds' key findings) — the durable audit, written at convergence rather than
every micro-exchange. CHANGE-REQUEST / DECISION docs are always files (contract boundary).

After 5 rounds without convergence, STOP and summarize for me. Never loop forever.
