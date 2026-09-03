#!/usr/bin/env bash
# aidev external-agent adapter template (aidev-agent/v1).
# Copy this file to .aidev/harness/adapters/<runner-id>.sh during /aidev:init, then implement the
# four commands below for the chosen CLI/API. Do not put executable commands in project roles.json.
set -euo pipefail
cmd="${1:-}"

case "$cmd" in
  describe)
    cat <<'JSON'
{"protocol":"aidev-agent/v1","kind":"external","roles":["reviewer"],"repo_access":["read-only"],"continuity":["replay"],"human_io":["relay"],"web_research":false}
JSON
    ;;
  doctor)
    # $2 includes role, workspace, explicit transport, opaque model/settings, requested access,
    # allowed/denied write paths, and resolved skill packages. Check capabilities. Be specific.
    printf '%s\n' '{"ok":false,"reason":"adapter template is not configured; implement doctor, probe, and invoke for this agent"}'
    exit 1
    ;;
  probe)
    # Perform a minimal live, read-only call with the exact requested model/settings. Also test the
    # selected transport across two turns (for example, recall a nonce via resume or replay).
    # This is where init verifies model/transport errors instead of silently substituting a fallback.
    printf '%s\n' '{"ok":false,"reason":"adapter template has no live model probe"}'
    exit 1
    ;;
  invoke)
    # $2 request JSON; $3 response JSON. Read charter_file + prompt_file + skills_bundle_file and
    # skill_packages, honor configured transport, enforce allowed + denied paths, then invoke the agent.
    # Do not let the agent bypass or game later checkpoints. Write its final Markdown to output_file.
    # Echo every binding field below from the request in the normalized response.
    request="${2:?request JSON required}"; response="${3:?response JSON required}"
    reason="adapter template cannot invoke an agent"
    jq -n --arg reason "$reason" \
      --arg protocol "$(jq -r '.protocol' "$request")" --arg invocation_id "$(jq -r '.invocation_id' "$request")" \
      --arg role "$(jq -r '.role' "$request")" --arg run_id "$(jq -r '.run_id' "$request")" \
      --arg transport "$(jq -r '.transport' "$request")" --arg config_hash "$(jq -r '.config_hash' "$request")" \
      --arg input_tree_hash "$(jq -r '.input_tree_hash' "$request")" \
      '{protocol:$protocol,invocation_id:$invocation_id,role:$role,run_id:$run_id,transport:$transport,
        config_hash:$config_hash,input_tree_hash:$input_tree_hash,status:"failed",reason:$reason,
        message_file:"",session_id:""}' > "$response"
    exit 1
    ;;
  *) echo "usage: $0 describe|doctor <request.json>|probe <request.json>|invoke <request.json> <response.json>" >&2; exit 2 ;;
esac
