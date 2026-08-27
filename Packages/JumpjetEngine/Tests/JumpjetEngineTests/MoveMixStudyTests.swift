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
        ]

        print("\n  mix              sweeps/s   accept   RMSD    Rg drift   backbone RMSF")
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
                format: "  %-15s %8.1f  %7.3f  %6.2f  %9.3f  %14.3f",
                (name as NSString).utf8String!, 400 / seconds,
                trajectory.acceptanceRatio, rmsd, radiusDrift, backboneShift))
        }
        print("")
    }
}
