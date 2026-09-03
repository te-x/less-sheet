# aidev language profile — Swift (SwiftPM; SwiftUI app logic behind protocols)
LANG_NAME="Swift (SwiftPM)"
ARCHITECTURE_PATHS=( "docs/architecture" )
FROZEN_PATHS=( "Sources/Contracts" "Tests" )
IMPLEMENTATION_PATHS=( "Sources" )
# SwiftPM dependency definition + resolved lock. Add the repo's Xcode Package.resolved path when applicable.
DEPENDENCY_PATHS=( "Package.swift" "Package.resolved" )
CONFORMANCE_CMD="swift build"
# Strict variant (warnings as errors): CONFORMANCE_CMD="swift build -Xswiftc -warnings-as-errors"
# Optional deterministic quality gate — enable during init ONLY after verifying the tool runs here:
# QUALITY_CMD="swiftlint --strict"
BEHAVIOR_CMD="swift test"
CONTRACT_HOWTO="Data types: struct/enum (Codable where crossing the wire). Signatures: protocol in Sources/Contracts; implementations declare conformance so swiftc enforces the signature, and a frozen test pins it via 'let _: any Foo = FooImpl()'. Tests: XCTest/swift-testing under Tests/. Implementations in Sources/<Target>; keep SwiftUI views thin over the protocol layer. UI-app schemes may need 'xcodebuild -scheme <App> build/test' instead of swift build/test — adjust the commands."
