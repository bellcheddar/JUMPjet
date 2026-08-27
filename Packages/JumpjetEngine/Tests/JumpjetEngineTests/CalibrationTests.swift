import XCTest
import JumpjetCore
import JumpjetParse

@testable import JumpjetEngine

/// Finds the move amplitudes that put the acceptance ratio in the band the
/// build plan's definition of done specifies (20 to 60 per cent).
///
/// Not part of the ordinary suite: it is a calibration, run by hand when the
/// force field changes, and its output is copied into `MoveAmplitudes`.
/// Run with `swift test -c release --filter CalibrationTests`.
final class CalibrationTests: XCTestCase {

    func testSweepAmplitudesForTheAcceptanceBand() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_CALIBRATE"] != nil,
            "set JUMPJET_CALIBRATE=1 to run the amplitude sweep")

        let structure = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"), source: .alphaFold
        ).structure
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        let tables = try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))
        let prior = (0..<structure.residueCount).map { index -> Float in
            0.15 + 0.7 * (sin(Float(index) / 20) * 0.5 + 0.5)
        }

        print("\n  sideChain  backbone   acceptance")
        for scale in [Float(1), 2, 3, 4, 6, 8] {
            var amplitudes = MoveAmplitudes()
            amplitudes.sideChainBase = 4 * scale
            amplitudes.sideChainFlexible = 26 * scale
            amplitudes.backboneBase = 0.6 * scale
            amplitudes.backboneFlexible = 3.4 * scale

            let sampler = MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: RunConfiguration(sweeps: 120, snapshotStride: 1000, seed: 21),
                amplitudes: amplitudes)
            let trajectory = sampler.run()
            print(String(
                format: "  %9.1f  %8.2f   %.3f", amplitudes.sideChainBase,
                amplitudes.backboneBase, trajectory.acceptanceRatio))
        }
        print("")
    }
}
