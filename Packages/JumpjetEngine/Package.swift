// swift-tools-version: 6.2
// JUMPjet: JumpjetEngine
// JetEngine: the torsional Monte Carlo sampler.
//
// OpenMM-INSPIRED and not OpenMM. OpenMM has no iOS platform, is C++ and
// CUDA/OpenCL, and ground rule 1 of the build plan says in terms not to attempt
// a cross-compile. Nothing here is ported, linked or derived from it.

import PackageDescription

let package = Package(
    name: "JumpjetEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JumpjetEngine", targets: ["JumpjetEngine"])
    ],
    dependencies: [
        .package(path: "../JumpjetCore"),
        // TEST ONLY, for running the sampler on real structures. Named at
        // package level and absent from the JumpjetEngine target: the physics
        // must not know how a file was read.
        .package(path: "../JumpjetParse"),
    ],
    targets: [
        .target(
            name: "JumpjetEngine",
            dependencies: ["JumpjetCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JumpjetEngineTests",
            dependencies: ["JumpjetEngine", "JumpjetParse"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
