// swift-tools-version: 6.2
// JUMPjet: JumpjetNeural
// ESM-2 on the Apple Neural Engine, and the flexibility prior built from it.
//
// The dependency rule lives in CLAUDE.md and is enforced here by what each
// manifest is allowed to name. Keep it acyclic and keep it shallow.

import PackageDescription

let package = Package(
    name: "JumpjetNeural",
    // iOS 17 is the real deployment target, and the .mlpackage is converted at
    // iOS17 to match. The macOS platform exists so `swift test` can run these
    // suites on the host without booting a simulator; Core ML is available on
    // both, so the model itself is genuinely exercised there.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JumpjetNeural", targets: ["JumpjetNeural"])
    ],
    dependencies: [
        .package(path: "../JumpjetCore")
    ],
    targets: [
        .target(
            name: "JumpjetNeural",
            dependencies: ["JumpjetCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JumpjetNeuralTests",
            dependencies: ["JumpjetNeural"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
