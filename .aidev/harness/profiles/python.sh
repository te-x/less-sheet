# aidev language profile — Python
LANG_NAME="Python"
ARCHITECTURE_PATHS=( "docs/architecture" )
# Paths the implementer may NOT touch (the contract + tests). Recursive.
FROZEN_PATHS=( "contracts" "tests" )
IMPLEMENTATION_PATHS=( "src" )
# Production dependency manifests + lockfiles. The planner owns these; the implementer may not edit them.
DEPENDENCY_PATHS=( "pyproject.toml" "requirements.txt" "requirements-dev.txt" "requirements-prod.txt" "requirements" "setup.py" "setup.cfg" "Pipfile" "Pipfile.lock" "poetry.lock" "uv.lock" "pdm.lock" "environment.yml" "environment.yaml" "conda-lock.yml" "pixi.toml" "pixi.lock" )
# Conformance: the type-checker enforces that implementations match the frozen signatures.
CONFORMANCE_CMD="mypy --no-error-summary src tests contracts"
# Strict variant: CONFORMANCE_CMD="mypy --strict --no-error-summary src tests contracts"
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD="ruff check src tests contracts"
# Behavior: the spec tests.
BEHAVIOR_CMD="python -m pytest -q"
# Guidance injected for the planner.
CONTRACT_HOWTO="Data types: @dataclass(frozen=True). Signatures: typing.Protocol + stub functions (body 'raise NotImplementedError') under contracts/. A conformance line '_c: SomeProtocol = some_impl' in a test makes mypy fail on signature drift. Tests: pytest under tests/. Implementations under src/."
