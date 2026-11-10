// swift-tools-version:5.9
// Mac-side unit tests for the bridge core:  cd ClaudeBridge && swift test
// The runner does not use this package; project.yml compiles Core/ directly.
import PackageDescription

let package = Package(
    name: "ClaudeBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeBridgeCore", path: "Core"),
        .testTarget(name: "ClaudeBridgeCoreTests", dependencies: ["ClaudeBridgeCore"], path: "Tests"),
    ],
    swiftLanguageVersions: [.v5]
)
