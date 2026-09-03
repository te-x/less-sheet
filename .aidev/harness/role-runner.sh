#!/usr/bin/env bash
# Provider-neutral role dispatcher. Projects select trusted adapter IDs, opaque models,
# transports, and skills in .aidev/roles.json. Executable adapters stay outside the repo.
set -euo pipefail

AIDEV_HOME="${AIDEV_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
AIDEV_STATE_ROOT="${AIDEV_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/aidev}"
PROTOCOL="aidev-agent/v1"
umask 077

die() { echo "role-runner: $*" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
usage:
  role-runner.sh inspect <role> [project-dir]
  role-runner.sh doctor [project-dir]
  role-runner.sh probe [project-dir]
  role-runner.sh tree-hash [project-dir]
  role-runner.sh run <role> <start|resume> <run-id> <prompt-file> [project-dir]
  role-runner.sh relay <role> <start|resume> <run-id> [project-dir] \
      --from <role>:<run-id>:<turn> [--from ...] [--human <file>] [--note <label> <file>]
  role-runner.sh journal <role> <run-id> message <reply-file> [project-dir]
  role-runner.sh verify-relay <run-id> [project-dir]
  role-runner.sh last <role> <run-id> [project-dir]

Roles: architect | planner | implementer | reviewer

relay assembles the next prompt ITSELF from references — the orchestrator supplies
pointers to prior role messages (--from), human input (--human), and labeled
orchestration context (--note); it cannot alter role message bytes. verify-relay
re-derives every prompt from its ledgered sources and fails on any drift.
EOF
  exit 2
}

valid_role() {
  case "$1" in architect|planner|implementer|reviewer) return 0 ;; *) return 1 ;; esac
}

find_root() {
  local root="$1"
  [ -d "$root" ] || die "project directory not found: $root"
  root="$(cd "$root" && pwd -P)"
  while [ "$root" != "/" ] && [ ! -f "$root/.aidev/profile.sh" ]; do root="$(dirname "$root")"; done
  [ -f "$root/.aidev/profile.sh" ] || die "no .aidev/profile.sh (run /aidev:init)"
  printf '%s\n' "$root"
}

project_key() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
}

load_profile_declarations() {
  local root="$1" output line assignments=""
  output="$(mktemp "${TMPDIR:-/tmp}/aidev-profile.XXXXXX")"
  if ! /bin/bash --noprofile --norc -c '
    set -eu
    : > "$2"
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    for name in LANG_NAME ARCHITECTURE_PATHS FROZEN_PATHS DEPENDENCY_PATHS IMPLEMENTATION_PATHS; do
      if builtin declare -p "$name" >/dev/null 2>&1; then
        builtin declare -p "$name" >> "$2"
      fi
    done
  ' aidev-profile "$root/.aidev/profile.sh" "$output"; then
    rm -f "$output"
    die "profile could not be evaluated in the isolated loader: $root/.aidev/profile.sh"
  fi
  while IFS= read -r line; do
    case "$line" in
      declare\ -*\ LANG_NAME=*|declare\ -*\ ARCHITECTURE_PATHS=*|declare\ -*\ FROZEN_PATHS=*|declare\ -*\ DEPENDENCY_PATHS=*|declare\ -*\ IMPLEMENTATION_PATHS=*) : ;;
      *) rm -f "$output"; die "profile produced an unexpected declaration" ;;
    esac
    assignments="${assignments}${line}
"
  done < "$output"
  rm -f "$output"
  [ -n "$assignments" ] || die "profile declared none of the required aidev fields (a top-level exit/return is not allowed)"
  PROFILE_DECLARATIONS="$assignments"
}

validate_profile() {
  local root="$1" p probe parent dep_declared=0 impl_declared=0 lang="" all=()
  set +u
  load_profile_declarations "$root"
  eval "$PROFILE_DECLARATIONS"
  declare -p FROZEN_PATHS >/dev/null 2>&1 || die "profile is missing FROZEN_PATHS"
  all=("${FROZEN_PATHS[@]}")
  if declare -p ARCHITECTURE_PATHS >/dev/null 2>&1; then all+=("${ARCHITECTURE_PATHS[@]}"); fi
  if declare -p DEPENDENCY_PATHS >/dev/null 2>&1; then dep_declared=1; all+=("${DEPENDENCY_PATHS[@]}"); fi
  if declare -p IMPLEMENTATION_PATHS >/dev/null 2>&1; then impl_declared=1; all+=("${IMPLEMENTATION_PATHS[@]}"); fi
  lang="${LANG_NAME:-}"
  for p in "${all[@]}"; do
    case "$p" in
      ''|/*|-*|.|./*|..|../*|*/../*|*/..|*/./*|*/.|*//*) die "profile paths must be canonical project-relative paths: $p" ;;
      *$'\n'*|*$'\r'*|*$'\t'*) die "profile paths may not contain control characters" ;;
      *"*"*|*"?"*|*"["*) die "profile paths must be literal (no globs): $p" ;;
    esac
    probe="$root/$p"
    while [ "$probe" != "$root" ] && [ "$probe" != "/" ]; do
      [ ! -L "$probe" ] || die "profile paths may not traverse symlinks: $p"
      parent="$(dirname "$probe")"
      [ "$parent" != "$probe" ] || break
      probe="$parent"
    done
  done
  case "$lang" in
    workspace*) : ;;
    *)
      [ "$dep_declared" -eq 1 ] || die "profile must declare DEPENDENCY_PATHS (use an empty array if the project truly has none)"
      [ "$impl_declared" -eq 1 ] || die "profile must declare IMPLEMENTATION_PATHS for implementer write control"
      ;;
  esac
  set -u
}

