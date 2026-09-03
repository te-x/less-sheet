#!/usr/bin/env bash
# aidev gate — the authoritative, language-agnostic enforcement.
# Reads the current project's .aidev/profile.sh. Exit 0 only when:
#   1)  the protected surface (architecture/contract/tests/dependency setup) matches the snapshot
#   1b) (git repos with a committed snapshot) protected paths show no drift vs HEAD —
#       catches "tamper + re-freeze" re-blessing of the snapshot
#   2)  conformance (compiler/type-checker) passes
#   2b) (optional) QUALITY_CMD — deterministic strict lint/quality checks pass, when the profile sets it
#   3)  behavior tests pass
#   4)  (--relay <run-id>) the relay chain verifies — every role→role handoff in that run was a
#       byte-exact, ledgered relay assembled by role-runner from references, not orchestrator text
# Usage: gate.sh [--require-frozen] [--relay <run-id>] [project-dir]
set -uo pipefail
AIDEV_HOME="${AIDEV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
require_frozen=0
relay_run=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-frozen) require_frozen=1; shift ;;
    --relay)
      relay_run="${2:-}"
      case "$relay_run" in ''|*[!A-Za-z0-9._-]*) echo "GATE: --relay needs a valid run-id" >&2; exit 2 ;; esac
      shift 2 ;;
    *) break ;;
  esac
done
start="${1:-$PWD}"
root="$start"
while [ "$root" != "/" ] && [ ! -f "$root/.aidev/profile.sh" ]; do root="$(dirname "$root")"; done
if [ ! -f "$root/.aidev/profile.sh" ]; then echo "GATE: no .aidev/profile.sh found (run /aidev:init)"; exit 2; fi
cd "$root"
[ -d .venv/bin ] && PATH="$PWD/.venv/bin:$PATH"
fail() { echo "GATE: FAIL — $1"; exit 1; }

control_paths=(
  ".aidev/profile.sh" ".aidev/roles.json" ".aidev/models.conf" ".aidev/harness" ".aidev/.frozen.sha256"
  ".claude/agents/architect.md" ".claude/agents/planner.md"
  ".claude/agents/implementer.md" ".claude/agents/reviewer.md"
)

# Verify control files BEFORE loading project-supplied commands.
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"
  if git cat-file -e "HEAD:${prefix}.aidev/.frozen.sha256" 2>/dev/null; then
    git diff --quiet HEAD -- "${control_paths[@]}" 2>/dev/null \
      || fail "harness/profile/role controls differ from the committed frozen baseline."
    untracked_controls="$(git ls-files --others --exclude-standard -- "${control_paths[@]}" 2>/dev/null)"
    [ -z "$untracked_controls" ] \
      || fail "untracked harness/profile/role controls: $(printf '%s' "$untracked_controls" | tr '\n' ' ')"
  fi
fi

if [ -f .aidev/.frozen.sha256 ]; then
  expected_profile="$(awk '$2 == ".aidev/profile.sh" {print $1; exit}' .aidev/.frozen.sha256)"
  [ -n "$expected_profile" ] \
    || fail "snapshot does not protect .aidev/profile.sh; refreeze with the current aidev before building."
  actual_profile="$(shasum -a 256 .aidev/profile.sh | awk '{print $1}')"
  [ "$actual_profile" = "$expected_profile" ] || fail "profile changed before it could be loaded."
elif [ "$require_frozen" -eq 1 ]; then
  fail "no frozen baseline; run /aidev:feature and commit the planner freeze before /aidev:build."
fi

# Source in a child so a profile cannot exit this trusted process; import only fixed variables.
profile_dump="$(/bin/bash --noprofile --norc -c '
  set -uo pipefail
  . "$1" >/dev/null
  for v in LANG_NAME ARCHITECTURE_PATHS FROZEN_PATHS DEPENDENCY_PATHS IMPLEMENTATION_PATHS CONFORMANCE_CMD QUALITY_CMD BEHAVIOR_CMD CONTRACT_HOWTO; do
    declare -p "$v" 2>/dev/null || true
  done
