// swift-tools-version: 6.2
// JUMPjet: JumpjetMovie
// Offscreen SCNRenderer into AVAssetWriter: the shareable payoff.

import PackageDescription

let package = Package(
    name: "JumpjetMovie",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JumpjetMovie", targets: ["JumpjetMovie"])
    ],
    dependencies: [
        .package(path: "../JumpjetCore"),
        .package(path: "../JumpjetViewer"),
        .package(path: "../JumpjetHUD"),
        // TEST ONLY: exporting a real trajectory needs a real structure, and
        // the demo export needs a real sampler to make one.
        .package(path: "../JumpjetParse"),
        .package(path: "../JumpjetEngine"),
    ],
    targets: [
        .target(
            name: "JumpjetMovie",
            dependencies: ["JumpjetCore", "JumpjetViewer", "JumpjetHUD"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JumpjetMovieTests",
            dependencies: ["JumpjetMovie", "JumpjetParse", "JumpjetEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