load_role() {
  local root="$1" role="$2" r
  # roles.json is centralized at the repo root (README: one roles.json + nested per-component profiles),
  # so resolve it by walking up from the component profile root to the nearest ancestor that defines it.
  ROLE_FILE=""
  r="$root"
  while [ "$r" != "/" ]; do
    if [ -f "$r/.aidev/roles.json" ]; then ROLE_FILE="$r/.aidev/roles.json"; break; fi
    r="$(dirname "$r")"
  done
  [ -n "$ROLE_FILE" ] || die "no .aidev/roles.json in $root or any parent; run /aidev:init to configure role runners"
  jq -e '.schema == 1 and (.roles | type == "object")' "$ROLE_FILE" >/dev/null \
    || die ".aidev/roles.json is invalid or uses an unsupported schema"
  ROLE_CONFIG="$(jq -c --arg r "$role" '.roles[$r] // empty' "$ROLE_FILE")"
  [ -n "$ROLE_CONFIG" ] || die "role '$role' is not configured"
  printf '%s' "$ROLE_CONFIG" | jq -e '
    (.runner | type == "string" and length > 0) and
    (.transport | type == "string" and length > 0) and
    ((.model // "") | type == "string") and
    ((.settings // {}) | type == "object") and
    ((.skills // []) | type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9._:-]+$"))) and
    ((.skill_sources // {}) | type == "object" and all(.[]; type == "string" and length > 0)) and
    (((.skill_sources // {}) | keys) - (.skills // []) | length == 0)
  ' >/dev/null || die "role '$role' must set runner, transport, valid model/settings, safe skill names, and skill_sources only for selected skills"
  printf '%s' "$ROLE_CONFIG" | jq -e '((.model // "") | test("[\\x00-\\x1F\\x7F]") | not)' >/dev/null \
    || die "role '$role' model must not contain newlines or other control characters"

  ROLE_RUNNER="$(printf '%s' "$ROLE_CONFIG" | jq -r '.runner')"
  ROLE_TRANSPORT="$(printf '%s' "$ROLE_CONFIG" | jq -r '.transport')"
  ROLE_MODEL="$(printf '%s' "$ROLE_CONFIG" | jq -r '.model // ""')"
  ROLE_SETTINGS="$(printf '%s' "$ROLE_CONFIG" | jq -c '.settings // {}')"
  ROLE_SKILLS="$(printf '%s' "$ROLE_CONFIG" | jq -c '.skills // []')"
  ROLE_SKILL_SOURCES="$(printf '%s' "$ROLE_CONFIG" | jq -c '.skill_sources // {}')"
  case "$ROLE_RUNNER" in *[!A-Za-z0-9._-]*) die "invalid runner id '$ROLE_RUNNER'" ;; esac

  if [ "$ROLE_RUNNER" = "claude-native" ]; then
    ROLE_KIND="native"
    ROLE_ADAPTER=""
    ROLE_DESCRIPTION='{"protocol":"aidev-agent/v1","kind":"native","roles":["*"],"repo_access":["read-only","workspace-write"],"continuity":["native"],"human_io":["relay"],"web_research":true}'
    return
  fi

  ROLE_KIND="external"
  ROLE_ADAPTER="$AIDEV_HOME/adapters/$ROLE_RUNNER.sh"
  [ -x "$ROLE_ADAPTER" ] || die "runner '$ROLE_RUNNER' is unavailable: expected executable $ROLE_ADAPTER. Configure that adapter during /aidev:init or choose another runner/model"
  ROLE_DESCRIPTION="$("$ROLE_ADAPTER" describe 2>/dev/null)" \
    || die "runner '$ROLE_RUNNER' could not describe itself. Repair the adapter or choose another runner/model"
  printf '%s' "$ROLE_DESCRIPTION" | jq -e --arg p "$PROTOCOL" '.protocol == $p' >/dev/null \
    || die "runner '$ROLE_RUNNER' does not support $PROTOCOL. Upgrade its adapter or choose another runner/model"
  printf '%s' "$ROLE_DESCRIPTION" | jq -e --arg r "$role" '(.roles // []) | index("*") != null or index($r) != null' >/dev/null \
    || die "runner '$ROLE_RUNNER' does not support role '$role'. Choose another runner/model for this role"
}

has_capability() {
  local field="$1" value="$2"
  printf '%s' "$ROLE_DESCRIPTION" | jq -e --arg f "$field" --arg v "$value" '.[$f] // [] | index($v) != null' >/dev/null
}

validate_role_capabilities() {
  local role="$1"
  if [ "$ROLE_KIND" = "native" ]; then
    [ "$ROLE_TRANSPORT" = "native" ] \
      || die "role '$role' uses claude-native and must set transport to 'native'"
    return
  fi
  case "$ROLE_TRANSPORT" in
    resume|replay) : ;;
    *) die "role '$role' external runner must set transport to 'resume' or 'replay'" ;;
  esac
  has_capability continuity "$ROLE_TRANSPORT" \
    || die "runner '$ROLE_RUNNER' does not implement configured transport '$ROLE_TRANSPORT'. Repair the adapter or choose another runner/model"
  case "$role" in
    architect)
      has_capability human_io relay \
        || die "runner '$ROLE_RUNNER' cannot conduct the architect interview through the orchestrator relay. Choose another runner/model"
      has_capability repo_access workspace-write \
        || die "runner '$ROLE_RUNNER' cannot produce architecture-document changes. Choose another runner/model"
      has_capability write_scope allowed-paths || has_capability write_scope isolated-promotion \
        || die "runner '$ROLE_RUNNER' cannot enforce the architect's allowed write paths. Add a narrow sandbox/isolated promotion adapter or choose another runner/model"
      ;;
    planner|implementer)
      has_capability repo_access workspace-write \
        || die "runner '$ROLE_RUNNER' cannot make the writes required by role '$role'. Choose another runner/model"
      has_capability write_scope allowed-paths || has_capability write_scope isolated-promotion \
        || die "runner '$ROLE_RUNNER' cannot enforce role '$role' allowed write paths. Add a narrow sandbox/isolated promotion adapter or choose another runner/model"
      ;;
    reviewer)
      has_capability repo_access read-only \
        || die "runner '$ROLE_RUNNER' cannot provide an enforceable read-only review mode. Choose another runner/model"
      ;;
  esac
}

canonical_file() {
  local path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
  else
    (cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
  fi
}

add_skill_candidate() {
  local candidate="$1" canonical
  [ -f "$candidate" ] || return 0
  canonical="$(canonical_file "$candidate")"
  grep -Fqx "$canonical" "$CANDIDATE_FILE" 2>/dev/null || printf '%s\n' "$canonical" >> "$CANDIDATE_FILE"
}

resolve_skill() {
  local root="$1" ref="$2" source candidate short search_root count choices
  source="$(printf '%s' "$ROLE_SKILL_SOURCES" | jq -r --arg ref "$ref" '.[$ref] // ""')"
  if [ -n "$source" ]; then
    case "$source" in
      *$'\n'*|*$'\r'*) die "skill_sources['$ref'] contains a newline" ;;
      \~|\~/*) die "skill_sources['$ref'] must be absolute or project-relative; '~' is not expanded" ;;
      /*) candidate="$source" ;;
      *)
        case "$source" in ..|../*|*/../*|*/..) die "skill_sources['$ref'] project-relative path must stay inside the project" ;; esac
        candidate="$root/$source"
        ;;
    esac
    [ "$(basename "$candidate")" = "SKILL.md" ] \
      || die "skill_sources['$ref'] must point to the canonical SKILL.md file, not a directory"
    [ -f "$candidate" ] \
      || die "skill_sources['$ref'] does not exist or is not a file: $source"
    RESOLVED_SKILL_PATH="$(canonical_file "$candidate")"
    return
  fi

  short="${ref##*:}"
  CANDIDATE_FILE="$(mktemp "${TMPDIR:-/tmp}/aidev-skill-candidates.XXXXXX")"
  : > "$CANDIDATE_FILE"
  for candidate in \
    "$root/.claude/skills/$ref/SKILL.md" "$root/.agents/skills/$ref/SKILL.md" \
    "$HOME/.claude/skills/$ref/SKILL.md" "$HOME/.agents/skills/$ref/SKILL.md" \
    "$root/.claude/skills/$short/SKILL.md" "$root/.agents/skills/$short/SKILL.md" \
    "$HOME/.claude/skills/$short/SKILL.md" "$HOME/.agents/skills/$short/SKILL.md"; do
    add_skill_candidate "$candidate"
  done
  for search_root in "$root/.claude/plugins" "$HOME/.claude/plugins"; do
    [ -d "$search_root" ] || continue
    while IFS= read -r candidate; do add_skill_candidate "$candidate"; done < <(
      find "$search_root" -path "*/skills/$short/SKILL.md" -type f 2>/dev/null | LC_ALL=C sort
    )
  done
  count="$(awk 'END { print NR + 0 }' "$CANDIDATE_FILE")"
  if [ "$count" -eq 0 ]; then
    rm -f "$CANDIDATE_FILE"
    die "configured skill '$ref' cannot be resolved; set skill_sources['$ref'] to an absolute or project-relative SKILL.md path, or remove it during /aidev:init"
  fi
  if [ "$count" -gt 1 ]; then
    choices="$(awk 'BEGIN { ORS="" } { if (NR > 1) printf "; "; printf "%s", $0 }' "$CANDIDATE_FILE")"
    rm -f "$CANDIDATE_FILE"
    die "configured skill '$ref' is ambiguous ($choices); set skill_sources['$ref'] to the intended SKILL.md during /aidev:init"
  fi
  RESOLVED_SKILL_PATH="$(sed -n '1p' "$CANDIDATE_FILE")"
  rm -f "$CANDIDATE_FILE"
}

build_skills_bundle() {
  local root="$1" output="$2" ref path package_root digest package_digest
  : > "$output"
  RESOLVED_SKILL_PACKAGES='[]'
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    resolve_skill "$root" "$ref"
    path="$RESOLVED_SKILL_PATH"
    package_root="$(dirname "$path")"
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
    package_digest="$(directory_hash "$package_root")"
    RESOLVED_SKILL_PACKAGES="$(printf '%s' "$RESOLVED_SKILL_PACKAGES" | jq -c \
      --arg name "$ref" --arg skill_file "$path" --arg root "$package_root" --arg sha256 "$digest" \
      --arg package_sha256 "$package_digest" \
      '. + [{name:$name,skill_file:$skill_file,root:$root,sha256:$sha256,package_sha256:$package_sha256}]')"
    {
      echo "===== PRELOADED SKILL: $ref ($path) ====="
      cat "$path"
      echo
    } >> "$output"
  done < <(printf '%s' "$ROLE_SKILLS" | jq -r '.[]')
}

directory_hash() {
  local directory="$1" manifest path rel digest target
  manifest="$(mktemp "${TMPDIR:-/tmp}/aidev-directory.XXXXXX")"
  find "$directory" \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r path; do
    rel="${path#"$directory"/}"
    if [ -L "$path" ]; then
      target="$(readlink "$path")"
      printf 'SYMLINK\0%s\0%s\0' "$rel" "$target"
    else
      digest="$(shasum -a 256 "$path" | awk '{print $1}')"
      printf 'FILE\0%s\0%s\0' "$rel" "$digest"
    fi
  done > "$manifest"
  shasum -a 256 "$manifest" | awk '{print $1}'
  rm -f "$manifest"
}

validate_native_skill_bindings() {
  local root="$1" ref path short expected_personal expected_project personal namespace plugin_root plugin_name
  while IFS=$'\t' read -r ref path; do
    [ -n "$ref" ] || continue
    short="${ref##*:}"
    if [ "$short" != "$ref" ]; then
      namespace="${ref%%:*}"
      plugin_root="$(dirname "$path")"
      while [ "$plugin_root" != "/" ] && [ ! -f "$plugin_root/.claude-plugin/plugin.json" ]; do
        plugin_root="$(dirname "$plugin_root")"
      done
      [ -f "$plugin_root/.claude-plugin/plugin.json" ] \
        || die "role skill '$ref' selects '$path', but no Claude plugin manifest defines that namespace"
      plugin_name="$(jq -r '.name // ""' "$plugin_root/.claude-plugin/plugin.json")"
      [ "$plugin_name" = "$namespace" ] \
        || die "role skill '$ref' selects plugin '$plugin_name'; use '$plugin_name:$short' or choose the matching skill source"
      case "$path" in */skills/"$short"/SKILL.md) : ;; *) die "role skill '$ref' source does not match skills/$short/SKILL.md" ;; esac
      continue
    fi
    expected_personal="$(canonical_file "$HOME/.claude/skills/$ref/SKILL.md" 2>/dev/null || true)"
    expected_project="$(canonical_file "$root/.claude/skills/$ref/SKILL.md" 2>/dev/null || true)"
    if [ -n "$expected_personal" ] && [ "$path" = "$expected_personal" ]; then
      continue
    fi
    if [ -n "$expected_project" ] && [ "$path" = "$expected_project" ]; then
      personal="$HOME/.claude/skills/$ref/SKILL.md"
      if [ -f "$personal" ] && [ "$(canonical_file "$personal")" != "$path" ]; then
        die "role skill '$ref' selects the project copy, but Claude Code resolves the personal copy first; rename one skill or select/install the intended source under ~/.claude/skills"
      fi
      continue
    fi
    die "role skill '$ref' resolves to '$path', which claude-native cannot preload by that name; install it at .claude/skills/$ref/SKILL.md, ~/.claude/skills/$ref/SKILL.md, or use its plugin namespace"
  done < <(printf '%s' "$RESOLVED_SKILL_PACKAGES" | jq -r '.[] | [.name,.skill_file] | @tsv')
}

array_json() {
  if [ "$#" -eq 0 ]; then printf '[]\n'; return; fi
  printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]'
}

allowed_paths_json() {
  local root="$1" role="$2"
  local architecture=() frozen=() dependencies=() implementation=() allowed=()
  set +u
  load_profile_declarations "$root"
  eval "$PROFILE_DECLARATIONS"
  declare -p ARCHITECTURE_PATHS >/dev/null 2>&1 && architecture=("${ARCHITECTURE_PATHS[@]}")
  frozen=("${FROZEN_PATHS[@]}")
  declare -p DEPENDENCY_PATHS >/dev/null 2>&1 && dependencies=("${DEPENDENCY_PATHS[@]}")
  declare -p IMPLEMENTATION_PATHS >/dev/null 2>&1 && implementation=("${IMPLEMENTATION_PATHS[@]}")
  case "$role" in
    architect) allowed=("${architecture[@]}") ;;
    planner) allowed=("${frozen[@]}" "${dependencies[@]}" "${implementation[@]}" ".aidev") ;;
    implementer) allowed=("${implementation[@]}" ".aidev/CHANGE-REQUEST.md") ;;
    reviewer) allowed=() ;;
  esac
  array_json "${allowed[@]}"
  set -u
}

