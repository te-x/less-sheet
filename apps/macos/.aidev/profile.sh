# aidev language profile — Swift (SwiftPM; SwiftUI app logic behind protocols)
LANG_NAME="Swift (SwiftPM)"
# Package.swift is a FILE entry: frozen so the implementer can't drop test targets or add deps (planner owns it).
FROZEN_PATHS=( "Sources/Contracts" "Tests" "Package.swift" )
ARCHITECTURE_PATHS=( )                   # architecture owned at the workspace root (docs/architecture)
DEPENDENCY_PATHS=( "Package.swift" )     # SwiftPM manifest (also frozen above — planner-owned)
IMPLEMENTATION_PATHS=( "Sources/LessSheetApp" "Sources/LessSheetKit" "Sources/CLessSheet" )
# The Kit links the Zig core statically (backend/zig-out/lib/liblesssheet.a),
# so conformance builds the backend artifact first.
# STALE-LINK GUARD (find-seek round 2 lesson): SwiftPM does NOT track the .a as a
# build input (linked via -L/linkedLibrary), so after rebuilding the backend we
# delete the link products — otherwise the gate can certify binaries still linked
# against an OLD core (proven both directions by experiment, REVIEW-6-frontend).
# Object caches survive; only the final links are redone (seconds).
# csv-corpus AC5: generate the 5 representative corpus files (git-ignored .build/
# corpus-cache) the frozen CorpusColdOpenTests launch probe reads. Hermetic +
# deterministic (fixed seed); the clean-room generator is stdlib-Python (a gate
# prerequisite). The backend build.zig generate-step covers the AC2-4 sweep; this
# covers only the macOS UI-sample. Heavy cases stay out of the gate (on-demand perf).
CONFORMANCE_CMD='(cd ../../backend && zig build) && rm -rf .build/*/debug/LessSheet .build/*/debug/*.xctest .build/*/release/LessSheet .build/*/release/*.xctest && swift build && python3 ../../tools/csvgen/gen.py --case unicode_emoji --case eol_crlf --case wide_100k_cols --case enc_utf16le --case happy_numeric --seed 1337 --out .build/corpus-cache'
# QUALITY_CMD deferred: `swiftlint --strict` has a 333-violation baseline (199 identifier_name,
# 69 line_length, plus complexity/length) — enabling needs a project .swiftlint.yml tuned to our
# standards + a cleanup pass (its own slice), not a mechanical reformat. Command once clean:
# QUALITY_CMD="swiftlint lint --strict Sources"
BEHAVIOR_CMD="swift test"
CONTRACT_HOWTO="Data types: struct/enum (Codable where crossing the wire). Signatures: protocol in Sources/Contracts; implementations declare conformance so swiftc enforces the signature, and a frozen test pins it via 'let _: any Foo = FooImpl()'. Tests: XCTest/swift-testing under Tests/. Implementations in Sources/<Target>; keep SwiftUI views thin over the protocol layer. UI-app schemes may need 'xcodebuild -scheme <App> build/test' instead of swift build/test — adjust the commands."
