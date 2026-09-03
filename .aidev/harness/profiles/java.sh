# aidev language profile — Java (Maven)
LANG_NAME="Java (Maven)"
ARCHITECTURE_PATHS=( "docs/architecture" )
# Interfaces/records live in a 'contract' package; tests under src/test. Both frozen.
FROZEN_PATHS=( "src/main/java/contract" "src/test" )
IMPLEMENTATION_PATHS=( "src/main/java" )
DEPENDENCY_PATHS=( "pom.xml" ".mvn" )
# Conformance: javac. If an impl class 'implements' a frozen interface and the signature drifts, it won't compile.
CONFORMANCE_CMD="mvn -q -DskipTests test-compile"
# Strict variant (warnings as errors): CONFORMANCE_CMD="mvn -q -DskipTests -Dmaven.compiler.failOnWarning=true test-compile"
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD="mvn -q spotless:check"
# Behavior: JUnit.
BEHAVIOR_CMD="mvn -q test"
CONTRACT_HOWTO="Data types: record. Signatures: interface in the contract package; implementations 'implements' it so javac enforces the signature. Tests: JUnit under src/test. Implementations under src/main/java (outside the contract package)."
