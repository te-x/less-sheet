---
description: Architect (interactive, with the user) + plan a feature — aligns live, then produces an ARCH doc, a frozen contract, and red tests.
argument-hint: <feature name and one-line description>
---
Drive the design phase for: $ARGUMENTS

Read `.aidev/harness/ORCHESTRATOR.md` FIRST — the fixed role/enforcement invariants. Treat them as ground
truth; do not re-derive what the roles do. Derive only project specifics (paths, commands, per-role
runner/model/transport) from `.aidev/profile.sh` and `.aidev/roles.json`.

If there is no `.aidev/profile.sh`, tell me to run `/aidev:init <language>` first, and stop.
Run `bash .aidev/harness/role-runner.sh doctor` before any role. If an assignment fails, stop, explain
the exact reason, and ask me to choose/configure another runner or model. Never substitute one silently.
All roles work toward the strongest delivery within the signed scope and constraints. Relay uncertainty,
trade-offs, and evidence faithfully; never steer another role toward a shortcut just to advance the workflow.

**You (the orchestrator) are a SWITCHBOARD, not a participant.** Never perform a role yourself — you do
not design, plan, or answer an architect/planner question in a role's stead. Between roles, messages move
verbatim and by reference: use `role-runner.sh relay ... --from <role>:<run-id>:<turn>` for external
runners (turn 1 briefings via `run` are the only orchestrator-authored prompts), and for native roles
compose with `relay`, SendMessage the composed content verbatim, and `journal` the reply. When a role's
question batch goes to the human you may summarize and clarify freely; the human's answers return to the
SAME role verbatim as a `--human` section. The architect→planner boundary itself is durable files (the
signed ARCH doc), which the gate already hashes.
Polyglot workspaces: if the feature targets a component with its own `.aidev/`, work inside it and use
the trusted global gate/freeze drivers with that component path; changes to the shared root
`api/` surface are frozen by the ROOT planner pass, never by a component implementer.

**Role dispatch (use for every role below).** Inspect with
`bash .aidev/harness/role-runner.sh inspect <role>`; branch only on `kind`/capabilities, never a provider or
model name. For `native`, spawn the configured project subagent once and use SendMessage on later turns. For
`external`, write a focused turn prompt to a temp file and call `role-runner.sh run <role> start|resume
<run-id> <prompt-file>`; read its normalized `message_file`. The adapter selected during init decides whether
resume uses a live session/API, transcript replay, structured output, or a durable-file bridge.

1. **Architect — interactive, with ME.** Start the configured architect in RELAYED INTERACTIVE mode as
   `feature-<feature>` and relay
   its small question batches to me; return my answers to the SAME native session or external run until it
   says the design is ready. Do not perform the architect role in the orchestrator and do not replace it
   with the current session model.
   - Survey existing code first (brownfield) so your questions are informed.
   - Use AskUserQuestion for discrete choices (formats, error behavior, scope cuts) — batch 2–4 at a
     time; use free-form questions for open topics.
   - Keep going until inputs/outputs/formats, edge-case behavior, and every architecture-significant technology
     choice are concrete. Research major build-vs-buy, library/framework, database/storage, service,
     logging/observability, infrastructure, and production-dependency choices; recommend a direction and work
     through consequential trade-offs with me rather than leaving them to the planner or implementer.
   - Draft `docs/architecture/ARCH-<feature>.md`, show me the Technology decisions and acceptance criteria,
     and get my explicit sign-off (iterate until I approve). No Open Questions may remain in the final doc.
2. **Planner.** Start the configured planner (Mode A) on the approved ARCH doc; resume the same run when
   returning decisions or profile fixes.
   - `## Architect decision needed` → return the gap to the architect + me; amend ARCH/PROJECT, get my
     explicit sign-off again, then re-invoke the planner. The planner never chooses production technology.
   - `## Decisions needed` → these are contract/API details inside the approved architecture; bring each
     option + recommendation to me, then re-invoke the planner with my answer.
   - `## Profile update needed` → add every named dependency/build file to literal `DEPENDENCY_PATHS`
     entries (no globs), confirm the list with me, then re-invoke the planner.
   - On resolution it finalizes the approved dependency setup + contract + tests, seeds a red implementation,
     and the freeze runs: a native planner runs `bash .aidev/harness/freeze.sh "$PWD"` itself; if the
     planner runner is EXTERNAL (isolated workspace), run that trusted freeze YOURSELF on the real
     workspace after its final changes are promoted — an in-iso freeze snapshot is a discarded control
     and never promotes.
3. **Commit the contract (git repos).** If the project is a git repo, commit the protected surface — the
   ARCH doc, any approved PROJECT update, dependency manifest/lock changes, contract, tests, seed implementation,
   and `.aidev/.frozen.sha256` — message
   `aidev: freeze contract for <feature>`. This arms the gate's git anti-tamper layer. If it is not a
   git repo, say so and recommend `git init` (the gate then relies on the snapshot alone).
4. Run `bash .aidev/harness/gate.sh --require-frozen "$PWD"` YOURSELF. Expected: integrity OK, conformance OK,
   behavior RED. Report it. Never accept a role's own gate claim.

Then tell me to run `/aidev:build <feature>`.
