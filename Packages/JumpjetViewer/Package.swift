// swift-tools-version: 6.2
// JUMPjet: JumpjetViewer
// SceneKit renderer: backbone tube, side-chain sticks, colour modes.
//
// The dependency rule lives in CLAUDE.md and is enforced here by what each
// manifest is allowed to name. Keep it acyclic and keep it shallow.

import PackageDescription

let package = Package(
    name: "JumpjetViewer",
    // iOS 17 is the real deployment target (Observation framework, Swift Charts).
    // The macOS platform exists only so `swift test` can run these suites on the
    // host without booting a simulator, so keep it as LOW as the sources compile
    // against: pinning it to the newest macOS makes the test binaries unloadable
    // on an older machine or CI runner.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JumpjetViewer", targets: ["JumpjetViewer"])
    ],
    dependencies: [
        .package(path: "../JumpjetCore"),
        .package(path: "../JumpjetHUD"),
        // TEST ONLY. Named at package level so the test target can reach it,
        // but deliberately absent from the JumpjetViewer target's dependencies:
        // the renderer must not know how a file was read. The tests use it to
        // render real fixtures rather than hand-built toy structures.
        .package(path: "../JumpjetParse"),
    ],
    targets: [
        .target(
            name: "JumpjetViewer",
            dependencies: ["JumpjetCore", "JumpjetHUD"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JumpjetViewerTests",
            dependencies: ["JumpjetViewer", "JumpjetParse"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
