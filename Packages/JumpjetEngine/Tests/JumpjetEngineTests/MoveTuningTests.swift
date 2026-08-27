import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

/// The final tuning run: the candidate move configurations, over several seeds.
///
/// Several seeds because the earlier single-seed sweeps were noisy enough to
/// invert a trend: the cost-bias study showed outer-third motion RISING from
/// bias 0 to 0.5 and falling again, which is not a mechanism, it is one run.
/// Throughput is stable across seeds and the displacement figures are not, so
/// the displacements are averaged and the conclusion rests on the mean.
///
///     JUMPJET_STUDY=1 swift test -c release --filter MoveTuningTests
final class MoveTuningTests: XCTestCase {

    private struct Candidate {
        let name: String
        let backboneShare: Float
        let bias: Float
    }

    func testTheCandidateConfigurations() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_STUDY"] != nil,
            "set JUMPJET_STUDY=1 to run the tuning study")

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

        // Bias 0 throughout: the equal-wall-clock run showed the bias buying
        // speed at a real cost in mid-chain coverage (55.2% down to 35.6%),
        // while cutting the SHARE cost almost nothing (60.6% to 55.2%). So the
        // question left is how low the share can go.
        let candidates = [
            Candidate(name: "22% (shipped)", backboneShare: 0.22, bias: 0),
            Candidate(name: "11%", backboneShare: 0.11, bias: 0),
            Candidate(name: "6%", backboneShare: 0.06, bias: 0),
            Candidate(name: "3%", backboneShare: 0.03, bias: 0),
            Candidate(name: "1.5%", backboneShare: 0.015, bias: 0),
        ]
        let seeds: [UInt64] = [31, 77, 1_301]
        // Every configuration gets the same wall clock, and takes as many
        // sweeps as it can inside it.
        let budgetSeconds = 8.0

        print(
            "\n  Equal wall clock: \(Int(budgetSeconds)) s per run, 3 seeds, 335 residues")
        print(
            "  configuration    sweeps/s   sweeps   accept   bbRMSF   "
                + "bb touched   mid-chain touched")
        for candidate in candidates {
            // Redistribute whatever the backbone gives up across the other three
            // in their original proportions, so the mix always sums to one.
            let rest = 1 - candidate.backboneShare
            let mix = MoveMix(
                sideChainPerturbation: rest * 0.50 / 0.78,
                rotamerJump: rest * 0.22 / 0.78,
                ringFlip: rest * 0.06 / 0.78,
                backbonePerturbation: candidate.backboneShare)
            var amplitudes = MoveAmplitudes()
            amplitudes.backboneCostBias = candidate.bias

            var rates: [Double] = []
            var accepts: [Float] = []
            var rmsds: [Float] = []
            var backbones: [Float] = []
            var ratios: [Float] = []
            var coverage: [Float] = []
            var sweeps: [Float] = []
            var midCoverage: [Float] = []

            for seed in seeds {
                let started = Date()
                let sampler = MonteCarloSampler(
                    structure: structure, flexibility: prior, tables: tables,
                    // A real snapshot stride. At 100,000 the only frame ever
                    // stored was frame 0, so "the last frame" was the STARTING
                    // structure and every displacement read exactly 0.000 --
                    // a column of zeros that looked like a metric.
                    configuration: RunConfiguration(
                        sweeps: 100_000, snapshotStride: 50, seed: seed),
                    mix: mix, amplitudes: amplitudes)
                var sweepsDone = 0
                let trajectory = sampler.run { progress in
                    sweepsDone = progress.sweep
                    return Date().timeIntervalSince(started) < budgetSeconds
                }
                rates.append(
                    Double(sweepsDone) / Date().timeIntervalSince(started))
                sweeps.append(Float(sweepsDone))
                accepts.append(trajectory.acceptanceRatio)

                let final = Array(trajectory.frame(trajectory.frameCount - 1))
                rmsds.append(
                    Geometry.superposedRMSD(moving: final, onto: structure.positions))

                let fit = Geometry.kabschSuperposition(
                    moving: final, onto: structure.positions)
                let fitted = Geometry.apply(fit, to: final)
                var outer: Float = 0, outerCount = 0
                var middle: Float = 0, middleCount = 0
                var all: Float = 0, allCount = 0
                for residue in structure.residues.indices {
                    guard let atom = structure.alphaCarbonIndex(ofResidue: residue) else {
                        continue
                    }
                    let shift = simd_distance(
                        fitted[atom], structure.atoms[atom].position)
                    all += shift
                    allCount += 1
                    if residue < structure.residueCount / 3
                        || residue >= structure.residueCount * 2 / 3
                    {
                        outer += shift
                        outerCount += 1
                    } else {
                        middle += shift
                        middleCount += 1
                    }
                }
                // Coverage: what fraction of backbone torsions were accepted at
                // least once, overall and in the middle third of the chain.
                var touched = 0, backboneCount = 0
                var midTouched = 0, midCount = 0
                let topology = TorsionTopology(structure: structure)
                for (index, torsion) in topology.torsions.enumerated()
                where torsion.isBackboneTorsion {
                    backboneCount += 1
                    let hit = index < sampler.acceptedPerTorsion.count
                        && sampler.acceptedPerTorsion[index] > 0
                    if hit { touched += 1 }
                    let residue = torsion.residueIndex
                    if residue >= structure.residueCount / 3,
                        residue < structure.residueCount * 2 / 3
                    {
                        midCount += 1
                        if hit { midTouched += 1 }
                    }
                }
                coverage.append(Float(touched) / Float(max(1, backboneCount)))
                midCoverage.append(Float(midTouched) / Float(max(1, midCount)))

                backbones.append(all / Float(max(1, allCount)))
                let outerMean = outer / Float(max(1, outerCount))
                ratios.append(
                    outerMean > 0 ? (middle / Float(max(1, middleCount))) / outerMean : 0)
            }

            func mean(_ values: [Float]) -> Float {
                values.reduce(0, +) / Float(values.count)
            }
            _ = rmsds
            _ = ratios
            print(String(
                format: "  %-15s %8.1f  %7.0f  %7.3f  %7.3f  %10.1f%%  %16.1f%%",
                (candidate.name as NSString).utf8String!,
                rates.reduce(0, +) / Double(rates.count), mean(sweeps), mean(accepts),
                mean(backbones), mean(coverage) * 100, mean(midCoverage) * 100))
        }
        print("")
    }
}
