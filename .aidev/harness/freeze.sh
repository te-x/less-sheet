#!/usr/bin/env bash
# Snapshot the protected surface (architecture + contract + tests + dependency/build files): file LIST + content hashes.
#   freeze.sh [dir]            — write the snapshot (run by the PLANNER after authoring/amending)
#   freeze.sh --verify [dir]   — recompute and compare against the snapshot (used by the gate);
#                                catches MODIFIED, ADDED, and DELETED files under protected paths.
set -uo pipefail
mode="freeze"
start="$PWD"
for a in "$@"; do
  case "$a" in
    --verify) mode="verify" ;;
    *) start="$a" ;;
  esac
done
root="$start"
while [ "$root" != "/" ] && [ ! -f "$root/.aidev/profile.sh" ]; do root="$(dirname "$root")"; done
[ -f "$root/.aidev/profile.sh" ] || { echo "no .aidev/profile.sh (run /aidev:init)"; exit 2; }
cd "$root"

# Load only declared profile values from a child shell. A profile containing
# `exit 0` must not terminate this trusted driver successfully.
profile_dump="$(/bin/bash --noprofile --norc -c '
  set -uo pipefail
  . "$1" >/dev/null
  for v in FROZEN_PATHS ARCHITECTURE_PATHS DEPENDENCY_PATHS; do
    declare -p "$v" 2>/dev/null || true
  done
' _ "$PWD/.aidev/profile.sh")" || { echo "freeze: profile could not be loaded safely" >&2; exit 2; }
case "$profile_dump" in
  *"declare -a FROZEN_PATHS="*) : ;;
  *) echo "freeze: profile did not define FROZEN_PATHS" >&2; exit 2 ;;
esac
eval "$profile_dump"

snap=".aidev/.frozen.sha256"
# These files control enforcement/role assignment, so they are protected independently of profile contents.
protected_paths=(
  ".aidev/profile.sh" ".aidev/roles.json" ".aidev/models.conf" ".aidev/harness"
  ".claude/agents/architect.md" ".claude/agents/planner.md"
  ".claude/agents/implementer.md" ".claude/agents/reviewer.md"
  "${FROZEN_PATHS[@]}"
)
if declare -p ARCHITECTURE_PATHS >/dev/null 2>&1; then
  set +u; protected_paths+=("${ARCHITECTURE_PATHS[@]}"); set -u
fi
if declare -p DEPENDENCY_PATHS >/dev/null 2>&1; then
  # Bash 3.2 + nounset rejects expansion of an empty array; profiles may intentionally define one.
  set +u; protected_paths+=("${DEPENDENCY_PATHS[@]}"); set -u
fi
for p in "${protected_paths[@]}"; do
  case "$p" in
    ''|/*|-*|.|./*|..|../*|*/../*|*/..|*/./*|*/.|*//*) echo "freeze: protected paths must be canonical project-relative paths: $p" >&2; exit 2 ;;
    *$'\n'*|*$'\r'*|*$'\t'*) echo "freeze: protected paths may not contain control characters" >&2; exit 2 ;;
    *"*"*|*"?"*|*"["*) echo "freeze: profile paths must be literal (no globs): $p" >&2; exit 2 ;;
  esac
  probe="$p"
  while [ "$probe" != "." ] && [ "$probe" != "/" ]; do
    [ ! -L "$probe" ] || { echo "freeze: protected paths may not traverse symlinks: $p" >&2; exit 2; }
    parent="$(dirname "$probe")"
    [ "$parent" != "$probe" ] || break
    probe="$parent"
  done
done

compute() {  # full snapshot (sorted file list + hashes) to stdout
  existing=()
  for p in "${protected_paths[@]}"; do [ -e "$p" ] && existing+=("$p"); done
  [ "${#existing[@]}" -gt 0 ] || return 0
  find "${existing[@]}" -type f 2>/dev/null | LC_ALL=C sort | while read -r f; do
    shasum -a 256 "$f"
  done
}

if [ "$mode" = "verify" ]; then
  [ -f "$snap" ] || { echo "verify: no snapshot ($snap) — the planner must run freeze.sh first"; exit 2; }
  cur="$(mktemp "${TMPDIR:-/tmp}/aidev-snap.XXXXXX")"
  compute > "$cur"
  if ! d="$(diff "$snap" "$cur")"; then
    echo "frozen surface drift (modified, added, or deleted files):"
    printf '%s\n' "$d" | sed -n 's/^[<>]/  &/p' | head -20
    rm -f "$cur"
    exit 1
  fi
  rm -f "$cur"
  exit 0
fi

compute > "$snap"
n="$(grep -c . "$snap" 2>/dev/null || true)"; [ -n "$n" ] || n=0
echo "Froze ${n} file(s) over [${protected_paths[*]}] -> $snap"
