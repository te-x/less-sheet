# aidev — AI software-engineering pipeline

A reusable, **language-agnostic team of constrained agents** with a **deterministic quality gate**,
installed at user level (`~/.claude/`) so it's available in *every* project.

**Mental model.** Design becomes a **frozen contract** — data types + public signatures + behavior
tests. An *implementer* fills in the bodies but **cannot change the contract**. A *reviewer* verifies
independently. The boundary is held by a **gate that fails the build** — not by asking the model nicely.
The **architect designs WITH you, live** and owns architecture-significant technology choices: it researches
major libraries/frameworks, databases, services, observability, infrastructure, and build-vs-buy options,
working through consequential trade-offs with you. The other roles surface uncertainty at checkpoints instead
of guessing. The signed architecture docs, contract/tests, and configured dependency/build files form the
protected surface. **Which model runs which role is chosen per project at onboarding — nothing is enforced globally.**

The roles are independent checkpoints, not opponents. They all pursue the strongest maintainable delivery
within the signed scope and constraints. They do not game the gate, weaken tests, hide evidence, or push
shortcuts onto another role; uncertainty and stalled rounds are escalated honestly instead.

---

## TL;DR

```
cd <your repo>
/aidev:init python          # setup: runner/model/transport/skills choice for every role
/aidev:feature  slugify     # interactive architect interview → planner → frozen contract, RED tests
/aidev:build    slugify     # implementer ⇄ reviewer loop until gate GREEN + reviewer PASS
```

```
architect ─► planner ─► frozen contract ─► build cell(s)
                                             │
                 inner loop:       implementer ⇄ gate.sh
                                             │ gate passes
                 outer loop:                  ▼
                                    changes ⇄ reviewer ─► done
                                             │
                 joint Contract Change Request ─► planner
```

---

## Skills

### Agents (`.aidev/harness/agents/`)

Each role is assigned independently per project. Native Claude roles use project agent overrides;
external models use trusted adapters selected during onboarding (see **Role runners**).

| Agent | Model | May write | Role |
|---|---|---|---|
| **architect** | per project | architecture docs | Defines behavior and constraints, researches architecture-significant technology choices, recommends a direction, and works through consequential trade-offs with you before sign-off. |
| **planner** | per project | contract + tests + dependency setup | Turns the approved design into a **frozen contract**, behavior tests, module boundaries, and approved manifests/lockfiles/build setup. Applies approved changes; surfaces design gaps rather than making consequential architecture choices. |
| **implementer** | per project | implementation only | Fills in implementation using the approved stack. Chooses private details and algorithms, but cannot edit configured protected paths or use an unapproved production dependency. |
| **reviewer** | per project | nothing (read only) | Verifies the implementation against acceptance criteria, contract, and recorded technology decisions. Tags findings `[impl]`, `[contract]`, or `[design]`; requests host-run measurements when needed; never edits project files. |

### Commands (`.claude/commands/aidev/`)

| Command | Argument | What it does |
|---|---|---|
| **`/aidev:init`** | `<language>` | Sets up `.aidev/`; asks for an open-ended runner, model, settings, transport, and editable skill list for every role; then validates the selected combination. |
| **`/aidev:feature`** | `<name + description>` | Interactive architect interview with YOU → planner → commit of the frozen contract (git repos). Produces the ARCH doc, frozen contract, RED tests. Pauses on Decisions needed. |
| **`/aidev:build`** | `<feature>` | The implementer ⇄ reviewer cell until gate GREEN + reviewer PASS (or a joint Contract Change Request, or 5-round cap → back to you). |

---

## Role runners (per project)

No role has a fixed provider list. `/aidev:init` records a runner ID, opaque model string, adapter-owned
settings, selected transport, and explicit skill preload list for every role in `<repo>/.aidev/roles.json`.
The skill names in the example are illustrative; init writes only user-confirmed, resolvable skills.