denied_paths_json() {
  local root="$1" role="$2"
  local architecture=() frozen=() dependencies=() implementation=() controls=() denied=()
  set +u
  load_profile_declarations "$root"
  eval "$PROFILE_DECLARATIONS"
  declare -p ARCHITECTURE_PATHS >/dev/null 2>&1 && architecture=("${ARCHITECTURE_PATHS[@]}")
  frozen=("${FROZEN_PATHS[@]}")
  declare -p DEPENDENCY_PATHS >/dev/null 2>&1 && dependencies=("${DEPENDENCY_PATHS[@]}")
  declare -p IMPLEMENTATION_PATHS >/dev/null 2>&1 && implementation=("${IMPLEMENTATION_PATHS[@]}")
  controls=(
    ".aidev/profile.sh" ".aidev/roles.json" ".aidev/models.conf"
    ".aidev/gate.sh" ".aidev/freeze.sh" ".aidev/.frozen.sha256" ".claude/agents"
  )
  case "$role" in
    architect) denied=("${frozen[@]}" "${dependencies[@]}" "${implementation[@]}" "${controls[@]}") ;;
    planner) denied=("${architecture[@]}" "${controls[@]}") ;;
    implementer) denied=("${architecture[@]}" "${frozen[@]}" "${dependencies[@]}" "${controls[@]}") ;;
    reviewer) denied=(".") ;;
  esac
  array_json "${denied[@]}"
  set -u
}

requested_access() {
  case "$1" in reviewer) printf 'read-only\n' ;; *) printf 'workspace-write\n' ;; esac
}

write_check_request() {
  local root="$1" role="$2" output="$3" bundle="$4" access allowed denied
  access="$(requested_access "$role")"
  allowed="$(allowed_paths_json "$root" "$role")"
  denied="$(denied_paths_json "$root" "$role")"
  jq -n --arg protocol "$PROTOCOL" --arg role "$role" --arg workspace "$root" \
    --arg runner "$ROLE_RUNNER" --arg transport "$ROLE_TRANSPORT" --arg model "$ROLE_MODEL" \
    --argjson settings "$ROLE_SETTINGS" --argjson role_config "$ROLE_CONFIG" \
    --arg access "$access" --argjson allowed_write_paths "$allowed" --argjson denied_write_paths "$denied" \
    --argjson skills "$ROLE_SKILLS" \
    --argjson skill_sources "$ROLE_SKILL_SOURCES" --argjson skill_packages "$RESOLVED_SKILL_PACKAGES" \
    --arg skills_bundle_file "$bundle" \
    '{protocol:$protocol,role:$role,workspace:$workspace,runner:$runner,transport:$transport,
      model:$model,settings:$settings,role_config:$role_config,access:$access,
      allowed_write_paths:$allowed_write_paths,denied_write_paths:$denied_write_paths,
      skills:$skills,skill_sources:$skill_sources,
      skill_packages:$skill_packages,skills_bundle_file:$skills_bundle_file}' > "$output"
}

