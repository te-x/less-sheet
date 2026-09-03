# aidev external-agent adapters

Adapters let any role use an agent that is not a native Claude Code subagent. A project names only a
trusted runner ID in `.aidev/roles.json`; executable code stays here, under the user's aidev install.

Copy `ADAPTER.template.sh` to `<runner-id>.sh`. Runner IDs use letters, digits, dot, underscore, and dash.
The executable implements `aidev-agent/v1`:

## `describe`

Print one JSON object:

```json
{
  "protocol": "aidev-agent/v1",
  "kind": "external",
  "roles": ["*"],
  "repo_access": ["read-only", "workspace-write"],
  "write_scope": ["allowed-paths"],
  "continuity": ["resume"],
  "human_io": ["relay"],
  "web_research": true
}
```

Use only capabilities the adapter actually enforces. `continuity` may contain `resume` (same live session)
or `replay` (cold invocation using the provided durable transcript). Human interaction is relayed by the
orchestrator, so supported interview-capable adapters declare `human_io: ["relay"]`.

Writable roles must also declare `write_scope: ["allowed-paths"]` when their sandbox directly enforces the
request's paths, or `write_scope: ["isolated-promotion"]` when they work in isolation and promote only a
validated allowed-path patch. A general workspace-write sandbox plus a prompt is not sufficient.

## `doctor <request.json>`

Check the chosen binary/API, authentication, opaque model/settings, and role-specific permissions. Return:

```json
{"ok":true,"reason":"ready"}
```

or fail with a concrete reason such as missing executable, invalid model, authentication failure, no writable
mode, or no enforceable read-only review mode. Static doctor checks do not claim that an opaque model exists.
Aidev asks the user to repair the issue or select another runner/model; an adapter must never select a fallback
model silently.

During init, research the most efficient reliable transport for the actual runner combination: native
messages, a resumable CLI session, ACP/server API, structured stdout, transcript replay, or a file bridge.
Implement that method here and report it honestly from `describe`.

Each role selects one transport explicitly in `.aidev/roles.json`: `resume` or `replay` for external adapters,
and `native` for Claude-native roles. The selected transport must appear in the adapter's `continuity` list.

## `probe <request.json>`

Make a minimal live, read-only request using the exact configured model and settings. Validate the configured
transport with a second turn that must recall a nonce through resume or durable replay. Return
`{"ok":true,"reason":"..."}` or a specific failure. Init runs probes after static doctor checks; do not
silently retry with a different model or transport.

## `invoke <request.json> <response.json>`

The request includes:

- `action`: `start` or `resume`, the selected `transport`, `previous_session_id`, a prior response path,
  and a durable `transcript_file` for replay adapters;
- opaque `model` and `settings`;
- `workspace`, `access`, `allowed_write_paths`, and role-specific `denied_write_paths` (deny wins when
  an implementation directory contains a nested frozen/contract path);
- canonical `charter_file` and turn-specific `prompt_file`;
- final, user-approved `skills`, their explicit `skill_sources`, a resolved text bundle, and `skill_packages`
  with canonical `SKILL.md` files, package roots, and hashes so referenced scripts/assets remain available;
- adapter state/output paths under a private state root outside both the project and executable install;
- `invocation_id`, `role`, `run_id`, `config_hash`, and `input_tree_hash` bindings.

Enforce the requested access. Use the same session on `resume`, or replay durable state when the adapter
declares `replay`. Write the final Markdown message to `output_file`, then write:

```json
{
  "protocol": "aidev-agent/v1",
  "invocation_id": "echo from request",
  "role": "reviewer",
  "run_id": "feature-123",
  "transport": "resume",
  "config_hash": "echo from request",
  "input_tree_hash": "echo from request",
  "status": "completed",
  "message_file": "/absolute/path/to/message.md",
  "session_id": "opaque-session-id"
}
```

`status` may also be `needs_input` or `failed`; failures include `reason`. Provider output is never accepted as
proof that the gate passes—the orchestrator runs the trusted global gate itself. Aidev rejects responses whose
bindings or output path do not exactly match the request. The canonical charter is mandatory on every turn; an
adapter must not weaken it or encourage gaming another role's checkpoint.

## Skill sources

`skills` is the user-approved list for a role. Optional `skill_sources` entries bind a name to the intended
canonical `SKILL.md` using an absolute path or a project-relative path resolved from the repository root:

```json
{"skills":["geometry"],"skill_sources":{"geometry":".agents/skills/geometry/SKILL.md"}}
```

Bare names are accepted only when exactly one installed/project source matches. Ambiguous names fail with the
candidate paths so init can ask the user to choose. Claude-native roles additionally require a source Claude
Code can preload by that name (`.claude/skills`, `~/.claude/skills`, or a plugin namespace).