```json
{
  "schema": 1,
  "roles": {
    "architect":   {"runner":"agent-a", "transport":"resume", "model":"vendor/model-a", "settings":{"reasoning":"max"}, "skills":["architecture-research"], "skill_sources":{"architecture-research":"/exact/path/to/SKILL.md"}},
    "planner":     {"runner":"claude-native", "transport":"native", "model":"opus", "settings":{"effort":"max"}, "skills":["project-contracts"], "skill_sources":{}},
    "implementer": {"runner":"agent-b", "transport":"replay", "model":"vendor/model-b", "settings":{}, "skills":["project-conventions"], "skill_sources":{}},
    "reviewer":    {"runner":"agent-c", "transport":"resume", "model":"vendor/model-c", "settings":{"variant":"fast"}, "skills":[], "skill_sources":{}}
  }
}
```

`claude-native` is the built-in Claude Code subagent path. Every other runner ID resolves to a trusted,
trusted executable at `.aidev/harness/adapters/<runner-id>.sh`; project JSON never contains executable
commands or credentials. An adapter implements the small `aidev-agent/v1` contract (`describe`, `doctor`,
`probe`, `invoke`) and may wrap a CLI, API, local server, or another agent system. `ADAPTER.template.sh` is the
starting point.

This vendored copy ships no external-runner adapters: every role in this project runs on `claude-native`.
A writable external role, if one is ever added, must enforce **isolated promotion** in its adapter: the
runner works inside a private copy of the repo and only the request's `allowed_write_paths` MINUS its
`denied_write_paths` are promoted back afterward (deny wins in both nesting directions), so a role cannot
rewrite the signed architecture, the frozen surface, or the enforcement controls — including
`.aidev/.frozen.sha256` — even where they sit inside an allowed directory. That write boundary is a safety
property of the adapter, not a provider/model allowlist in aidev. The planner authors the frozen contract
and tests that the gate trusts, so it is a higher-trust assignment — the signed ARCH doc it may not edit
and the human review of the frozen commit are its checks. Because the frozen snapshot never promotes, the
orchestrator runs the trusted freeze on the real workspace itself when the planner is external.

**Liveness.** An adapter should monitor every live turn (kill the process tree and return `failed`, promoting
nothing, when its event stream goes idle for `settings.heartbeat_idle_secs` or the turn exceeds
`settings.deadline_secs`). Independently, any external role may set `settings.invoke_deadline_secs` for a
provider-neutral coarse wall-clock cap that `role-runner.sh` enforces around the whole adapter call (needs
`timeout`/`gtimeout` on PATH); this backstop protects even adapters with no internal heartbeat.

During init, aidev researches the most efficient reliable communication available for the exact selected
combination—native messages, resumable sessions, ACP/server APIs, structured output, or transcript replay—
and records the selected transport per role. It also proposes a short project- and role-relevant skill list
for each model. The user may expand, reduce, replace, or empty every list. Each approved skill is resolved to
one exact source; the confirmed packages are preloaded into native agents or injected into external context.

`role-runner.sh doctor` validates static runner availability, authentication, role permissions, transport,
and skill resolution. `role-runner.sh probe` then makes a small live request using each exact model/settings
choice. If a niche choice cannot satisfy its role after sensible attempts, init explains the exact reason and
asks for another choice. It never silently substitutes a model or weakens permissions.

Change assignments between active build cells by re-running `/aidev:init`, or edit `roles.json`, then run
`bash .aidev/harness/role-runner.sh doctor`, `bash .aidev/harness/role-runner.sh probe`, and
`bash .aidev/harness/set-models.sh`. Because role assignments are protected during a build, an already-frozen
project must deliberately refreeze and commit
the approved config change before work resumes. `set-models.sh` can still read legacy `models.conf`, but the
capability-based feature/build workflows require `roles.json`; rerun `/aidev:init` once to migrate an old project.
After `set-models.sh` writes `.claude/agents/*.md` directly, restart the Claude Code session before dispatching
native roles so their new model/effort/skill frontmatter is loaded.

### Continue a project created with an older aidev

Migrate between build cells when possible; do not throw away an in-progress implementation or its contract.

1. Commit the current coherent state, or stash unfinished edits so the migration diff is easy to inspect.
2. Run `/aidev:init <language>` again. It preserves an existing profile and treats legacy `models.conf`
   values only as proposed defaults; confirm every role rather than accepting an automatic substitution.