doctor_role() {
  local root="$1" role="$2" request result ok reason skill_check rc effort
  load_role "$root" "$role"
  validate_role_capabilities "$role"
  skill_check="$(mktemp "${TMPDIR:-/tmp}/aidev-skills.XXXXXX")"
  build_skills_bundle "$root" "$skill_check"
  if [ "$ROLE_KIND" = "native" ]; then
    validate_native_skill_bindings "$root"
    command -v claude >/dev/null 2>&1 || { rm -f "$skill_check"; die "role '$role' cannot use claude-native: the claude executable is not installed or not on PATH. Choose another runner/model."; }
    claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null \
      || { rm -f "$skill_check"; die "role '$role' cannot use claude-native: Claude Code is not authenticated. Run claude auth login or choose another runner/model."; }
    printf '%s' "$ROLE_SETTINGS" | jq -e '(keys - ["effort"] | length) == 0' >/dev/null \
      || { rm -f "$skill_check"; die "role '$role': claude-native settings support only 'effort'"; }
    effort="$(printf '%s' "$ROLE_SETTINGS" | jq -r '.effort // ""')"
    case "$effort" in ''|low|medium|high|xhigh|max) : ;; *) rm -f "$skill_check"; die "role '$role': claude-native effort must be low|medium|high|xhigh|max" ;; esac
    rm -f "$skill_check"
    echo "  $role -> claude-native / ${ROLE_MODEL:-inherit} / $ROLE_TRANSPORT / $(printf '%s' "$ROLE_SKILLS" | jq 'length') skill(s)"
    return
  fi

  request="$(mktemp "${TMPDIR:-/tmp}/aidev-doctor.XXXXXX")"
  write_check_request "$root" "$role" "$request" "$skill_check"
  set +e
  result="$("$ROLE_ADAPTER" doctor "$request" 2>&1)"; rc=$?
  set -e
  rm -f "$request" "$skill_check"
  ok="$(printf '%s' "$result" | jq -r '.ok // false' 2>/dev/null || printf false)"
  reason="$(printf '%s' "$result" | jq -r '.reason // "adapter returned no reason"' 2>/dev/null || printf '%s' "$result")"
  [ "$rc" -eq 0 ] && [ "$ok" = "true" ] \
    || die "role '$role' cannot use runner '$ROLE_RUNNER': $reason. Choose another runner/model."
  echo "  $role -> $ROLE_RUNNER / ${ROLE_MODEL:-adapter default} / $ROLE_TRANSPORT / $(printf '%s' "$ROLE_SKILLS" | jq 'length') skill(s)"
}

probe_role() {
  local root="$1" role="$2" request result ok reason skill_check rc output effort
  local args=()
  load_role "$root" "$role"
  validate_role_capabilities "$role"
  skill_check="$(mktemp "${TMPDIR:-/tmp}/aidev-skills.XXXXXX")"
  build_skills_bundle "$root" "$skill_check"
  if [ "$ROLE_KIND" = "native" ]; then
    args=(claude -p --safe-mode --no-session-persistence --permission-mode dontAsk --tools "")
    [ -n "$ROLE_MODEL" ] && args+=(--model "$ROLE_MODEL")
    effort="$(printf '%s' "$ROLE_SETTINGS" | jq -r '.effort // ""')"
    [ -n "$effort" ] && args+=(--effort "$effort")
    set +e
    # `--tools` is variadic in Claude Code; `--` keeps the probe text from being consumed as another tool.
    output="$(cd "$root" && "${args[@]}" -- 'Reply with exactly AIDEV_PROBE_OK and nothing else.' 2>&1)"; rc=$?
    set -e
    rm -f "$skill_check"
    [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -Fq 'AIDEV_PROBE_OK' \
      || die "role '$role' live probe failed for claude-native model '${ROLE_MODEL:-inherit}': $(printf '%s' "$output" | tail -n 3 | tr '\n' ' '). Choose another runner/model."
    echo "  $role -> live probe PASS"
    return
  fi

  request="$(mktemp "${TMPDIR:-/tmp}/aidev-probe.XXXXXX")"
  write_check_request "$root" "$role" "$request" "$skill_check"
  set +e
  result="$("$ROLE_ADAPTER" probe "$request" 2>&1)"; rc=$?
  set -e
  rm -f "$request" "$skill_check"
  ok="$(printf '%s' "$result" | jq -r '.ok // false' 2>/dev/null || printf false)"
  reason="$(printf '%s' "$result" | jq -r '.reason // "adapter returned no reason"' 2>/dev/null || printf '%s' "$result")"
  [ "$rc" -eq 0 ] && [ "$ok" = "true" ] \
    || die "role '$role' live probe failed for runner '$ROLE_RUNNER' and model '${ROLE_MODEL:-adapter default}': $reason. Choose another runner/model."
  echo "  $role -> live probe PASS"
}

latest_numbered_file() {
  local directory="$1" prefix="$2" number
  number="$(find "$directory" -maxdepth 1 -name "$prefix-*.json" -type f 2>/dev/null \
    | while IFS= read -r path; do basename "$path"; done \
    | sed -n "s/^$prefix-\\([0-9][0-9]*\\)\\.json$/\\1/p" \
    | LC_ALL=C sort -n | tail -n 1)"
  [ -n "$number" ] || return 1
  printf '%s/%s-%s.json\n' "$directory" "$prefix" "$number"
}

working_tree_hash() {
  local root="$1" manifest rel digest target
  manifest="$(mktemp "${TMPDIR:-/tmp}/aidev-tree.XXXXXX")"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'HEAD\0%s\0' "$(git -C "$root" rev-parse HEAD 2>/dev/null || printf unborn)" > "$manifest"
    git -C "$root" status --porcelain=v1 -z --untracked-files=all >> "$manifest"
    git -C "$root" ls-files -co --exclude-standard -z | while IFS= read -r -d '' rel; do
      printf 'PATH\0%s\0' "$rel"
      if [ -L "$root/$rel" ]; then
        target="$(readlink "$root/$rel")"
        printf 'SYMLINK\0%s\0' "$target"
      elif [ -f "$root/$rel" ]; then
        digest="$(shasum -a 256 "$root/$rel" | awk '{print $1}')"
        printf 'FILE\0%s\0' "$digest"
      else
        printf 'MISSING\0'
      fi
    done >> "$manifest"
  else
    find "$root" -path "$root/.git" -prune -o -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r target; do
      rel="${target#"$root"/}"
      digest="$(shasum -a 256 "$target" | awk '{print $1}')"
      printf 'PATH\0%s\0FILE\0%s\0' "$rel" "$digest"
    done > "$manifest"
  fi
  shasum -a 256 "$manifest" | awk '{print $1}'
  rm -f "$manifest"
}

configuration_hash() {
  local charter="$1" manifest digest
  manifest="$(mktemp "${TMPDIR:-/tmp}/aidev-config.XXXXXX")"
  printf '%s' "$ROLE_CONFIG" | jq -S -c . > "$manifest"
  digest="$(shasum -a 256 "$charter" | awk '{print $1}')"
  printf '\ncharter %s\n' "$digest" >> "$manifest"
  digest="$(shasum -a 256 "$ROLE_ADAPTER" | awk '{print $1}')"
  printf 'adapter %s\n' "$digest" >> "$manifest"
  printf '%s' "$RESOLVED_SKILL_PACKAGES" | jq -S -c . >> "$manifest"
  shasum -a 256 "$manifest" | awk '{print $1}'
  rm -f "$manifest"
}

build_replay_transcript() {
  local state_dir="$1" last_turn="$2" output="$3" n prompt message
  : > "$output"
  n=1
  while [ "$n" -le "$last_turn" ]; do
    prompt="$state_dir/prompt-$n.md"
    message="$state_dir/message-$n.md"
    if [ -f "$prompt" ]; then
      printf '===== TURN %s USER/ORCHESTRATOR =====\n' "$n" >> "$output"
      cat "$prompt" >> "$output"
      printf '\n' >> "$output"
    fi
    if [ -f "$message" ]; then
      printf '===== TURN %s AGENT =====\n' "$n" >> "$output"
      cat "$message" >> "$output"
      printf '\n' >> "$output"
    fi
    n=$((n + 1))
  done
}

# ===== verbatim relay — the orchestrator hands REFERENCES; role-runner assembles the bytes =====
# Every turn leaves a ledger entry (kind: relay | direct | native-message) in the role's private
# state dir. verify-relay re-derives each relayed prompt byte-for-byte from its ledgered sources,
# so a paraphrased or edited role→role handoff cannot pass. External runners get this structurally;
# claude-native handoffs are journaled and audited (one session holds both ends — cooperative tier).

sha_file() { shasum -a 256 "$1" | awk '{print $1}'; }

append_ledger() { printf '%s\n' "$2" >> "$1/ledger.jsonl"; }

next_request_turn() { # external roles advance by request-N.json (same rule as run_external)
  local latest
  latest="$(latest_numbered_file "$1" request 2>/dev/null || true)"
  if [ -z "$latest" ]; then printf '1\n'; return; fi
  printf '%s\n' "$(( $(basename "$latest" | sed 's/^request-//;s/\.json$//') + 1 ))"
}

next_prompt_turn() { # native roles advance by prompt-N.md
  local latest
  latest="$(find "$1" -maxdepth 1 -name 'prompt-*.md' -type f 2>/dev/null \
    | while IFS= read -r p; do basename "$p"; done \
    | sed -n 's/^prompt-\([0-9][0-9]*\)\.md$/\1/p' | LC_ALL=C sort -n | tail -n 1)"
  printf '%s\n' "$(( ${latest:-0} + 1 ))"
}

compose_relay_prompt() { # $1 ledger-entry json, $2 output file — byte-deterministic
  local entry="$1" output="$2" count i n src kind file sha meta
  count="$(printf '%s' "$entry" | jq '.sources | length')"
  printf '===== AIDEV-RELAY PROMPT role=%s run_id=%s sections=%s (sections are VERBATIM; assembled by role-runner from references, not orchestrator text) =====\n' \
    "$(printf '%s' "$entry" | jq -r '.role')" \
    "$(printf '%s' "$entry" | jq -r '.run_id')" "$count" > "$output"
  i=0
  while [ "$i" -lt "$count" ]; do
    n=$((i + 1))
    src="$(printf '%s' "$entry" | jq -c --argjson i "$i" '.sources[$i]')"
    kind="$(printf '%s' "$src" | jq -r '.kind')"
    file="$(printf '%s' "$src" | jq -r '.file')"
    sha="$(printf '%s' "$src" | jq -r '.sha256')"
    case "$kind" in
      from) meta="role=$(printf '%s' "$src" | jq -r '.role') run_id=$(printf '%s' "$src" | jq -r '.run_id') turn=$(printf '%s' "$src" | jq -r '.turn')" ;;
      human) meta="channel=human" ;;
      note) meta="label=$(printf '%s' "$src" | jq -r '.label')" ;;
      *) die "ledger entry has an unknown source kind '$kind'" ;;
    esac
    [ -f "$file" ] && [ ! -L "$file" ] || die "relay source is not a regular file: $file"
    printf '===== AIDEV-RELAY SECTION %s BEGIN kind=%s %s sha256=%s =====\n' "$n" "$kind" "$meta" "$sha" >> "$output"
    cat "$file" >> "$output"
    printf '\n===== AIDEV-RELAY SECTION %s END =====\n' "$n" >> "$output"
    i=$n
  done
}

