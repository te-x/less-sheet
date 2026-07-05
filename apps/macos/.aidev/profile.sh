# aidev language profile — Swift (SwiftPM; SwiftUI app logic behind protocols)
LANG_NAME="Swift (SwiftPM)"
# Package.swift is a FILE entry: frozen so the implementer can't drop test targets or add deps (planner owns it).
FROZEN_PATHS=( "Sources/Contracts" "Tests" "Package.swift" )
CONFORMANCE_CMD="swift build"
BEHAVIOR_CMD="swift test"
CONTRACT_HOWTO="Data types: struct/enum (Codable where crossing the wire). Signatures: protocol in Sources/Contracts; implementations declare conformance so swiftc enforces the signature, and a frozen test pins it via 'let _: any Foo = FooImpl()'. Tests: XCTest/swift-testing under Tests/. Implementations in Sources/<Target>; keep SwiftUI views thin over the protocol layer. UI-app schemes may need 'xcodebuild -scheme <App> build/test' instead of swift build/test — adjust the commands."