3. Update the preserved profile with literal `ARCHITECTURE_PATHS`, `FROZEN_PATHS`, `DEPENDENCY_PATHS`, and
   `IMPLEMENTATION_PATHS`, plus `CONTRACT_HOWTO` and the real test/conformance commands. Establish a green
   baseline first for an existing codebase.
4. Confirm each role's runner, exact model/settings, transport, and editable skill list; run `doctor`, the
   live `probe`, and `set-models` as init directs, then restart the Claude Code session.
5. For an in-flight feature, keep its ARCH doc, contract, tests, and implementation. Have the configured
   planner inspect those artifacts against the new profile, then run the trusted global freeze and commit the
   new role/profile/generated-agent controls with the protected surface.
6. Reapply any stashed implementation changes. If they now touch a protected path, do not force them through;
   route that difference through the planner. Resume with `/aidev:build <feature>` using fresh role run IDs.
   Start `/aidev:feature` only when no contract exists yet or when the old design genuinely needs to be redone.

---

## The gate — deterministic enforcement

The project shim calls the trusted global gate; build workflows invoke
`bash .aidev/harness/gate.sh --require-frozen "$PWD"`
directly. It exits 0 (`GATE: PASS`) only if all four checks pass:
1. **Integrity** — the enforcement profile, role assignment, signed architecture, contract/tests, and
   configured dependency/build files match the snapshot. Catches modified, **added**, and deleted files.
2. **Git anti-tamper** *(armed once the contract is committed — `/aidev:feature` does this)* — frozen
   paths and the snapshot must match HEAD, so "tamper + re-run freeze" re-blessing fails too.
3. **Conformance** — implementation matches the declared types/signatures (`CONFORMANCE_CMD`: `mypy`, or `javac`/`scalac` via `mvn`/`sbt`). On compiled languages a signature drift won't compile.
   Profiles ship commented warnings-as-errors variants — prefer them when the baseline is warning-clean,
   so warnings are gate failures rather than transcript noise the roles must remember to read.
3b. **Quality** *(optional — when the profile sets `QUALITY_CMD`)* — deterministic strict lint / format /
   complexity checks. This is the gate-tier slice of code quality; each profile ships a commented
   suggestion, enabled during init after verifying the tool runs. Judgment-tier quality (structure,
   generality, dead code) stays with the planner's contract design and the reviewer's named checks.
4. **Behavior** — the spec tests pass (`BEHAVIOR_CMD`: `pytest` / `mvn test` / `sbt test`).
5. **Relay chain** *(with `--relay <run-id>` — `/aidev:build` passes it on the final acceptance run)* —
   every role→role handoff in that run was a verbatim, ledgered relay assembled by `role-runner.sh`
   from references (see **The orchestrator is a switchboard** below). A paraphrased or orchestrator-
   authored resume prompt fails the gate.

The gate is the **guarantee**; the hook and prompts are fail-fast layers on top. `/aidev:build` has the
orchestrator run the final gate **itself** — a subagent's "it passes" is a claim, not evidence.

---

## The build-cell transport — durable boundary, capability-based loop

The contract boundary (ARCH → planner → implementer) is a **handoff of durable artifacts**: files,
committed, hashed by the gate. That's mandatory — the guarantee lives on disk. The implementer ⇄
reviewer inner loop is a **tight negotiation toward convergence**, so its transport follows tested
runner capabilities, with the **orchestrator as relay hub**:

| Capability | Loop transport |
|---|---|
| native role | spawn once, then SendMessage |
| resumable external runner | resume the same CLI/API/server session |
| replay-only external runner | replay durable transcript + latest delta |

### The orchestrator is a switchboard — verbatim relay, enforced

The orchestrator **never assumes a role** and **never rewrites what moves between roles**. It may
summarize and clarify toward the **human** — that's its job — but a role→role handoff is verbatim.
Like the contract, this is held by machinery, not by prompt alone:

- **Relay by reference.** `role-runner.sh relay <role> resume <run-id> --from <src-role>:<run-id>:<turn>`
  hands the runner *pointers* to recorded role messages. The trusted runner reads those files itself and
  assembles the next prompt — the orchestrator structurally cannot alter the bytes. Human input enters
  verbatim via `--human <file>`; unavoidable orchestration context (round number, the trusted gate
  transcript) enters as separate, labeled `--note` sections, never woven into a role's words.
- **Ledger.** Every turn appends a hash-bound entry (`relay` with its sources, or `direct` for the one
  allowed orchestrator-authored turn-1 briefing) to the run's private state; adapter responses are
  already bound to role/run/config/tree digests.
- **Verification.** `role-runner.sh verify-relay <run-id>` re-derives every relayed prompt byte-for-byte
  from its ledgered sources and fails on any drift, any orchestrator-authored resume prompt, or any
  resume relay carrying only orchestrator notes. `/aidev:build` chains it into the final acceptance
  gate via `gate.sh --relay <run-id>`.
- **Native tier, honestly.** External runners get this structurally (the prompt file is composed by the
  trusted runner). `claude-native` roles live in the same session as the orchestrator, so their handoffs
  are composed with `relay`, sent verbatim, and the reply recorded with `role-runner.sh journal` —
  journaled + gate-audited, cooperative-tier rather than structurally forced. Assign external adapters
  to the inner loop when you need the hard guarantee.

Init researches and tests the best reliable method for the actual combination; provider names do not decide
transport. Parallel cells use separate run IDs, and reviewer verdicts are bound to the exact input-tree digest.
Independent of transport, three rules apply: the **gate settles
everything objective** (so the reviewer only judges the subjective residue — acceptance criteria, NFR
measurement, `[impl]`/`[contract]`/`[design]`); the **durable review record is written once at convergence**,
not every round; and the loop is **bounded (5 rounds) then escalates** (CHANGE-REQUEST / human).

---

## Workflows

### 0 · Brand-new project from zero (recommended start)
1. `mkdir <proj> && cd <proj> && git init` — git first: it arms the gate's anti-tamper layer.
2. `/aidev:init <language>` — profile, a seeded `docs/architecture/PROJECT.md`, then per-role
   runner/model/transport/skill choices.
3. **During init, fill the useful project brief context before confirming skills**: what/why, use cases,
   settled stack + why,
   hard constraints, non-goals, domain glossary, a rough ordered slice list, open questions.
   Keep it 1–2 pages: decisions and constraints, NOT designs — no module layouts or signatures
   (per-feature precision is produced BY the pipeline, through the architect interview).
4. **Bootstrap a runnable toolchain** (green baseline): the gate needs `CONFORMANCE_CMD`/`BEHAVIOR_CMD`
   to actually run — e.g. `pyproject.toml` + venv + one passing placeholder test, or a `pom.xml` /
   `build.sbt` skeleton. Ask the configured planner to scaffold it; verify the trusted global gate runs.
5. Commit the bootstrap.
6. `/aidev:feature <first-slice>` — start with a **walking skeleton** (thinnest end-to-end path).
   The interview is fast because the architect reads your brief and asks only what's missing.
7. `/aidev:build <first-slice>` → green. Repeat 6–7 per slice.

### 1 · Set up / onboard a project
`/aidev:init python` (or `java | scala | generic`) → creates `.aidev/`, asks the per-role runner/model/skill
assignments, writes `roles.json`, validates adapters, and creates native/relay overrides. Existing repo?
Tune `.aidev/profile.sh` to its real layout and keep a green baseline.

### 2 · Build a feature (greenfield)
`/aidev:feature parse-duration "…"` → live architect interview → ARCH doc + frozen contract + RED tests,
committed (git repos — this arms the anti-tamper layer). Then `/aidev:build parse-duration` →
implementer ⇄ reviewer until the orchestrator's own `GATE: PASS` + reviewer `PASS`.

### 3 · Existing codebase (brownfield)
Same commands. Architect + planner **survey existing code** and build the contract on top of it; existing
public APIs are fixed constraints. Keep a green baseline (or scope `BEHAVIOR_CMD`) so the gate measures the feature.