relay_role() { # relay <role> <start|resume> <run-id> [project-dir] --from R:RUN:T ... [--human F] [--note LABEL F]
  local role="$1" action="$2" run_id="$3"; shift 3
  local root="$PWD"
  if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then root="$1"; shift; fi
  valid_role "$role" || usage
  case "$action" in start|resume) : ;; *) die "action must be start or resume" ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) die "run-id must use letters, digits, dot, underscore, or dash" ;; esac
  root="$(find_root "$root")"
  validate_profile "$root"
  load_role "$root" "$role"
  validate_role_capabilities "$role"
  local key state_dir turn
  key="$(project_key "$root")"
  state_dir="$AIDEV_STATE_ROOT/$key/$run_id/$role"
  mkdir -p "$AIDEV_STATE_ROOT" "$AIDEV_STATE_ROOT/$key" "$AIDEV_STATE_ROOT/$key/$run_id" "$state_dir"
  chmod 700 "$AIDEV_STATE_ROOT" "$AIDEV_STATE_ROOT/$key" "$AIDEV_STATE_ROOT/$key/$run_id" "$state_dir"
  if [ "$ROLE_KIND" = "native" ]; then
    turn="$(next_prompt_turn "$state_dir")"
  else
    turn="$(next_request_turn "$state_dir")"
  fi

  local sources='[]' idx=1 has_content=0
  local spec src_role src_run src_turn msg sha copy label file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)
        spec="${2:-}"; [ -n "$spec" ] || die "--from needs <role>:<run-id>:<turn>"
        src_role="${spec%%:*}"; spec="${spec#*:}"
        src_turn="${spec##*:}"; src_run="${spec%:*}"
        valid_role "$src_role" || die "--from role '$src_role' is not a harness role"
        case "$src_run" in ''|*[!A-Za-z0-9._-]*) die "--from run-id '$src_run' is invalid" ;; esac
        case "$src_turn" in ''|*[!0-9]*) die "--from turn '$src_turn' must be a number" ;; esac
        msg="$AIDEV_STATE_ROOT/$key/$src_run/$src_role/message-$src_turn.md"
        [ -f "$msg" ] && [ ! -L "$msg" ] || die "no recorded message for $src_role/$src_run turn $src_turn: $msg"
        sha="$(sha_file "$msg")"
        sources="$(printf '%s' "$sources" | jq -c --arg role "$src_role" --arg run "$src_run" --argjson turn "$src_turn" \
          --arg file "$msg" --arg sha "$sha" '. + [{kind:"from",role:$role,run_id:$run,turn:$turn,file:$file,sha256:$sha}]')"
        has_content=1; idx=$((idx + 1)); shift 2 ;;
      --human)
        file="${2:-}"; [ -n "$file" ] && [ -f "$file" ] || die "--human file not found: ${2:-<missing>}"
        copy="$state_dir/source-$turn-$idx-human.md"
        cp "$file" "$copy"; sha="$(sha_file "$copy")"
        sources="$(printf '%s' "$sources" | jq -c --arg file "$copy" --arg sha "$sha" \
          '. + [{kind:"human",file:$file,sha256:$sha}]')"
        has_content=1; idx=$((idx + 1)); shift 2 ;;
      --note)
        label="${2:-}"; file="${3:-}"
        case "$label" in ''|*[!A-Za-z0-9._-]*) die "--note label must use letters, digits, dot, underscore, or dash" ;; esac
        [ -n "$file" ] && [ -f "$file" ] || die "--note file not found: ${3:-<missing>}"
        copy="$state_dir/source-$turn-$idx-note-$label.md"
        cp "$file" "$copy"; sha="$(sha_file "$copy")"
        sources="$(printf '%s' "$sources" | jq -c --arg label "$label" --arg file "$copy" --arg sha "$sha" \
          '. + [{kind:"note",label:$label,file:$file,sha256:$sha}]')"
        idx=$((idx + 1)); shift 3 ;;
      *) die "unknown relay option '$1'" ;;
    esac
  done
  [ "$(printf '%s' "$sources" | jq 'length')" -gt 0 ] || die "relay needs at least one --from/--human/--note source"
  if [ "$turn" -gt 1 ] && [ "$has_content" -eq 0 ]; then
    die "a resume relay must carry at least one --from role message or --human message; orchestrator notes alone are not a role handoff"
  fi

  local entry composed
  entry="$(jq -n -c --argjson turn "$turn" --arg role "$role" --arg run "$run_id" \
    --arg file "$state_dir/prompt-$turn.md" --argjson sources "$sources" \
    '{turn:$turn,role:$role,run_id:$run,kind:"relay",prompt_file:$file,sources:$sources}')"
  if [ "$ROLE_KIND" = "native" ]; then
    compose_relay_prompt "$entry" "$state_dir/prompt-$turn.md"
    entry="$(printf '%s' "$entry" | jq -c --arg sha "$(sha_file "$state_dir/prompt-$turn.md")" '. + {prompt_sha256:$sha}')"
    append_ledger "$state_dir" "$entry"
    echo "RELAY COMPOSED (native $role, turn $turn): $state_dir/prompt-$turn.md"
    echo "Send that file's content to the native '$role' subagent VERBATIM (no edits, no summary),"
    echo "then journal its full reply:"
    echo "  role-runner.sh journal $role $run_id message <reply-file> $root"
    return
  fi
  composed="$state_dir/.compose-$turn.md"
  compose_relay_prompt "$entry" "$composed"
  entry="$(printf '%s' "$entry" | jq -c --arg sha "$(sha_file "$composed")" '. + {prompt_sha256:$sha}')"
  RELAY_ENTRY_JSON="$entry"
  run_external "$root" "$role" "$action" "$run_id" "$composed"
  rm -f "$composed"
}

