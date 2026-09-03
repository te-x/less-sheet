# aidev profile — polyglot workspace ROOT (components have their own nested .aidev/)
LANG_NAME="workspace (edit me)"
ARCHITECTURE_PATHS=( "docs/architecture" )
# The language-NEUTRAL cross-component contract (C headers, .proto, OpenAPI): frozen for EVERYONE.
FROZEN_PATHS=( "api" )
# Implementation paths belong to nested component profiles; define root-level ones only when needed.
IMPLEMENTATION_PATHS=()
# Dependency manifests belong to each nested component profile. Define root-level ones here only when needed.
DEPENDENCY_PATHS=()
CONFORMANCE_CMD=""
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD=""   # components own their own quality gates; set a root-level lint only if needed
# Full gate = integrity on api/ + every component's own gate, chained:
BEHAVIOR_CMD="echo 'edit BEHAVIOR_CMD, e.g.: bash .aidev/harness/gate.sh --require-frozen backend && bash .aidev/harness/gate.sh --require-frozen apps/macos' && false"
CONTRACT_HOWTO="The root owns api/ — the language-neutral boundary artifacts (.h / .proto / openapi.yaml) every component consumes; each component's compiler enforces conformance to it. Each component is its own aidev project (nested .aidev/profile.sh). The guard hook and gate resolve the NEAREST enclosing profile, so component rules apply inside components and the root freeze protects api/ from every implementer."
