#!/usr/bin/env bash
# Generate project-level agent overrides from .aidev/roles.json (preferred) or legacy models.conf.
# Native Claude roles get model/effort frontmatter; external roles get provider-neutral relay wrappers.
# Nothing is enforced globally — this only writes <project>/.claude/agents/ which shadow the
# user-level agents for THIS project. Optional arg $1 = project dir (defaults to $PWD).
set -euo pipefail
AIDEV_HOME="${AIDEV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
GLOBAL_AGENTS="$AIDEV_HOME/agents"
proj="${1:-$PWD}"
roles="$proj/.aidev/roles.json"
conf="$proj/.aidev/models.conf"
[ -f "$roles" ] || [ -f "$conf" ] || { echo "set-models: no $roles or legacy $conf (run /aidev:init first)"; exit 2; }
if [ ! -f "$roles" ]; then
  # shellcheck disable=SC1091
  . "$conf"
fi
mkdir -p "$proj/.claude/agents"
OUTPUT_DIR="$proj/.claude/agents"

write_override() {  # <role> <model> <effort> [skills-json]
  role="$1"; model="$2"; effort="$3"; skills="${4:-[]}"
  srcf="$GLOBAL_AGENTS/$role.md"
  [ -f "$srcf" ] || { echo "set-models: required canonical role file is missing: $srcf" >&2; return 2; }
  MODEL="$model" EFFORT="$effort" SKILLS="$skills" awk '
    BEGIN { infm=0; fence=0; injected=0 }
    /^---[[:space:]]*$/ {
      fence++; print
      if (fence==1) infm=1; else if (fence==2) infm=0
      next
    }
    {
      if (infm) {
        if ($0 ~ /^model:/)  next
        if ($0 ~ /^effort:/) next
        if ($0 ~ /^skills:/) next
        print
        if ($0 ~ /^name:/ && !injected) {
          print "model: " ENVIRON["MODEL"]
          if (ENVIRON["EFFORT"] != "") print "effort: " ENVIRON["EFFORT"]
          if (ENVIRON["SKILLS"] != "[]") print "skills: " ENVIRON["SKILLS"]
          injected=1
        }
        next
      }
      print
    }
  ' "$srcf" > "$OUTPUT_DIR/$role.md"
  echo "  $role -> model=$model effort=${effort:-(default)}"
}

write_external_wrapper() {  # <role> <runner> <model> <skills-json>
  role="$1"; runner="$2"; model="$3"; skills="$4"
  cat > "$OUTPUT_DIR/$role.md" <<EOF
---
name: $role
description: Generated relay for an external aidev role runner.
model: inherit
tools: Read, Bash
---
<!-- generated-by: aidev roles.json -->
This project assigns **$role** to the external runner **$runner** (model: **${model:-adapter default}**;
preloaded skills: **$skills**).
Do not perform the $role role yourself and do not substitute the current Claude model. The active aidev
workflow must invoke it through:

\`bash .aidev/harness/role-runner.sh run $role <start|resume> <run-id> <prompt-file> <project-dir>\`

Read the normalized response and relay the external agent's message verbatim. If its doctor/invocation
fails, explain the concrete reason and ask the user to choose or configure another runner/model.
EOF
  echo "  $role -> external runner=$runner model=${model:-adapter default}"
}

if [ -f "$roles" ]; then
  jq -e '.schema == 1 and (.roles | type == "object")' "$roles" >/dev/null \
    || { echo "set-models: invalid $roles"; exit 2; }
  bash "$AIDEV_HOME/role-runner.sh" doctor "$proj"
  echo "Applying per-role runners for: $proj"
  generated="$(mktemp -d "${TMPDIR:-/tmp}/aidev-agents.XXXXXX")"
  trap 'rm -rf "$generated"' EXIT HUP INT TERM
  OUTPUT_DIR="$generated"
  for role in architect planner implementer reviewer; do
    runner="$(jq -r --arg r "$role" '.roles[$r].runner // empty' "$roles")"
    model="$(jq -r --arg r "$role" '.roles[$r].model // ""' "$roles")"
    effort="$(jq -r --arg r "$role" '.roles[$r].settings.effort // ""' "$roles")"
    skills="$(jq -c --arg r "$role" '.roles[$r].skills // []' "$roles")"
    if [ "$runner" = "claude-native" ]; then
      write_override "$role" "${model:-inherit}" "$effort" "$skills"
    else
      write_external_wrapper "$role" "$runner" "$model" "$skills"
    fi
  done
  for role in architect planner implementer reviewer; do
    [ -s "$generated/$role.md" ] || { echo "set-models: generation did not produce $role.md" >&2; exit 2; }
  done
  for role in architect planner implementer reviewer; do
    mv "$generated/$role.md" "$proj/.claude/agents/$role.md"
  done
  rm -rf "$generated"
  trap - EXIT HUP INT TERM
  echo "Done. Role assignments come from $roles."
  echo "Restart the Claude Code session before dispatching native project agents so these definitions reload."
  exit 0
fi

echo "Applying legacy per-role models for: $proj"
write_override architect "${ARCHITECT_MODEL:-inherit}" "${ARCHITECT_EFFORT:-}"
write_override planner     "${PLANNER_MODEL:-inherit}"     "${PLANNER_EFFORT:-}"
write_override implementer "${IMPLEMENTER_MODEL:-inherit}" "${IMPLEMENTER_EFFORT:-}"

write_override reviewer "${REVIEWER_MODEL:-inherit}" "${REVIEWER_EFFORT:-}"

echo "Done. Project-level overrides in $proj/.claude/agents/ now shadow the global agents for this project."
echo "Restart the Claude Code session before dispatching native project agents so these definitions reload."
