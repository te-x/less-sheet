# aidev profile — polyglot workspace ROOT (components have their own nested .aidev/)
LANG_NAME="workspace (Zig core + Swift/macOS and C/GTK4 frontends)"
# The language-NEUTRAL cross-component contract (C headers, .proto, OpenAPI): frozen for EVERYONE.
FROZEN_PATHS=( "api" )
# Architecture (ARCH docs + PROJECT.md) is owned here at the workspace root.
ARCHITECTURE_PATHS=( "docs/architecture" )
# Dependencies + implementation are DELEGATED to the nested component profiles
# (backend/.aidev, apps/macos/.aidev, apps/gtk/.aidev); the root owns only api/ + architecture.
DEPENDENCY_PATHS=( )
IMPLEMENTATION_PATHS=( )
CONFORMANCE_CMD=""
# Full gate = integrity on api/ + every component's own gate, chained (each gate runs its own
# conformance + optional QUALITY_CMD + behavior, so a component's quality gate propagates here for free):
BEHAVIOR_CMD="bash backend/.aidev/gate.sh backend && bash apps/macos/.aidev/gate.sh apps/macos && bash apps/gtk/.aidev/gate.sh apps/gtk"
CONTRACT_HOWTO="The root owns api/ — the language-neutral boundary artifacts (.h / .proto / openapi.yaml) every component consumes; each component's compiler enforces conformance to it. Each component is its own aidev project (nested .aidev/profile.sh). The guard hook and gate resolve the NEAREST enclosing profile, so component rules apply inside components and the root freeze protects api/ from every implementer."
