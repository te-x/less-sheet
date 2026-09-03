#!/usr/bin/env bash
# Thin wrapper: run the aidev harness vendored in this repository (.aidev/harness/), so a fresh
# clone needs nothing installed; fall back to a user-level install only if the vendored copy is gone.
d="$(cd "$(dirname "$0")/.." && pwd -P)"
while [ "$d" != "/" ] && [ ! -f "$d/.aidev/harness/gate.sh" ]; do d="$(dirname "$d")"; done
h="$d/.aidev/harness/gate.sh"; [ -f "$h" ] || h="$HOME/.claude/aidev/gate.sh"
exec bash "$h" "$@"