### 4 · Human checkpoints (agents ask, don't guess)
architect → **live interview + your sign-off on behavior, constraints, and technology decisions** (frequent
small check-ins, not one questionnaire); planner → **`## Decisions needed`** (stops before freezing on consequential choices);
build cell → escalation + 5-round cap back to you. Low-stakes internals are decided by the agents.

### 5 · Parallel build cells (one per independent component)
When a feature spans components that are **provably independent** — separated by a frozen boundary
(e.g. the `api/` headers) with disjoint writable areas and independently runnable gates — the
orchestrator MAY run one implementer per component in parallel (e.g. CSV, Parquet, and XLSX parsers;
or backend vs frontend). **Each parallel implementer gets its own reviewer**, reviewing against that
component's contract/tests; the orchestrator still owns the final cross-component gate run.
Lean conservative: parallelize only when independence is certain. Watch for hidden couplings —
shared build artifacts (one component's gate rebuilding another's tree mid-edit), tests that link
the other component's real implementation (those stay red until integration — list them, don't
chase them), and any shared writable file (disqualifying). When in doubt, one implementer.

### 6 · Change a frozen contract (joint request)
implementer drafts `.aidev/CHANGE-REQUEST.md` (evidence/measurements) → reviewer independently **co-signs**
(re-checking numbers) → planner (Mode B) adjudicates **default-REJECT**, approving only on infeasibility or a
substantial *measured* win → on approve edits contract + tests, writes `DECISION-<n>.md`, **re-freezes**.

### 7 · Another language
`/aidev:init java|scala|zig|swift|c-gtk` (compilers enforce conformance natively). Add a language by
dropping a profile in `.aidev/harness/profiles/<lang>.sh`.

### 8 · Polyglot / multi-component repos (e.g. Zig backend + SwiftUI + GTK frontends)
One profile per component, nested; the ROOT freezes the cross-language contract:
```
myapp/
├── .aidev/profile.sh          # 'workspace' profile — FROZEN_PATHS=(api); full gate chains the others
├── api/                       # language-NEUTRAL contract (C headers / .proto / OpenAPI) — frozen for ALL
├── backend/      + .aidev/    # zig profile
├── apps/macos/   + .aidev/    # swift profile
└── apps/linux/   + .aidev/    # c-gtk profile
```
Resolution is by NEAREST enclosing `.aidev` — the hook and gate both walk up — so the backend's rules
apply under `backend/`, and a write to `api/` from anywhere hits the root freeze. Run a component's gate
with `bash .aidev/harness/gate.sh <comp>`; the root gate checks `api/` integrity and chains every component
gate. Features that span components: one architect interview for the whole feature, then plan/build per
component against `api/`. Each component's gate runs where its toolchain lives (GTK behavior tests on
Linux — container or CI; macOS can still compile-check via brew gtk4).

**Multi-repo variant** — components as separate projects also works: each repo is a plain
single-language aidev project. The shared contract then lives in a dedicated contract repo (or is
owned + versioned by the backend), and each consumer repo pins a copy and lists it in its own
`FROZEN_PATHS` — local drift of the vendored contract becomes a gate failure; changes flow upstream
via the same joint Contract Change Request → planner process, released as a new contract version and bumped
deliberately. Trade-off: independent release cadence + per-platform CI, at the cost of multi-repo
dances for cross-cutting changes. Greenfield rule of thumb: start as a workspace monorepo while the
API churns (atomic changes); split later — nested components are already repo-shaped.

---

## Reference

### Profile schema (`<repo>/.aidev/profile.sh`)
```sh
LANG_NAME="Python"
ARCHITECTURE_PATHS=( "docs/architecture" )                       # signed design + technology decisions
FROZEN_PATHS=( "contracts" "tests" )                            # implementer may NOT touch (recursive)
IMPLEMENTATION_PATHS=( "src" )                                 # allowed implementation area
DEPENDENCY_PATHS=( "pyproject.toml" "uv.lock" )                 # planner-applied dependency/build setup
CONFORMANCE_CMD="mypy --no-error-summary src tests contracts"   # compiler/type-checker (empty = skip)
BEHAVIOR_CMD="python -m pytest -q"                              # test runner (required)
CONTRACT_HOWTO="…"                                              # language idiom guidance for the planner
```

