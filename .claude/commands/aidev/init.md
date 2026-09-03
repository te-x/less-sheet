---
description: Onboard the project — language profile + open-ended per-role runner, model, transport, and skills.
argument-hint: <language: python|java|scala|generic>
---
Onboard this project. Set up its language boundary, then configure each role's runner, model, transport,
and skill preload explicitly. The defaults are proposals; the user makes the final choice.

All four roles share one delivery standard: pursue the strongest result within the agreed scope and
constraints. A runner is not acceptable if it can only appear to pass by weakening checks, hiding uncertainty,
or pushing shortcuts onto another role.

1. **Project and language setup.** Run `bash .aidev/harness/init.sh $ARGUMENTS` to create `.aidev/` (profile + gate
   shims) and skeleton dirs. For EVERY project, inspect and confirm `.aidev/profile.sh`:
   `ARCHITECTURE_PATHS`, `FROZEN_PATHS`, `DEPENDENCY_PATHS`, `IMPLEMENTATION_PATHS`, `CONFORMANCE_CMD`, and `BEHAVIOR_CMD` must match
   the real layout. Also propose enabling `QUALITY_CMD` — the optional deterministic quality gate step
   (each profile ships a commented suggestion: strict linter / format check / complexity caps). VERIFY the
   tool actually runs in this project first, show the exact command and its current output to the user, and
   enable it only with their confirmation — once set it is a hard gate step, so a missing or failing tool
   must stay commented out until the baseline is clean. Likewise propose the profile's strict
   warnings-as-errors `CONFORMANCE_CMD` variant when the current baseline builds warning-clean, so
   warnings become gate failures instead of transcript noise. Built-in dependency lists are common
   starting points, not discovery. Inventory every
   actual manifest, lockfile, and dependency-bearing build file, including nested modules. Entries are literal
   file/directory paths; never use globs. Generic profiles must define `DEPENDENCY_PATHS` before proceeding
   (a workspace root may delegate them explicitly to protected nested component profiles).

   Read the repository and `docs/architecture/PROJECT.md` before choosing skills. For a brownfield project,
   confirm the existing suite is green now. For a greenfield project, do a short project-context intake and
   fill the useful parts of PROJECT first; configure the roles below, then ask the configured planner to create
   the minimal runnable toolchain. The first feature must not start until that bootstrap is green and committed.

   If this is an older project with `models.conf` but no `roles.json`, use its values only as proposed
   migration defaults. Still show and confirm all four runner/model assignments, transport choices, and skills.

2. **Choose each role runner — required, open-ended.** Ask which runner + exact model the user wants for
   **architect**, **planner**, **implementer**, and **reviewer**. Do not present a closed provider/model menu.
   A role may use:
   - `claude-native` — a normal Claude Code subagent; `model` is any Claude alias/full ID and
     `settings.effort` is optional; or
   - any external runner ID backed by an executable adapter at
     `.aidev/harness/adapters/<runner-id>.sh`. The model string and `settings` object are opaque to aidev
     and belong to that adapter (reasoning effort, variant, endpoint, agent name, etc.).

   List already configured adapter IDs as conveniences, not as the available universe. If the user names a
   new CLI/API agent, inspect that agent during this init, copy `ADAPTER.template.sh`, and implement its
   `describe`, `doctor`, `probe`, and `invoke` operations. A writable adapter must actually enforce the role's
   allowed and denied paths (for example through a narrow sandbox or isolated patch promotion); a prompt-only request is
   not enforcement. Exhaust sensible setup options, but never silently switch
   models or weaken the role. If it cannot meet the role (for example: missing/auth failure, no required write
   mode, or no enforceable read-only reviewer mode), explain the specific reason and ask the user to choose
   another runner/model.

   Research the most efficient reliable communication method for the ACTUAL four-runner combination selected:
   native SendMessage, resumable CLI sessions, ACP/server APIs, structured stdout, transcript replay, or durable
   files. Configure each adapter accordingly and declare the result in `describe.continuity` / `human_io`.
   Prefer live/resumable transport when it preserves isolation and authorship; use files when they are the most
   reliable boundary. Do not infer transport from the provider name. Persist the selected transport per role and
   test it across two turns, including separate run IDs for parallel cells.

   **Skills are selected per role too.** Inspect the project's language, framework, domain docs, and available
   project/user/plugin skills. Propose a short role-relevant preload list for each selected model, with a one-line
   reason for each skill. Check that a skill's required tools/workflow make sense for that selected runner; call
   out incompatibilities. Show the proposals to the user and let them expand, reduce, replace, or empty any list;
   the user's answer is final. Do not silently add skills later. Resolve each approved name to one exact `SKILL.md`;
   if more than one candidate has that name, ask which source to use. External adapters receive the same resolved
   skill package/context as native roles, even if their CLI has no native skills feature.

3. **Persist data, not commands**, in `.aidev/roles.json` (skill names below are illustrative; write only
   names that doctor can resolve in this project/user/plugin environment). Record `transport` and use
   `skill_sources` whenever a name could resolve to more than one package:
   ```json
   {
     "schema": 1,
     "roles": {
       "architect":   {"runner":"some-agent", "model":"vendor/model-a", "transport":"resume", "settings":{"reasoning":"max"}, "skills":["architecture-research"], "skill_sources":{"architecture-research":"/exact/path/to/SKILL.md"}},
       "planner":     {"runner":"claude-native", "model":"opus", "transport":"native", "settings":{"effort":"max"}, "skills":["project-contracts"], "skill_sources":{}},
       "implementer": {"runner":"another-agent", "model":"vendor/model-b", "transport":"replay", "settings":{}, "skills":["project-conventions"], "skill_sources":{}},
       "reviewer":    {"runner":"review-agent", "model":"vendor/model-c", "transport":"resume", "settings":{"variant":"fast"}, "skills":[], "skill_sources":{}}
     }
   }
   ```
   Runner IDs resolve only through the trusted user-level adapter directory; never put a shell command or
   credentials in the project JSON. `models.conf` is legacy compatibility only.

4. **Validate and apply.** Run `bash .aidev/harness/role-runner.sh doctor` (runner, permissions,
   authentication, transport, and every configured skill), then `bash .aidev/harness/role-runner.sh probe`
   to exercise the exact model/settings/transport choices, and then
   `bash .aidev/harness/set-models.sh`. Doctor must validate all four assignments before any feature work.
   A failed assignment or probe stops init with its concrete reason and asks for another choice; no fallback.

5. Report the final runner/model/transport/skill mapping. For a brownfield project with a green baseline,
   tell the user to restart the Claude Code session so directly generated project-agent definitions and
   preloaded skills are reloaded, then run `/aidev:feature <description>`. For greenfield, restart first, have
   the configured planner bootstrap the approved toolchain, verify it is green, and commit it.
   Assignments may be changed between active build cells by rerunning init (or editing roles.json + doctor +
   set-models). If the project is already frozen, deliberately refreeze and commit that approved config change.
