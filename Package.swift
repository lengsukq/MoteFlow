// swift-tools-version: 5.9
import PackageDescription

// Modular SwiftPM package exposing the pure, zero-UI domain & protocol layer (ATVVCore).
// Any pure model, codec, store, or state machine placed under GoogleRemote/Sources/Core
// is automatically compiled and tested without manual file exclusion lists.
let package = Package(
    name: "MoteFlowCorePackage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ATVVCore", targets: ["ATVVCore"])
    ],
    targets: [
        .target(
            name: "ATVVCore",
            path: "GoogleRemote/Sources/Core"
        ),
        .testTarget(
            name: "ATVVCoreTests",
            dependencies: ["ATVVCore"],
            path: "Tests"
        )
    ]
)
