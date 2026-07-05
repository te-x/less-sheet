// swift-tools-version: 6.1
// Frozen by the planner from the first contract freeze — target/dependency changes go through it.
import PackageDescription

let package = Package(
    name: "LessSheetMac",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "LessSheetKit"),
        .testTarget(name: "LessSheetKitTests", dependencies: ["LessSheetKit"]),
    ]
)
