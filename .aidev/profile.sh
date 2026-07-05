# aidev profile — polyglot workspace ROOT (components have their own nested .aidev/)
LANG_NAME="workspace (Zig core + Swift/macOS frontend)"
# The language-NEUTRAL cross-component contract (C headers, .proto, OpenAPI): frozen for EVERYONE.
FROZEN_PATHS=( "api" )
CONFORMANCE_CMD=""
# Full gate = integrity on api/ + every component's own gate, chained:
BEHAVIOR_CMD="bash backend/.aidev/gate.sh backend && bash apps/macos/.aidev/gate.sh apps/macos"
CONTRACT_HOWTO="The root owns api/ — the language-neutral boundary artifacts (.h / .proto / openapi.yaml) every component consumes; each component's compiler enforces conformance to it. Each component is its own aidev project (nested .aidev/profile.sh). The guard hook and gate resolve the NEAREST enclosing profile, so component rules apply inside components and the root freeze protects api/ from every implementer."
