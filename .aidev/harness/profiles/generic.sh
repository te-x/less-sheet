# aidev language profile — generic (EDIT THESE for your language/repo)
LANG_NAME="(generic — edit me)"
ARCHITECTURE_PATHS=( "docs/architecture" )
# Paths the implementer may NOT touch (the contract + tests). Recursive.
FROZEN_PATHS=( "contracts" "tests" )
IMPLEMENTATION_PATHS=( "src" )
# Configure every real dependency/build file during /aidev:init, e.g. DEPENDENCY_PATHS=( "manifest" "lockfile" ).
# Entries are literal file or directory paths; globs are not supported. Left undefined here because a
# generic profile cannot infer them safely.
# Conformance: your compiler/type-checker command (leave empty to skip).
CONFORMANCE_CMD=""
# Prefer your compiler's warnings-as-errors flag in CONFORMANCE_CMD once the baseline is warning-clean.
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD=""   # your language's strict linter / format check
# Behavior: your test runner command (required).
BEHAVIOR_CMD="echo 'Set BEHAVIOR_CMD in .aidev/profile.sh to your test command' && false"
CONTRACT_HOWTO="Put the public surface (types + signatures) under contracts/ in your language's interface idiom, frozen. Implement under src/. Tests under tests/. Set CONFORMANCE_CMD (compiler/type-checker) and BEHAVIOR_CMD (test runner) to your real commands."