' _ "$PWD/.aidev/profile.sh")" || fail "profile could not be loaded safely."
case "$profile_dump" in *"declare -a FROZEN_PATHS="*) : ;; *) fail "profile did not define FROZEN_PATHS." ;; esac
case "$profile_dump" in *"CONFORMANCE_CMD="*) : ;; *) fail "profile did not define CONFORMANCE_CMD." ;; esac
case "$profile_dump" in *"BEHAVIOR_CMD="*) : ;; *) fail "profile did not define BEHAVIOR_CMD." ;; esac
eval "$profile_dump"

# Never let a writable agent weaken commands/paths, swap a role, or rewrite generated role definitions.
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
  set +u; protected_paths+=("${DEPENDENCY_PATHS[@]}"); set -u
fi
for p in "${protected_paths[@]}"; do
  case "$p" in
    ''|/*|-*|.|./*|..|../*|*/../*|*/..|*/./*|*/.|*//*) echo "GATE: configuration error — protected paths must be canonical project-relative paths: $p" >&2; exit 2 ;;
    *$'\n'*|*$'\r'*|*$'\t'*) echo "GATE: configuration error — protected paths may not contain control characters." >&2; exit 2 ;;
    *"*"*|*"?"*|*"["*) echo "GATE: configuration error — profile paths must be literal (no globs): $p" >&2; exit 2 ;;
  esac
  probe="$p"
  while [ "$probe" != "." ] && [ "$probe" != "/" ]; do
    [ ! -L "$probe" ] || { echo "GATE: configuration error — protected paths may not traverse symlinks: $p" >&2; exit 2; }
    parent="$(dirname "$probe")"
    [ "$parent" != "$probe" ] || break
    probe="$parent"
  done
done

# 1) integrity — frozen surface identical to the snapshot (catches modified, ADDED, and deleted files)
if [ -f .aidev/.frozen.sha256 ]; then
  bash "$AIDEV_HOME/freeze.sh" --verify "$PWD" \
    || fail "protected harness/architecture/contract/test/dependency files changed — use the approved init, architect, or planner flow."
else
  echo "GATE: note — no freeze snapshot yet (planner runs the trusted global freeze driver)."
fi

# 1b) git anti-tamper layer — a re-blessed snapshot still differs from the committed contract
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"
  if git cat-file -e "HEAD:${prefix}.aidev/.frozen.sha256" 2>/dev/null; then
    git diff --quiet HEAD -- "${protected_paths[@]}" .aidev/.frozen.sha256 2>/dev/null \
      || fail "protected paths (or the snapshot) differ from the committed baseline at HEAD — the planner must amend AND commit them."
    untracked="$(git ls-files --others --exclude-standard -- "${protected_paths[@]}" 2>/dev/null)"
    [ -z "$untracked" ] || fail "untracked files under protected paths: $(printf '%s' "$untracked" | tr '\n' ' ')"
  else
    echo "GATE: note — snapshot not committed yet; git anti-tamper layer inactive (commit the contract to arm it)."
  fi
else
  echo "GATE: note — not a git repo (or no commits); git anti-tamper layer inactive."
fi

# 2) conformance — implementation matches the declared types/signatures
if [ -n "${CONFORMANCE_CMD:-}" ]; then
  echo "GATE: conformance -> $CONFORMANCE_CMD"
  eval "$CONFORMANCE_CMD" || fail "conformance check failed."
fi

# 2b) quality — optional deterministic lint/quality commands (QUALITY_CMD in .aidev/profile.sh).
# This is the gate-tier slice of code quality: strict linters, format checks, complexity caps.
if [ -n "${QUALITY_CMD:-}" ]; then
  echo "GATE: quality -> $QUALITY_CMD"
  eval "$QUALITY_CMD" || fail "quality checks failed."
fi

# 3) behavior — the spec tests pass
if [ -z "${BEHAVIOR_CMD:-}" ]; then fail "BEHAVIOR_CMD not set in .aidev/profile.sh"; fi
echo "GATE: behavior -> $BEHAVIOR_CMD"
eval "$BEHAVIOR_CMD" || fail "behavior tests failed."

# 4) relay chain — role→role handoffs in this run were verbatim (assembled by reference, hash-verified)
if [ -n "$relay_run" ]; then
  echo "GATE: relay -> verify-relay $relay_run"
  bash "$AIDEV_HOME/role-runner.sh" verify-relay "$relay_run" "$PWD" \
    || fail "relay chain verification failed — a role→role handoff was not a verbatim, ledgered relay."
fi

echo "GATE: PASS"
