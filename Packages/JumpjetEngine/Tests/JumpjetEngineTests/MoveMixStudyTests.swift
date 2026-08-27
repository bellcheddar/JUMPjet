import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

/// What each kind of move actually BUYS.
///
/// Backbone moves are 97% of the sampler's measured cost, and the throughput
/// target turns on them. Before optimising them it is worth knowing whether
/// they are doing anything: a move that costs a quarter of the protein's atoms
/// per proposal and, at the amplitude needed to be accepted, barely changes the
/// structure, is a move to make rarer rather than faster.
///
///     JUMPJET_STUDY=1 swift test -c release --filter MoveMixStudyTests
final class MoveMixStudyTests: XCTestCase {

    func testWhatEachMoveKindContributes() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_STUDY"] != nil,
            "set JUMPJET_STUDY=1 to run the move-mix study")

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

        // Every mix normalised to the same total, so the only thing changing is
        // WHICH moves are proposed, not how many.
        //
        // The metric that decides this is backbone motion per SECOND, not per
        // sweep. Fewer backbone moves means fewer sweeps are needed to reach the
        // same backbone sampling only if a sweep costs the same, and it does
        // not: a backbone move costs a hundred times what a side-chain move
        // costs, so trading them for cheaper sweeps can buy MORE backbone
        // motion per unit of wall clock, not less.
        let mixes: [(String, MoveMix)] = [
            ("as shipped", MoveMix()),
            ("no backbone", MoveMix(
                sideChainPerturbation: 0.64, rotamerJump: 0.28, ringFlip: 0.08,
                backbonePerturbation: 0)),
            ("backbone only", MoveMix(
                sideChainPerturbation: 0, rotamerJump: 0, ringFlip: 0,
                backbonePerturbation: 1.0)),
            ("half backbone", MoveMix(
                sideChainPerturbation: 0.56, rotamerJump: 0.25, ringFlip: 0.08,
                backbonePerturbation: 0.11)),
            ("backbone 6%", MoveMix(
                sideChainPerturbation: 0.60, rotamerJump: 0.26, ringFlip: 0.08,
                backbonePerturbation: 0.06)),
            ("backbone 3%", MoveMix(
                sideChainPerturbation: 0.62, rotamerJump: 0.27, ringFlip: 0.08,
                backbonePerturbation: 0.03)),
            ("backbone 1.5%", MoveMix(
                sideChainPerturbation: 0.63, rotamerJump: 0.275, ringFlip: 0.08,
                backbonePerturbation: 0.015)),
        ]

        print("\n  mix              sweeps/s   accept   RMSD    Rg drift   bbRMSF   bbRMSF/s")
        for (name, mix) in mixes {
            let started = Date()
            let sampler = MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: RunConfiguration(
                    sweeps: 400, snapshotStride: 400, seed: 31),
                mix: mix)
            let trajectory = sampler.run()
            let seconds = Date().timeIntervalSince(started)
            let final = Array(trajectory.frame(trajectory.frameCount - 1))

            let rmsd = Geometry.superposedRMSD(moving: final, onto: structure.positions)
            let radiusDrift = abs(
                Geometry.radiusOfGyration(final)
                    - Geometry.radiusOfGyration(structure.positions))

            // How much the BACKBONE itself moved, which is what a backbone move
            // is for. Side-chain moves cannot touch an alpha carbon at all.
            var backboneShift: Float = 0
            var counted = 0
            let fit = Geometry.kabschSuperposition(
                moving: final, onto: structure.positions)
            let fitted = Geometry.apply(fit, to: final)
            for residue in structure.residues.indices {
                guard let atom = structure.alphaCarbonIndex(ofResidue: residue) else { continue }
                backboneShift += simd_distance(fitted[atom], structure.atoms[atom].position)
                counted += 1
            }
            backboneShift /= Float(max(1, counted))

            print(String(
                format: "  %-15s %8.1f  %7.3f  %6.2f  %9.3f  %7.3f  %9.4f",
                (name as NSString).utf8String!, 400 / seconds,
                trajectory.acceptanceRatio, rmsd, radiusDrift, backboneShift,
                backboneShift / Float(seconds)))
        }
        print("")
    }
}
