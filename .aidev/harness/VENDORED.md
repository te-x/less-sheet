# Vendored aidev harness

This directory is a copy of the aidev pipeline harness (roles + deterministic gate), vendored into the
repository so that a fresh clone can run the gate, the freeze, the role runner and the `/aidev:*`
commands with nothing installed at user level. The wrappers `.aidev/gate.sh` and `.aidev/freeze.sh`
(root and per component) exec this copy first and fall back to `~/.claude/aidev/` only if it is gone.

## What differs from a user-level install
- Every script locates the harness by its own path (`AIDEV_HOME` defaults to this directory; it can
  still be overridden in the environment). The canonical role charters live in `agents/` here, the
  slash commands in `.claude/commands/aidev/`.
- The legacy external-runner scripts and adapters are not included: every role in this project runs on
  the native Claude runner (`.aidev/roles.json`), which needs no adapter. `adapters/` keeps only the
  template and its README for anyone who adds one.
- Paths in the documentation point at the in-repo locations.

## Updating the copy
Copy the upstream files over these, then re-apply the self-location edits (the `AIDEV_HOME` defaults at
the top of `gate.sh`, `init.sh`, `role-runner.sh`, `set-models.sh`; the charter path in
`role-runner.sh`; the in-repo paths in the docs, the commands and the charters), regenerate
`.claude/agents/` with `bash .aidev/harness/set-models.sh .`, re-pin the root baseline with
`bash .aidev/freeze.sh .`, and commit. The harness is a protected path: the gate fails on any
uncommitted change to it.
