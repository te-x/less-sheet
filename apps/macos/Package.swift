// swift-tools-version: 6.1
// FROZEN by the planner (viewer-ui contract): target/dependency/platform
// changes go through the change-request process. Implementer-owned code lives
// in Sources/LessSheetKit and Sources/LessSheetApp; Sources/Contracts and
// Tests are planner-owned.
import PackageDescription

// The Zig core is built by the component gate BEFORE swift build (see
// .aidev/profile.sh CONFORMANCE_CMD) and linked statically from
// ../../backend/zig-out/lib. Absolute -L via Context keeps the link
// independent of the linker's working directory. The C header is
// single-sourced from ../../api/lesssheet.h through a checked-in relative
// symlink at Sources/CLessSheet/include/lesssheet.h — never copy it.
let backendLibDir = "\(Context.packageDirectory)/../../backend/zig-out/lib"

let package = Package(
    name: "LessSheetMac",
    // macOS 26 minimum: the viewer-ui overlay uses the Liquid Glass
    // materials (glassEffect family). Part of the frozen contract.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "LessSheet", targets: ["LessSheetApp"])
    ],
    targets: [
        // C shim vendoring the workspace-frozen core header (no Swift code).
        .target(name: "CLessSheet"),
        // Planner-owned contract surface: protocols + types the UI consumes.
        .target(name: "Contracts"),
        // Swift wrapper over the core C ABI + view-model logic
        // (implementer-owned; conformances pinned by frozen tests).
        .target(
            name: "LessSheetKit",
            dependencies: ["Contracts", "CLessSheet"],
            linkerSettings: [
                .linkedLibrary("lesssheet"),
                .unsafeFlags(["-L\(backendLibDir)"]),
            ]
        ),
        // Thin SwiftUI shell (implementer-owned).
        .executableTarget(
            name: "LessSheetApp",
            dependencies: ["LessSheetKit", "Contracts"]
        ),
        .testTarget(
            name: "LessSheetKitTests",
            dependencies: ["LessSheetKit", "Contracts", "CLessSheet"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