journal_message() { # journal <role> <run-id> message <reply-file> [project-dir]
  local role="$1" run_id="$2" what="$3" file="$4" root="${5:-$PWD}"
  valid_role "$role" || usage
  [ "$what" = "message" ] || usage
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
  [ -f "$file" ] || die "message file not found: $file"
  root="$(find_root "$root")"
  load_role "$root" "$role"
  [ "$ROLE_KIND" = "native" ] || die "journal is only for claude-native roles; external runners return messages through their adapter"
  local key state_dir turn dest sha entry
  key="$(project_key "$root")"
  state_dir="$AIDEV_STATE_ROOT/$key/$run_id/$role"
  [ -d "$state_dir" ] || die "no relay state exists for $role/$run_id; compose a prompt with 'relay' first"
  turn="$(( $(next_prompt_turn "$state_dir") - 1 ))"
  [ "$turn" -ge 1 ] && [ -f "$state_dir/prompt-$turn.md" ] || die "no relayed prompt exists yet for $role/$run_id; compose it with 'relay' first"
  dest="$state_dir/message-$turn.md"
  [ ! -e "$dest" ] || die "turn $turn already has a journaled message: $dest"
  cp "$file" "$dest"; sha="$(sha_file "$dest")"
  entry="$(jq -n -c --argjson turn "$turn" --arg role "$role" --arg run "$run_id" \
    --arg file "$dest" --arg sha "$sha" \
    '{turn:$turn,role:$role,run_id:$run,kind:"native-message",message_file:$file,message_sha256:$sha}')"
  append_ledger "$state_dir" "$entry"
  echo "JOURNALED: $dest"
}

