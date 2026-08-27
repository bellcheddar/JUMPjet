import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

final class SamplerTests: XCTestCase {

    private func haemoglobin() throws -> Structure {
        try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold
        ).structure
    }

    private func tables() throws -> TorsionTables {
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        return try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))
    }

    /// A flexibility prior that varies along the chain, so the amplitude
    /// scaling and the spring softening are both genuinely exercised rather
    /// than being constant-folded away by a uniform input.
    private func syntheticPrior(_ structure: Structure) -> [Float] {
        (0..<structure.residueCount).map { index in
            let phase = Float(index) / Float(max(1, structure.residueCount - 1))
            return 0.15 + 0.7 * (sin(phase * 6) * 0.5 + 0.5)
        }
    }

    // MARK: - Tables

    /// The Ramachandran table must have wells in the right places, or every
    /// backbone move is accepted and the sampler generates conformations no
    /// protein adopts.
    func testRamachandranTableHasWellsWhereItShould() throws {
        let tables = try tables()
        let alpha = tables.backboneEnergy(phi: -63, psi: -43, residue: .alanine)
        let beta = tables.backboneEnergy(phi: -135, psi: 135, residue: .alanine)
        let forbidden = tables.backboneEnergy(phi: 60, psi: -120, residue: .alanine)

        XCTAssertLessThan(alpha, 1.0, "the alpha region should be favourable")
        XCTAssertLessThan(beta, 2.0, "the beta region should be favourable")
        XCTAssertGreaterThan(forbidden, 3.0, "the bridge region should be expensive")
        XCTAssertGreaterThan(forbidden, alpha + 3)
    }

    /// Glycine has no side chain and therefore reaches the left-handed region
    /// that everything else is excluded from. If the tables did not separate
    /// it, every glycine turn in every protein would read as a violation.
    func testGlycineHasItsOwnTable() throws {
        let tables = try tables()
        let leftHanded = (phi: Float(60), psi: Float(40))
        XCTAssertLessThan(
            tables.backboneEnergy(phi: leftHanded.phi, psi: leftHanded.psi, residue: .glycine),
            tables.backboneEnergy(phi: leftHanded.phi, psi: leftHanded.psi, residue: .alanine))
    }

    func testChi1PrefersStaggeredRotamers() throws {
        let tables = try tables()
        for residue in [AminoAcid.leucine, .methionine, .lysine, .serine] {
            let staggered = [-60, 180].map {
                tables.chiEnergy(Float($0), chiIndex: 0, residue: residue)
            }.min() ?? 99
            let eclipsed = tables.chiEnergy(0, chiIndex: 0, residue: residue)
            XCTAssertGreaterThan(
                eclipsed, staggered + 1.5,
                "\(residue.rawValue) shows no staggered preference")
        }
    }

    /// -180 and +180 are the same angle. A table indexed without wrapping puts
    /// a discontinuity in the middle of the extended backbone region.
    func testTableLookupWrapsAtTheSeam() throws {
        let tables = try tables()
        XCTAssertEqual(
            tables.backboneEnergy(phi: -179.9, psi: 100, residue: .alanine),
            tables.backboneEnergy(phi: 180.0, psi: 100, residue: .alanine),
            accuracy: 1e-6)
        XCTAssertEqual(TorsionTables.bin(-180, bins: 36), TorsionTables.bin(180, bins: 36))
    }

    // MARK: - The grid

    /// The grid is an optimisation, so it must agree exactly with the brute
    /// force it replaces. Anything else is a silent change to the physics.
    func testGridFindsTheSameStericPairsAsAllPairs() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology,
            flexibility: syntheticPrior(structure), tables: TorsionTables.flat())
        let positions = structure.positions
        let grid = NeighbourGrid(positions: positions, cutoff: model.stericCutoff)

        var bruteForce: Float = 0
        for i in 0..<structure.atomCount {
            for j in (i + 1)..<structure.atomCount {
                bruteForce += model.stericPairEnergy(i, j, positions[i], positions[j])
            }
        }

        var viaGrid: Float = 0
        var candidates: [Int32] = []
        for i in 0..<structure.atomCount {
            candidates.removeAll(keepingCapacity: true)
            grid.appendNeighbours(of: positions[i], into: &candidates)
            for candidate in candidates where Int(candidate) > i {
                viaGrid += model.stericPairEnergy(
                    i, Int(candidate), positions[i], positions[Int(candidate)])
            }
        }

        XCTAssertGreaterThan(bruteForce, 0, "the fixture should have some close contacts")
        XCTAssertEqual(viaGrid, bruteForce, accuracy: max(1e-3, bruteForce * 1e-5))
    }

    // MARK: - Energy model

    /// Bonded and 1-3 pairs are held at fixed geometry, so a repulsion between
    /// them is a constant nothing can relieve. Leaving them in makes every
    /// residue permanently clashed with itself.
    func testBondedAndOneThreePairsAreExcludedFromSterics() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology,
            flexibility: syntheticPrior(structure), tables: TorsionTables.flat())

        let nitrogen = try XCTUnwrap(structure.atomIndex(named: "N", inResidue: 5))
        let alpha = try XCTUnwrap(structure.alphaCarbonIndex(ofResidue: 5))
        let carbon = try XCTUnwrap(structure.atomIndex(named: "C", inResidue: 5))

        // N-CA is bonded, N...C is 1-3 across CA. Both must be silent.
        XCTAssertEqual(
            model.stericPairEnergy(
                nitrogen, alpha, structure.atoms[nitrogen].position,
                structure.atoms[alpha].position), 0)
        XCTAssertEqual(
            model.stericPairEnergy(
                nitrogen, carbon, structure.atoms[nitrogen].position,
                structure.atoms[carbon].position), 0)
    }

    /// A flexible residue's springs must be softer than a rigid one's. This is
    /// the build plan's central coupling between the neural layer and the
    /// physics, and without it the prior changes nothing.
    func testFlexibilitySoftensTheElasticNetwork() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)

        let rigid = EnergyModel(
            structure: structure, topology: topology,
            flexibility: [Float](repeating: 0, count: structure.residueCount),
            tables: TorsionTables.flat())
        let floppy = EnergyModel(
            structure: structure, topology: topology,
            flexibility: [Float](repeating: 1, count: structure.residueCount),
            tables: TorsionTables.flat())

        let rigidMean = rigid.networkConstant.reduce(0, +) / Float(rigid.networkConstant.count)
        let floppyMean = floppy.networkConstant.reduce(0, +) / Float(floppy.networkConstant.count)
        XCTAssertGreaterThan(rigidMean, floppyMean * 5)
        XCTAssertGreaterThan(floppyMean, 0, "even a floppy loop keeps some restraint")
    }

    /// Side-chain torsions split no network pair, because no alpha carbon
    /// moves. That is what makes them cheap enough to dominate the move mix.
    func testSideChainTorsionsSplitNoNetworkPairs() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology,
            flexibility: syntheticPrior(structure), tables: TorsionTables.flat())

        var backboneWithPairs = 0
        for (index, torsion) in topology.torsions.enumerated() {
            if torsion.isBackboneTorsion {
                if !model.networkPairsCrossing[index].isEmpty { backboneWithPairs += 1 }
            } else {
                XCTAssertTrue(
                    model.networkPairsCrossing[index].isEmpty,
                    "a side-chain torsion should split no network pair")
            }
        }
        XCTAssertGreaterThan(backboneWithPairs, 100)
    }

    // MARK: - The sampler

    /// The build plan's definition of done: replay from a seed.
    func testTheSameSeedGivesAnIdenticalTrajectory() throws {
        let structure = try haemoglobin()
        let prior = syntheticPrior(structure)
        let tables = try tables()
        var configuration = RunConfiguration(sweeps: 60, snapshotStride: 20, seed: 12_345)
        configuration.temperature = 1.2

        func trajectory() -> Trajectory {
            MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: configuration
            ).run()
        }

        let first = trajectory()
        let second = trajectory()

        XCTAssertEqual(first.frameCount, second.frameCount)
        XCTAssertEqual(first.acceptanceRatio, second.acceptanceRatio)
        XCTAssertEqual(first.positions, second.positions)
    }

    func testADifferentSeedGivesADifferentTrajectory() throws {
        let structure = try haemoglobin()
        let prior = syntheticPrior(structure)
        let tables = try tables()

        func trajectory(seed: UInt64) -> Trajectory {
            MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: RunConfiguration(sweeps: 60, snapshotStride: 20, seed: seed)
            ).run()
        }

        XCTAssertNotEqual(trajectory(seed: 1).positions, trajectory(seed: 2).positions)
    }

    /// Bond lengths are the representation's fixed point. If a single one moves
    /// over a whole run, the torsional model has been violated somewhere.
    func testBondLengthsSurviveAWholeRun() throws {
        let structure = try haemoglobin()
        let bonds = BondFinder.bonds(in: structure)
        let reference = bonds.map {
            simd_distance(structure.atoms[$0.a].position, structure.atoms[$0.b].position)
        }

        let sampler = MonteCarloSampler(
            structure: structure, flexibility: syntheticPrior(structure),
            tables: try tables(),
            configuration: RunConfiguration(sweeps: 200, snapshotStride: 200, seed: 7))
        let trajectory = sampler.run()
        let final = Array(trajectory.frame(trajectory.frameCount - 1))

        for (index, bond) in bonds.enumerated() {
            XCTAssertEqual(
                simd_distance(final[bond.a], final[bond.b]), reference[index],
                accuracy: 1e-2, "bond \(index) changed length during the run")
        }
    }

    /// The build plan's energy sanity check: no runaway across a long run.
    func testEnergyDoesNotRunAway() throws {
        let structure = try haemoglobin()
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: syntheticPrior(structure),
            tables: try tables(),
            configuration: RunConfiguration(sweeps: 300, snapshotStride: 30, seed: 3))
        let trajectory = sampler.run()

        let energies = trajectory.energies.map(\.total)
        let first = try XCTUnwrap(energies.first)
        for (index, energy) in energies.enumerated() {
            XCTAssertTrue(energy.isFinite, "frame \(index) has a non-finite energy")
            XCTAssertLessThan(
                energy, first + 5000,
                "the energy exploded by frame \(index): \(first) to \(energy)")
        }
        // And it must not be frozen either: a sampler that accepts nothing has
        // a beautifully stable energy and does no science.
        XCTAssertNotEqual(energies.first, energies.last)
    }

    /// The structure must actually move, and must not fly apart.
    func testTheStructureMovesButStaysFolded() throws {
        let structure = try haemoglobin()
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: syntheticPrior(structure),
            tables: try tables(),
            configuration: RunConfiguration(sweeps: 300, snapshotStride: 300, seed: 11))
        let trajectory = sampler.run()
        let final = Array(trajectory.frame(trajectory.frameCount - 1))

        let rmsd = Geometry.superposedRMSD(moving: final, onto: structure.positions)
        XCTAssertGreaterThan(rmsd, 0.05, "nothing moved at all")
        XCTAssertLessThan(rmsd, 6.0, "the fold came apart")

        let startRadius = Geometry.radiusOfGyration(structure.positions)
        let endRadius = Geometry.radiusOfGyration(final)
        XCTAssertEqual(
            endRadius, startRadius, accuracy: startRadius * 0.25,
            "the radius of gyration moved too far for a folded protein")
    }

    /// The build plan asks for an acceptance ratio between 20 and 60% at the
    /// default throttle. That is a property of the move amplitudes, and it is
    /// the number that says whether the sampler is exploring or stuck.
    func testAcceptanceRatioIsInTheUsefulBand() throws {
        let structure = try haemoglobin()
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: syntheticPrior(structure),
            tables: try tables(),
            configuration: RunConfiguration(sweeps: 300, snapshotStride: 300, seed: 5))
        let trajectory = sampler.run()
        print("acceptance ratio \(trajectory.acceptanceRatio), "
            + "\(trajectory.sweepsPerSecond) sweeps/s")
        XCTAssertGreaterThan(trajectory.acceptanceRatio, 0.20)
        XCTAssertLessThan(trajectory.acceptanceRatio, 0.60)
    }

    func testFramesAreStoredOnTheSnapshotStride() throws {
        let structure = try haemoglobin()
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: syntheticPrior(structure),
            tables: try tables(),
            configuration: RunConfiguration(sweeps: 100, snapshotStride: 25, seed: 9))
        let trajectory = sampler.run()
        XCTAssertEqual(trajectory.sweeps, [0, 25, 50, 75, 100])
        XCTAssertEqual(trajectory.positions.count, 5 * structure.atomCount)
    }

    /// Cancelling must return the frames already collected, not throw them away.
    func testProgressCallbackCanStopTheRun() throws {
        let structure = try haemoglobin()
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: syntheticPrior(structure),
            tables: try tables(),
            configuration: RunConfiguration(sweeps: 1000, snapshotStride: 10, seed: 4))

        var lastSeen = 0
        let trajectory = sampler.run { progress in
            lastSeen = progress.sweep
            return progress.sweep < 30
        }
        XCTAssertEqual(lastSeen, 30)
        XCTAssertGreaterThan(trajectory.frameCount, 1)
        XCTAssertLessThan(trajectory.frameCount, 10)
    }
}