The profile lists are common starting points, not automatic discovery. During `/aidev:init`, inventory every
actual manifest, lockfile, and dependency-bearing build file (including nested modules). Entries are literal
file or directory paths; globs are not supported. The gate enforces configured paths; the reviewer also checks
for unapproved dependency use that does not show up as a protected-file edit.

### Files & layout
```
~/.claude/
  agents/{architect,planner,implementer,reviewer}.md     # model: inherit (overridden per project)
  commands/aidev/{init,feature,build}.md
  aidev/
    gate.sh  freeze.sh  guard-contracts.sh  init.sh
    role-runner.sh       # validates/dispatches role assignments; relay/journal/verify-relay = verbatim relay chain
    adapters/*.sh        # trusted aidev-agent/v1 adapters + template for new agents
    set-models.sh        # generates native or generic relay overrides from roles.json
    architect.sh review.sh  # legacy compatibility wrappers
    CHANGE-REQUEST.template.md   README.md
    profiles/{python,java,scala,generic}.sh

<repo>/
  .aidev/
    profile.sh           # architecture + contract + dependency paths, conformance/behavior commands
    roles.json           # runner + model/settings + transport + confirmed skill sources for all roles
    models.conf          # legacy input to set-models; migrate to roles.json before feature/build
    gate.sh  freeze.sh   # thin shims → global drivers
    .frozen.sha256       # freeze snapshot
    CHANGE-REQUEST.md / DECISION-<n>.md
  .claude/agents/*.md    # generated native-model or external-relay overrides
  docs/architecture/ARCH-<feature>.md   contracts/   tests/   src/   review/REVIEW-<n>.md
```

### Enforcement layers (defense in depth)
1. **Hook** (`guard-contracts.sh`, scoped to the implementer) — allows normal writes only inside
   `IMPLEMENTATION_PATHS`; denies `ARCHITECTURE_PATHS`, `FROZEN_PATHS`, `DEPENDENCY_PATHS`, **and
   the harness itself** (`.aidev/*`: profile, roles, snapshot, shims, DECISION files) — except
   `.aidev/CHANGE-REQUEST.md`, the petition channel. No-op outside aidev projects.
2. **Conformance** — compiler/type-checker rejects signature drift even inside implementation files.
3. **Integrity** — snapshot of the configured protected surface, including generated role definitions:
   modified/added/deleted files are all caught.
4. **Git anti-tamper** — with the contract committed, even re-running `freeze.sh` to re-bless a tampered
   surface fails (drift vs HEAD); and history keeps an audit trail.
5. **Relay chain** — role→role messages move by reference through `role-runner.sh relay`; the hash
   ledger + `verify-relay` (chained into the gate with `--relay <run-id>`) fail the build if the
   orchestrator paraphrased, edited, or authored a handoff it should only have relayed.
Layers 2–4 hold even if the hook is unavailable.

**Threat model, honestly:** these layers make violations impossible for a *cooperative* agent and
multi-step + auditable for a determined one (the implementer does have Bash). For an absolute guarantee,
run the trusted global `gate.sh` in CI on the planner's contract commit — outside any agent's control.

### Caveats
- **Per-agent hooks**: if your Claude Code version ignores the `hooks:` block in `implementer.md`, enforcement still holds via layers 2 + 3.
- **External runners**: each adapter must pass doctor and a live probe for the assigned role. A choice that
  cannot provide required write/read-only behavior, authentication, exact model, transport, or skills is
  rejected with a concrete reason. Writer adapters must enforce `allowed_write_paths`; a prompt that merely
  asks the model to stay inside those paths is not sufficient.
- **Brownfield baseline**: a red existing suite fails the gate — establish a green baseline or scope `BEHAVIOR_CMD`.
- **Existing profiles**: `init.sh` deliberately preserves an existing `.aidev/profile.sh`. Add
  `ARCHITECTURE_PATHS=("docs/architecture")`, `IMPLEMENTATION_PATHS=(...)`, and literal
  `DEPENDENCY_PATHS=(...)` entries manually to older projects before the next planner freeze.
- **Shell**: scripts target bash 3.2 (macOS default) and `jq` (for the hook).
