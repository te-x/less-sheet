#!/usr/bin/env bash
# Initialize the aidev pipeline in a project. Non-destructive.
# Usage: init.sh <language> [project_dir]   (language: python|java|scala|generic)
set -euo pipefail
AIDEV_HOME="${AIDEV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
lang="${1:-generic}"
proj="${2:-$PWD}"
src="$AIDEV_HOME/profiles/${lang}.sh"

if [ ! -f "$src" ]; then
  echo "Unknown language '$lang'. Available:"
  ls "$AIDEV_HOME/profiles" | sed 's/\.sh$//' | sed 's/^/  - /'
  exit 1
fi

mkdir -p "$proj/.aidev" "$proj/docs/architecture" "$proj/review"

if [ -f "$proj/.aidev/profile.sh" ]; then
  echo "note: .aidev/profile.sh already exists — leaving it untouched."
else
  cp "$src" "$proj/.aidev/profile.sh"
fi
cp -f "$AIDEV_HOME/CHANGE-REQUEST.template.md" "$proj/.aidev/CHANGE-REQUEST.template.md"

if [ ! -f "$proj/docs/architecture/PROJECT.md" ]; then
  cp "$AIDEV_HOME/PROJECT-BRIEF.template.md" "$proj/docs/architecture/PROJECT.md"
  echo "  seeded docs/architecture/PROJECT.md — fill in the project brief; architect & planner read it first"
fi

write_wrapper() {  # <script> <dest>: prefer a harness vendored in the repo, else a user-level install
  cat > "$2" <<WRAP
#!/usr/bin/env bash
# Thin wrapper: run the aidev harness vendored in this repository (.aidev/harness/), so a fresh
# clone needs nothing installed; fall back to a user-level install only if the vendored copy is gone.
d="\$(cd "\$(dirname "\$0")/.." && pwd -P)"
while [ "\$d" != "/" ] && [ ! -f "\$d/.aidev/harness/$1" ]; do d="\$(dirname "\$d")"; done
h="\$d/.aidev/harness/$1"; [ -f "\$h" ] || h="\$HOME/.claude/aidev/$1"
exec bash "\$h" "\$@"
WRAP
}
write_wrapper gate.sh   "$proj/.aidev/gate.sh"
write_wrapper freeze.sh "$proj/.aidev/freeze.sh"
chmod +x "$proj/.aidev/gate.sh" "$proj/.aidev/freeze.sh"

if [ ! -f "$proj/.claude/settings.json" ]; then
  mkdir -p "$proj/.claude"
  cat > "$proj/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(bash .aidev/gate.sh)",
      "Bash(bash .aidev/gate.sh:*)",
      "Bash(bash .aidev/freeze.sh)",
      "Bash(bash .aidev/freeze.sh:*)",
      "Bash(bash .aidev/harness/gate.sh:*)",
      "Bash(bash .aidev/harness/freeze.sh:*)",
      "Bash(bash .aidev/harness/role-runner.sh:*)",
      "Bash(bash .aidev/harness/set-models.sh:*)"
    ]
  }
}
JSON
  echo "  wrote .claude/settings.json (gate/freeze run without permission prompts)"
else
  echo "  note: .claude/settings.json exists — leaving it untouched (allow the trusted global gate/freeze/role-runner commands if prompted)."
fi

# Read only the profile data that init needs. Run the project-controlled file in a child shell so
# `exit`, traps, shell options, or functions in an old/broken profile cannot take over this driver.
profile_dump="$(bash -c '
  set -e
  # shellcheck disable=SC1090
  . "$1" >&2
  for v in LANG_NAME ARCHITECTURE_PATHS FROZEN_PATHS DEPENDENCY_PATHS IMPLEMENTATION_PATHS CONFORMANCE_CMD QUALITY_CMD BEHAVIOR_CMD CONTRACT_HOWTO; do
    declare -p "$v" 2>/dev/null || true
  done
' bash "$proj/.aidev/profile.sh")" || {
  echo "init: could not load .aidev/profile.sh" >&2
  exit 2
}
eval "$profile_dump"
for required in LANG_NAME FROZEN_PATHS CONFORMANCE_CMD BEHAVIOR_CMD; do
  declare -p "$required" >/dev/null 2>&1 || {
    echo "init: .aidev/profile.sh did not declare required value $required" >&2
    exit 2
  }
done
for p in "${FROZEN_PATHS[@]}"; do
  case "$(basename "$p")" in
    *.*) : ;;                      # file-like entry (e.g. Package.swift) — don't mkdir a dir for it
    *)   mkdir -p "$proj/$p" ;;
  esac
done

dependency_summary="(not configured)"
if declare -p DEPENDENCY_PATHS >/dev/null 2>&1; then
  set +u; dependency_summary="${DEPENDENCY_PATHS[*]:-(none configured)}"; set -u
fi
architecture_summary="(not configured)"
if declare -p ARCHITECTURE_PATHS >/dev/null 2>&1; then
  set +u; architecture_summary="${ARCHITECTURE_PATHS[*]:-(none configured)}"; set -u
fi
implementation_summary="(not configured)"
if declare -p IMPLEMENTATION_PATHS >/dev/null 2>&1; then
  set +u; implementation_summary="${IMPLEMENTATION_PATHS[*]:-(none configured)}"; set -u
fi

echo
echo "aidev ready in: $proj"
echo "  language     : ${LANG_NAME}"
echo "  frozen paths : ${FROZEN_PATHS[*]}"
echo "  architecture paths: ${architecture_summary}"
echo "  dependency paths: ${dependency_summary}"
echo "  implementation paths: ${implementation_summary}"
echo "  conformance  : ${CONFORMANCE_CMD:-(none)}"
echo "  quality      : ${QUALITY_CMD:-(none — optional strict lint; see QUALITY_CMD in the profile)}"
echo "  behavior     : ${BEHAVIOR_CMD}"
echo
echo "Review .aidev/profile.sh so all literal ARCHITECTURE_PATHS + FROZEN_PATHS + DEPENDENCY_PATHS + IMPLEMENTATION_PATHS and commands match the real project (no globs)."
if [ ! -f "$proj/.aidev/roles.json" ] && [ ! -f "$proj/.aidev/models.conf" ]; then
  echo "Next: finish /aidev:init role runner, model, transport, and skill setup; then run role-runner doctor."
else
  echo "Next: validate role assignments, then /aidev:feature <description>"
fi
