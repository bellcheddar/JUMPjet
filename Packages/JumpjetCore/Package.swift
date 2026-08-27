// swift-tools-version: 6.2
// JUMPjet: JumpjetCore
// Structure model, chemistry tables and geometry. Depends on nothing.
//
// The dependency rule lives in CLAUDE.md and is enforced here by what each
// manifest is allowed to name. Keep it acyclic and keep it shallow.

import PackageDescription

let package = Package(
    name: "JumpjetCore",
    // iOS 17 is the real deployment target (Observation framework, Swift Charts).
    // The macOS platform exists only so `swift test` can run these suites on the
    // host without booting a simulator, so keep it as LOW as the sources compile
    // against: pinning it to the newest macOS makes the test binaries unloadable
    // on an older machine or CI runner.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JumpjetCore", targets: ["JumpjetCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "JumpjetCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JumpjetCoreTests",
            dependencies: ["JumpjetCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
