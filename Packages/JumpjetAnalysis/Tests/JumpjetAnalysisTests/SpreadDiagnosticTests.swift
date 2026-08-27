import XCTest
import JumpjetCore
import JumpjetEngine
import JumpjetParse

@testable import JumpjetAnalysis

/// How much do backbone torsions actually move, now that the sampler proposes
/// far fewer backbone moves?
///
/// The PCA's 8 degree threshold was chosen before that change and is what now
/// refuses to project a short run. This prints the distribution so the
/// replacement is a measurement rather than another guess.
///
///     JUMPJET_STUDY=1 swift test -c release --filter SpreadDiagnosticTests
final class SpreadDiagnosticTests: XCTestCase {

    func testTheBackboneSpreadDistribution() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_STUDY"] != nil,
            "set JUMPJET_STUDY=1")

        let structure = try PDBParser.parse(
            Fixtures.text("structures/AF-P04406-F1-model_v6.pdb"), source: .alphaFold
        ).structure
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        let tables = try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))
        let prior = (0..<structure.residueCount).map { index -> Float in
            0.15 + 0.7 * (sin(Float(index) / 20) * 0.5 + 0.5)
        }

        for sweeps in [600, 2_000, 5_000] {
            let sampler = MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: RunConfiguration(
                    sweeps: sweeps, snapshotStride: max(10, sweeps / 60), seed: 17))
            let trajectory = sampler.run()
            let frames = TrajectoryFrames(
                positions: trajectory.positions, atomCount: trajectory.atomCount,
                sweeps: trajectory.sweeps)

            let backbone = TorsionSeries.backboneTracks(
                structure: structure, trajectory: frames)
            let spreads = backbone
                .map { max(DihedralPCA.circularSpread($0.phi),
                           DihedralPCA.circularSpread($0.psi)) }
                .sorted(by: >)
            guard !spreads.isEmpty else { continue }

            func percentile(_ p: Double) -> Float {
                spreads[min(spreads.count - 1, Int(Double(spreads.count) * p))]
            }
            print(String(
                format: "  %5d sweeps, %3d frames: max %6.2f  p10 %6.2f  median %6.2f  "
                    + "min %6.2f   above 8 deg: %3d   above 2 deg: %3d",
                sweeps, frames.frameCount, spreads[0], percentile(0.10),
                percentile(0.50), spreads[spreads.count - 1],
                spreads.filter { $0 >= 8 }.count,
                spreads.filter { $0 >= 2 }.count))
        }
        print("")
    }
}
