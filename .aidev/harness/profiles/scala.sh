# aidev language profile — Scala (sbt)
LANG_NAME="Scala (sbt)"
ARCHITECTURE_PATHS=( "docs/architecture" )
# Traits/case classes live in a 'contract' package; tests under src/test. Both frozen.
FROZEN_PATHS=( "src/main/scala/contract" "src/test" )
IMPLEMENTATION_PATHS=( "src/main/scala" )
DEPENDENCY_PATHS=( "build.sbt" "project/build.properties" "project/plugins.sbt" "project/Dependencies.scala" )
# Conformance: scalac (via sbt). If an impl extends a frozen trait and the signature drifts, it won't compile.
CONFORMANCE_CMD="sbt -batch -error compile Test/compile"
# Strict variant: add scalacOptions += "-Werror" in build.sbt so warnings fail conformance.
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD="sbt -batch -error scalafmtCheckAll"
# Behavior: ScalaTest / MUnit.
BEHAVIOR_CMD="sbt -batch -error test"
CONTRACT_HOWTO="Data types: case class / sealed trait. Signatures: trait in the contract package; implementations extend it so scalac enforces the signature. Tests: ScalaTest or MUnit under src/test. Implementations under src/main/scala (outside the contract package)."