verify_relay() { # verify-relay <run-id> [project-dir]
  local run_id="$1" root="${2:-$PWD}"
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
  root="$(find_root "$root")"
  local key run_dir fail=0 pre state_dir role ledger entries prompt n count i entry kind turn srcs j src sfile ssha tmp
  key="$(project_key "$root")"
  run_dir="$AIDEV_STATE_ROOT/$key/$run_id"
  [ -d "$run_dir" ] || die "no relay/run state exists for run '$run_id'"
  echo "Relay chain: $run_dir"
  for state_dir in "$run_dir"/*; do
    [ -d "$state_dir" ] || continue
    role="$(basename "$state_dir")"
    valid_role "$role" || { echo "  FAIL $role: unexpected state directory"; fail=1; continue; }
    ledger="$state_dir/ledger.jsonl"
    if [ ! -f "$ledger" ]; then
      if find "$state_dir" -maxdepth 1 -name 'prompt-*.md' -type f 2>/dev/null | grep -q .; then
        echo "  FAIL $role: prompts exist without a ledger (pre-relay or tampered run)"; fail=1
      fi
      continue
    fi
    entries="$(jq -s -c '.' "$ledger" 2>/dev/null)" || { echo "  FAIL $role: unreadable ledger"; fail=1; continue; }
    # every prompt on disk carries exactly one prompt-bearing ledger entry
    while IFS= read -r prompt; do
      [ -n "$prompt" ] || continue
      n="$(basename "$prompt" | sed 's/^prompt-//;s/\.md$//')"
      count="$(printf '%s' "$entries" | jq --argjson n "$n" '[.[] | select(.turn == $n and (.kind == "relay" or .kind == "direct"))] | length')"
      [ "$count" -eq 1 ] || { echo "  FAIL $role turn $n: $count ledger entries for this prompt (want exactly 1)"; fail=1; }
    done < <(find "$state_dir" -maxdepth 1 -name 'prompt-*.md' -type f 2>/dev/null | LC_ALL=C sort)
    count="$(printf '%s' "$entries" | jq 'length')"
    i=0
    while [ "$i" -lt "$count" ]; do
      entry="$(printf '%s' "$entries" | jq -c --argjson i "$i" '.[$i]')"
      i=$((i + 1))
      kind="$(printf '%s' "$entry" | jq -r '.kind // ""')"
      turn="$(printf '%s' "$entry" | jq -r '.turn // 0')"
      pre="$fail"
      case "$kind" in
        relay)
          prompt="$state_dir/prompt-$turn.md"
          if [ ! -f "$prompt" ]; then
            echo "  FAIL $role turn $turn: ledgered relay has no prompt file"; fail=1; continue
          fi
          [ "$(sha_file "$prompt")" = "$(printf '%s' "$entry" | jq -r '.prompt_sha256 // ""')" ] \
            || { echo "  FAIL $role turn $turn: prompt file drifted from its ledgered hash"; fail=1; }
          srcs="$(printf '%s' "$entry" | jq '.sources | length')"
          j=0
          while [ "$j" -lt "$srcs" ]; do
            src="$(printf '%s' "$entry" | jq -c --argjson j "$j" '.sources[$j]')"
            sfile="$(printf '%s' "$src" | jq -r '.file')"
            ssha="$(printf '%s' "$src" | jq -r '.sha256')"
            if [ ! -f "$sfile" ] || [ -L "$sfile" ] || [ "$(sha_file "$sfile")" != "$ssha" ]; then
              echo "  FAIL $role turn $turn: relay source drifted or vanished: $sfile"; fail=1
            fi
            j=$((j + 1))
          done
          tmp="$(mktemp "${TMPDIR:-/tmp}/aidev-recompose.XXXXXX")"
          if compose_relay_prompt "$entry" "$tmp" 2>/dev/null && [ "$(sha_file "$tmp")" = "$(sha_file "$prompt")" ]; then
            :
          else
            echo "  FAIL $role turn $turn: prompt is not the byte-exact composition of its ledgered sources"; fail=1
          fi
          rm -f "$tmp"
          if [ "$turn" -gt 1 ]; then
            printf '%s' "$entry" | jq -e '[.sources[] | select(.kind == "from" or .kind == "human")] | length > 0' >/dev/null \
              || { echo "  FAIL $role turn $turn: resume relay carries only orchestrator notes — not a verbatim role/human handoff"; fail=1; }
          fi
          [ "$fail" != "$pre" ] || echo "  ok   $role turn $turn: relay ($srcs source(s), byte-exact)"
          ;;
        direct)
          prompt="$state_dir/prompt-$turn.md"
          if [ ! -f "$prompt" ] || [ "$(sha_file "$prompt")" != "$(printf '%s' "$entry" | jq -r '.prompt_sha256 // ""')" ]; then
            echo "  FAIL $role turn $turn: direct prompt missing or drifted"; fail=1
          fi
          if [ "$turn" -gt 1 ]; then
            echo "  FAIL $role turn $turn: orchestrator-authored prompt on a resume turn — role→role handoffs must use relay"; fail=1
          fi
          [ "$fail" != "$pre" ] || echo "  ok   $role turn $turn: direct dispatch (orchestrator-authored initial briefing)"
          ;;
        native-message)
          if [ ! -f "$state_dir/message-$turn.md" ] || [ "$(sha_file "$state_dir/message-$turn.md")" != "$(printf '%s' "$entry" | jq -r '.message_sha256 // ""')" ]; then
            echo "  FAIL $role turn $turn: journaled native message missing or drifted"; fail=1
          else
            echo "  ok   $role turn $turn: native message journaled"
          fi
          ;;
        *) echo "  FAIL $role turn $turn: unknown ledger kind '$kind'"; fail=1 ;;
      esac
    done
  done
  if [ "$fail" -eq 0 ]; then echo "RELAY: PASS"; else echo "RELAY: FAIL"; exit 1; fi
}

validate_bound_response() {
  local response="$1" invocation="$2" role="$3" run_id="$4" config_hash="$5" tree_hash="$6" output="$7" status message session
  [ -f "$response" ] && [ ! -L "$response" ] \
    || die "runner '$ROLE_RUNNER' did not write a regular response file: $response"
  jq -e --arg p "$PROTOCOL" --arg invocation "$invocation" --arg role "$role" --arg run "$run_id" \
    --arg transport "$ROLE_TRANSPORT" --arg config "$config_hash" --arg tree "$tree_hash" '
      .protocol == $p and .invocation_id == $invocation and .role == $role and .run_id == $run and
      .transport == $transport and .config_hash == $config and .input_tree_hash == $tree and
      (.status == "completed" or .status == "needs_input" or .status == "failed")
    ' "$response" >/dev/null \
    || die "runner '$ROLE_RUNNER' wrote an invalid or unbound response; upgrade the adapter: $response"
  status="$(jq -r '.status' "$response")"
  if [ "$status" = "failed" ]; then
    [ -n "$(jq -r '.reason // ""' "$response")" ] || die "runner '$ROLE_RUNNER' reported failure without a reason"
    return
  fi
  message="$(jq -r '.message_file // ""' "$response")"
  [ "$message" = "$output" ] && [ -f "$output" ] && [ ! -L "$output" ] && [ -s "$output" ] \
    || die "runner '$ROLE_RUNNER' response did not bind to the expected non-empty message file: $output"
  session="$(jq -r '.session_id // ""' "$response")"
  if [ "$ROLE_TRANSPORT" = "resume" ] && [ -z "$session" ]; then
    die "runner '$ROLE_RUNNER' configured for resume did not return a session_id"
  fi
}

run_external() {
  local root="$1" role="$2" action="$3" run_id="$4" prompt="$5"
  local key state_dir max_request turn request response output prompt_copy previous access allowed denied charter invocation skills_bundle rc reason hb_deadline timeout_bin
  local latest previous_config previous_session transcript config_hash tree_hash after_tree_hash prior_turn
  validate_profile "$root"
  load_role "$root" "$role"
  [ "$ROLE_KIND" = "external" ] || die "role '$role' uses claude-native; spawn/resume the configured Claude subagent"
  validate_role_capabilities "$role"
  case "$action" in start|resume) : ;; *) die "action must be start or resume" ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) die "run-id must use letters, digits, dot, underscore, or dash" ;; esac
  [ -f "$prompt" ] || die "prompt file not found: $prompt"
  prompt="$(cd "$(dirname "$prompt")" && pwd -P)/$(basename "$prompt")"
  key="$(project_key "$root")"
  state_dir="$AIDEV_STATE_ROOT/$key/$run_id/$role"
  mkdir -p "$AIDEV_STATE_ROOT" "$AIDEV_STATE_ROOT/$key" "$AIDEV_STATE_ROOT/$key/$run_id" "$state_dir"
  chmod 700 "$AIDEV_STATE_ROOT" "$AIDEV_STATE_ROOT/$key" "$AIDEV_STATE_ROOT/$key/$run_id" "$state_dir"
  max_request=0
  latest="$(latest_numbered_file "$state_dir" request 2>/dev/null || true)"
  [ -z "$latest" ] || max_request="$(basename "$latest" | sed 's/^request-//;s/\.json$//')"
  if [ "$action" = "start" ] && [ "$max_request" -gt 0 ]; then
    die "run '$run_id' already has state for role '$role'; resume it or choose a new run-id"
  fi
  turn=$((max_request + 1))
  request="$state_dir/request-$turn.json"
  response="$state_dir/response-$turn.json"
  output="$state_dir/message-$turn.md"
  prompt_copy="$state_dir/prompt-$turn.md"
  skills_bundle="$state_dir/skills-$turn.md"
  transcript="$state_dir/transcript-$turn.md"
  cp "$prompt" "$prompt_copy"
  # relay-chain ledger: a relayed turn records its composed sources; anything else is "direct"
  # (orchestrator-authored) and verify-relay only accepts that on turn 1.
  if [ -n "${RELAY_ENTRY_JSON:-}" ]; then
    [ "$(printf '%s' "$RELAY_ENTRY_JSON" | jq -r '.turn')" = "$turn" ] \
      || die "internal relay error: composed turn $(printf '%s' "$RELAY_ENTRY_JSON" | jq -r '.turn') != run turn $turn"
    append_ledger "$state_dir" "$RELAY_ENTRY_JSON"
    RELAY_ENTRY_JSON=""
  else
    append_ledger "$state_dir" "$(jq -n -c --argjson turn "$turn" --arg role "$role" --arg run "$run_id" \
      --arg file "$prompt_copy" --arg sha "$(sha_file "$prompt_copy")" \
      '{turn:$turn,role:$role,run_id:$run,kind:"direct",prompt_file:$file,prompt_sha256:$sha}')"
  fi
  build_skills_bundle "$root" "$skills_bundle"
  charter="$AIDEV_HOME/agents/$role.md"
  [ -f "$charter" ] || die "canonical charter missing: $charter"
  config_hash="$(configuration_hash "$charter")"
  tree_hash="$(working_tree_hash "$root")"
  previous=""
  previous_session=""
  prior_turn=0
  if [ "$action" = "resume" ]; then
    latest="$(latest_numbered_file "$state_dir" response 2>/dev/null || true)"
    [ -n "$latest" ] || die "no prior turn exists for $role/$run_id"
    previous="$latest"
    prior_turn="$(basename "$latest" | sed 's/^response-//;s/\.json$//')"
    previous_config="$(jq -r '.config_hash // ""' "$latest" 2>/dev/null || true)"
    [ "$previous_config" = "$config_hash" ] \
      || die "role '$role' configuration, charter, adapter, or skills changed since this run started; start a new run-id"
    [ "$(jq -r '.role // ""' "$latest")" = "$role" ] && [ "$(jq -r '.run_id // ""' "$latest")" = "$run_id" ] \
      || die "prior response is not bound to $role/$run_id"
    previous_session="$(jq -r '.session_id // ""' "$latest")"
    if [ "$ROLE_TRANSPORT" = "resume" ] && [ -z "$previous_session" ]; then
      die "no resumable session exists for $role/$run_id; start a new run-id"
    fi
  fi
  build_replay_transcript "$state_dir" "$prior_turn" "$transcript"
  access="$(requested_access "$role")"
  allowed="$(allowed_paths_json "$root" "$role")"
  denied="$(denied_paths_json "$root" "$role")"
  invocation="$key-$run_id-$role-$turn"
  jq -n \
    --arg protocol "$PROTOCOL" --arg invocation_id "$invocation" --arg action "$action" \
    --arg role "$role" --arg run_id "$run_id" --arg runner "$ROLE_RUNNER" --arg transport "$ROLE_TRANSPORT" \
    --arg workspace "$root" --arg model "$ROLE_MODEL" --argjson settings "$ROLE_SETTINGS" \
    --argjson role_config "$ROLE_CONFIG" --arg charter_file "$charter" --arg prompt_file "$prompt_copy" \
    --arg output_file "$output" --arg state_dir "$state_dir" --arg previous_session_id "$previous_session" \
    --arg previous_response_file "$previous" --arg transcript_file "$transcript" \
    --arg access "$access" --argjson allowed_write_paths "$allowed" --argjson denied_write_paths "$denied" \
    --argjson skills "$ROLE_SKILLS" \
    --argjson skill_sources "$ROLE_SKILL_SOURCES" --argjson skill_packages "$RESOLVED_SKILL_PACKAGES" \
    --arg skills_bundle_file "$skills_bundle" --arg config_hash "$config_hash" --arg input_tree_hash "$tree_hash" \
    '{protocol:$protocol,invocation_id:$invocation_id,action:$action,role:$role,run_id:$run_id,
      runner:$runner,transport:$transport,workspace:$workspace,model:$model,settings:$settings,
      role_config:$role_config,charter_file:$charter_file,prompt_file:$prompt_file,output_file:$output_file,
      state_dir:$state_dir,previous_session_id:$previous_session_id,previous_response_file:$previous_response_file,
      transcript_file:$transcript_file,access:$access,allowed_write_paths:$allowed_write_paths,
      denied_write_paths:$denied_write_paths,
      skills:$skills,skill_sources:$skill_sources,skill_packages:$skill_packages,
      skills_bundle_file:$skills_bundle_file,config_hash:$config_hash,input_tree_hash:$input_tree_hash}' > "$request"
  # Coarse, provider-neutral backstop: a total wall-clock deadline around the whole invoke, so ANY
  # adapter (including third-party ones with no internal heartbeat) cannot hang the orchestrator forever.
  # Opt-in via roles.json settings.invoke_deadline_secs (0/absent = off). Fine-grained inactivity
  # liveness stays inside the adapter, which alone can see the model's token/event stream.
  set +e
  hb_deadline="$(printf '%s' "$ROLE_SETTINGS" | jq -r '.invoke_deadline_secs // 0' 2>/dev/null || echo 0)"
  hb_deadline="${hb_deadline%%.*}"   # truncate a fractional value instead of silently zeroing it below
  case "$hb_deadline" in ''|*[!0-9]*) hb_deadline=0 ;; esac
  timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then timeout_bin="gtimeout"; fi
  if [ "$hb_deadline" -gt 0 ] && [ -n "$timeout_bin" ]; then
    "$timeout_bin" --signal=TERM "$hb_deadline" "$ROLE_ADAPTER" invoke "$request" "$response"; rc=$?
  else
    [ "$hb_deadline" -gt 0 ] && [ -z "$timeout_bin" ] && \
      echo "role-runner: warning: invoke_deadline_secs=${hb_deadline} but neither timeout nor gtimeout is on PATH; running '$ROLE_RUNNER' without a coarse deadline (install coreutils for gtimeout)" >&2
    "$ROLE_ADAPTER" invoke "$request" "$response"; rc=$?
  fi
  set -e
  if [ "$hb_deadline" -gt 0 ] && [ "$rc" -eq 124 ]; then
    die "runner '$ROLE_RUNNER' exceeded invoke_deadline_secs (${hb_deadline}s) for role '$role'; no result accepted. Raise the deadline or repair the adapter"
  fi
  if [ "$access" = "read-only" ]; then
    after_tree_hash="$(working_tree_hash "$root")"
    [ "$after_tree_hash" = "$tree_hash" ] \
      || die "read-only runner '$ROLE_RUNNER' returned after the project tree changed; discard this review and rerun it against a stable tree"
  fi
  if [ ! -f "$response" ]; then
    die "runner '$ROLE_RUNNER' exited $rc without a response; inspect $state_dir"
  fi
  validate_bound_response "$response" "$invocation" "$role" "$run_id" "$config_hash" "$tree_hash" "$output"
  if [ "$rc" -ne 0 ]; then
    reason="$(jq -r '.reason // "adapter returned no reason"' "$response")"
    die "runner '$ROLE_RUNNER' could not perform role '$role': $reason. Repair it or choose another runner/model"
  fi
  [ "$(jq -r '.status' "$response")" != "failed" ] \
    || die "runner '$ROLE_RUNNER' reported failure: $(jq -r '.reason' "$response")"
  jq . "$response"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  inspect)
    role="${1:-}"; valid_role "$role" || usage
    root="$(find_root "${2:-$PWD}")"
    load_role "$root" "$role"
    validate_role_capabilities "$role"
    skill_check="$(mktemp "${TMPDIR:-/tmp}/aidev-skills.XXXXXX")"
    build_skills_bundle "$root" "$skill_check"
    rm -f "$skill_check"
    jq -n --arg role "$role" --arg kind "$ROLE_KIND" --arg runner "$ROLE_RUNNER" \
      --arg transport "$ROLE_TRANSPORT" --arg model "$ROLE_MODEL" --argjson settings "$ROLE_SETTINGS" \
      --argjson skills "$ROLE_SKILLS" --argjson skill_sources "$ROLE_SKILL_SOURCES" \
      --argjson skill_packages "$RESOLVED_SKILL_PACKAGES" --argjson capabilities "$ROLE_DESCRIPTION" \
      '{role:$role,kind:$kind,runner:$runner,transport:$transport,model:$model,settings:$settings,
        skills:$skills,skill_sources:$skill_sources,skill_packages:$skill_packages,capabilities:$capabilities}'
    ;;
  doctor)
    root="$(find_root "${1:-$PWD}")"
    validate_profile "$root"
    echo "Role runner check: $root"
    for role in architect planner implementer reviewer; do doctor_role "$root" "$role"; done
    echo "Role runner check: PASS"
    ;;
  probe)
    root="$(find_root "${1:-$PWD}")"
    validate_profile "$root"
    echo "Role runner live probe: $root"
    for role in architect planner implementer reviewer; do
      doctor_role "$root" "$role"
      probe_role "$root" "$role"
    done
    echo "Role runner live probe: PASS"
    ;;
  tree-hash)
    root="$(find_root "${1:-$PWD}")"
    working_tree_hash "$root"
    ;;
  run)
    role="${1:-}"; action="${2:-}"; run_id="${3:-}"; prompt="${4:-}"
    valid_role "$role" || usage
    [ -n "$action" ] && [ -n "$run_id" ] && [ -n "$prompt" ] || usage
    root="$(find_root "${5:-$PWD}")"
    run_external "$root" "$role" "$action" "$run_id" "$prompt"
    ;;
  relay)
    [ "$#" -ge 4 ] || usage
    relay_role "$@"
    ;;
  journal)
    [ "$#" -ge 4 ] || usage
    journal_message "$@"
    ;;
  verify-relay)
    [ -n "${1:-}" ] || usage
    verify_relay "$@"
    ;;
  last)
    role="${1:-}"; run_id="${2:-}"; valid_role "$role" || usage
    case "$run_id" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
    root="$(find_root "${3:-$PWD}")"
    key="$(project_key "$root")"
    state_dir="$AIDEV_STATE_ROOT/$key/$run_id/$role"
    latest="$(latest_numbered_file "$state_dir" response 2>/dev/null || true)"
    [ -n "$latest" ] || die "no result for $role/$run_id"
    message="$(jq -r '.message_file // ""' "$latest")"
    case "$message" in "$state_dir"/message-*.md) : ;; *) die "result points outside its private state directory" ;; esac
    [ -f "$message" ] && [ ! -L "$message" ] || die "result has no readable regular message file"
    cat "$message"
    ;;
  *) usage ;;
esac
