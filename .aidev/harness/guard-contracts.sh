#!/usr/bin/env bash
# PreToolUse guard, scoped to the implementer agent via its frontmatter. Denies writes to:
#   (a) the frozen contract/test paths (FROZEN_PATHS),
#   (b) approved architecture documents (ARCHITECTURE_PATHS),
#   (c) dependency/build files owned by the planner (DEPENDENCY_PATHS), and
#   (d) the aidev harness itself (.aidev/* — profile, roles/models config, snapshot, shims, decisions),
#       EXCEPT .aidev/CHANGE-REQUEST.md, which is the implementer's petition channel.
# No-op outside aidev projects. NOTE: fail-fast layer; the trusted global gate driver is the authoritative backstop.
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
[ -z "$file" ] && exit 0
case "/${file#/}/" in
  *'/../'*|*'/./'*|*'//'*) deny "Unsafe non-canonical path — use a path without '.', '..', or repeated slash components." ;;
  *$'\n'*|*$'\r'*|*$'\t'*) deny "Unsafe path — control characters are not allowed." ;;
esac
case "$file" in /*) abs="$file";; *) abs="$(pwd -P)/$file";; esac

# When the hook runs from an aidev project, bind every write to that project
# before inspecting the target. An absolute path outside it must not turn the
# hook into its documented no-op behavior for genuinely unrelated directories.
root="$(pwd -P)"
while [ "$root" != "/" ] && [ ! -f "$root/.aidev/profile.sh" ]; do root="$(dirname "$root")"; done
if [ -f "$root/.aidev/profile.sh" ]; then
  case "$abs" in
    "$root"|"$root/"*) : ;;
    *) deny "Outside the current aidev project — implementers may write only configured in-project implementation paths." ;;
  esac
else
  root="$(dirname "$abs")"
  while [ "$root" != "/" ] && [ ! -f "$root/.aidev/profile.sh" ]; do root="$(dirname "$root")"; done
  [ -f "$root/.aidev/profile.sh" ] || exit 0
fi

# Conservatively reject writes through any existing symlink component. Otherwise
# an apparently allowed src/link/file could resolve outside the implementation area.
probe="$abs"
while [ "$probe" != "/" ]; do
  [ ! -L "$probe" ] || deny "Writes through symlinks are not allowed for the implementer; use the canonical in-project path."
  parent="$(dirname "$probe")"
  [ "$parent" != "$probe" ] || break
  probe="$parent"
done

rel="${abs#$root/}"
case "$rel" in
  .aidev/CHANGE-REQUEST.md) exit 0 ;;  # the one harness file the implementer MAY write
  .aidev/*) deny "aidev harness file (profile/models/snapshot/gate/decisions) — the implementer may not reconfigure or re-bless its own enforcement. Petition via .aidev/CHANGE-REQUEST.md instead." ;;
  .claude/agents/*) deny "Generated aidev role definition — the implementer may not change its own or another role's authority." ;;
esac

# Keep project profile control flow inside a child and import only path arrays.
profile_dump="$(/bin/bash --noprofile --norc -c '
  set -uo pipefail
  . "$1" >/dev/null
  for v in FROZEN_PATHS ARCHITECTURE_PATHS DEPENDENCY_PATHS IMPLEMENTATION_PATHS; do
    declare -p "$v" 2>/dev/null || true
  done
' _ "$root/.aidev/profile.sh")" || deny "The aidev profile could not be loaded safely; writes are blocked until it is repaired."
case "$profile_dump" in
  *"declare -a FROZEN_PATHS="*) : ;;
  *) deny "The aidev profile does not define FROZEN_PATHS; writes are blocked until it is repaired." ;;
esac
eval "$profile_dump"

for p in "${FROZEN_PATHS[@]}"; do
  case "$abs" in
    "$root/$p"|"$root/$p/"*)
      deny "Frozen contract/test path — implementers may not change signatures, types, or tests. If the contract is truly infeasible (or a large quantified win is possible), write .aidev/CHANGE-REQUEST.md and get the reviewer to co-sign."
      ;;
  esac
done
if declare -p ARCHITECTURE_PATHS >/dev/null 2>&1; then
  for p in "${ARCHITECTURE_PATHS[@]}"; do
    case "$abs" in
      "$root/$p"|"$root/$p/"*)
        deny "Approved architecture path — implementers may not change signed requirements or technology decisions. Raise a Contract Change Request for architect + human review."
        ;;
    esac
  done
fi
if declare -p DEPENDENCY_PATHS >/dev/null 2>&1; then
  for p in "${DEPENDENCY_PATHS[@]}"; do
    case "$abs" in
      "$root/$p"|"$root/$p/"*)
        deny "Protected dependency manifest/lockfile — the planner owns approved dependency changes. Implementers may not add or replace production dependencies; raise a change request if the approved architecture must change."
        ;;
    esac
  done
fi
if declare -p IMPLEMENTATION_PATHS >/dev/null 2>&1; then
  for p in "${IMPLEMENTATION_PATHS[@]}"; do
    case "$abs" in
      "$root/$p"|"$root/$p/"*) exit 0 ;;
    esac
  done
  deny "Outside configured implementation paths — implementers may write only IMPLEMENTATION_PATHS or .aidev/CHANGE-REQUEST.md. Ask the planner to prepare setup changes."
fi
exit 0
