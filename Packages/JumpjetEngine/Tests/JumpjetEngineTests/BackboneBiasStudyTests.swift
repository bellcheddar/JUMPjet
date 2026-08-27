import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

/// Does biasing backbone selection towards CHEAP torsions starve the middle of
/// the chain?
///
/// A pivot's cost is tiny near a terminus and a quarter of the protein in the
/// middle, so weighting by cost necessarily samples the middle less. The
/// equilibrium ensemble is unaffected (the proposal is its own reverse and the
/// weights are fixed), but a mid-chain that never moves within a run anybody
/// would actually sit through is a practical failure even when it is a
/// theoretical success.
///
/// So this reports alpha-carbon displacement split by position along the chain.
///
///     JUMPJET_STUDY=1 swift test -c release --filter BackboneBiasStudyTests
final class BackboneBiasStudyTests: XCTestCase {

    func testWhetherCostBiasStarvesTheMiddle() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_STUDY"] != nil,
            "set JUMPJET_STUDY=1 to run the backbone bias study")

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

        // A fixed, generous backbone share, so the only variable is the bias.
        let mix = MoveMix(
            sideChainPerturbation: 0.50, rotamerJump: 0.22, ringFlip: 0.06,
            backbonePerturbation: 0.22)

        print("\n  bias   sweeps/s   accept   outer thirds   middle third   ratio")
        for bias in [Float(0), 0.25, 0.5, 0.75, 1.0] {
            var amplitudes = MoveAmplitudes()
            amplitudes.backboneCostBias = bias

            let started = Date()
            let sampler = MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: RunConfiguration(sweeps: 400, snapshotStride: 400, seed: 31),
                mix: mix, amplitudes: amplitudes)
            let trajectory = sampler.run()
            let seconds = Date().timeIntervalSince(started)
            let final = Array(trajectory.frame(trajectory.frameCount - 1))

            let fit = Geometry.kabschSuperposition(moving: final, onto: structure.positions)
            let fitted = Geometry.apply(fit, to: final)

            var outer: Float = 0, outerCount = 0
            var middle: Float = 0, middleCount = 0
            let total = structure.residueCount
            for residue in structure.residues.indices {
                guard let atom = structure.alphaCarbonIndex(ofResidue: residue) else { continue }
                let shift = simd_distance(fitted[atom], structure.atoms[atom].position)
                if residue < total / 3 || residue >= total * 2 / 3 {
                    outer += shift
                    outerCount += 1
                } else {
                    middle += shift
                    middleCount += 1
                }
            }
            outer /= Float(max(1, outerCount))
            middle /= Float(max(1, middleCount))

            print(String(
                format: "  %4.2f  %8.1f  %7.3f  %13.3f  %13.3f  %6.2f",
                bias, 400 / seconds, trajectory.acceptanceRatio, outer, middle,
                outer > 0 ? middle / outer : 0))
        }
        print("")
    }
}
