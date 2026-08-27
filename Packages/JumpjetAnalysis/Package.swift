// swift-tools-version: 6.2
// JUMPjet: JumpjetAnalysis
// The flight recorder: RMSD, RMSF, rotamer jumps, ring flips, basins.
//
// Depends on JumpjetCore ONLY, and deliberately not on JumpjetEngine. The
// analysis takes frames of coordinates, not a sampler's output type, which is
// what lets the whole of it be tested against synthetic trajectories with
// planted transitions rather than against whatever the sampler happened to
// produce. A jump detector validated on its own engine's output is a detector
// that agrees with itself.

import PackageDescription

let package = Package(
    name: "JumpjetAnalysis",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JumpjetAnalysis", targets: ["JumpjetAnalysis"])
    ],
    dependencies: [
        .package(path: "../JumpjetCore"),
        // TEST ONLY, absent from the JumpjetAnalysis target: the end-to-end
        // timing check needs a real structure and a real trajectory, and the
        // analysis itself must still know nothing about files or samplers.
        .package(path: "../JumpjetParse"),
        .package(path: "../JumpjetEngine"),
    ],
    targets: [
        .target(
            name: "JumpjetAnalysis",
            dependencies: ["JumpjetCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JumpjetAnalysisTests",
            dependencies: ["JumpjetAnalysis", "JumpjetParse", "JumpjetEngine"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
