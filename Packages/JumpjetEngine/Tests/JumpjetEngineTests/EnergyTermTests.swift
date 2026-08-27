import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

/// Each energy term against a value computed by hand.
///
/// The build plan's definition of done asks for this specifically, and the
/// reason is that property tests do not catch a wrong CONSTANT. "The energy
/// rises as the atoms approach" is true of a term with the wrong strength, the
/// wrong radii and the wrong power, and every one of those changes what the
/// sampler does.
final class EnergyTermTests: XCTestCase {

    /// Two atoms in one residue, at a chosen separation, with nothing else.
    private func pair(
        _ first: Element, _ second: Element, separation: Float,
        strength: Float = 6.0
    ) -> (EnergyModel, [SIMD3<Float>]) {
        let atoms = [
            // Named so they are not a bonded pair by BondFinder's reckoning: an
            // excluded pair would score zero and the test would pass on a
            // completely broken term.
            Atom(name: "XA", element: first, position: SIMD3(0, 0, 0), residueIndex: 0),
            Atom(name: "XB", element: second, position: SIMD3(separation, 0, 0),
                 residueIndex: 0),
        ]
        let structure = Structure(
            identifier: "PAIR", title: "", source: .local, atoms: atoms,
            residues: [
                Residue(
                    kind: .alanine, rawName: "ALA", sequenceNumber: 1, chainIndex: 0,
                    atomRange: 0..<2)
            ],
            chains: [Chain(id: "A", residueRange: 0..<1)])
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology, flexibility: [0.5],
            tables: TorsionTables.flat(), stericStrength: strength)
        return (model, structure.positions)
    }

    /// Soft-sphere repulsion is `strength * overlap^2`, where the overlap is
    /// how far inside the sum of the scaled radii the pair sits.
    ///
    /// Two carbons: 1.70 A Bondi radius, scaled by the build plan's 0.85, gives
    /// 1.445 each and a contact distance of 2.890 A. At 2.0 A apart the overlap
    /// is 0.890 A, so with a strength of 6 the energy is 6 * 0.890^2 = 4.7526.
    func testSoftSphereEnergyAgainstAHandComputedValue() {
        let contact = Float(1.70 * 0.85) * 2
        XCTAssertEqual(contact, 2.890, accuracy: 1e-5, "the contact distance itself")

        let (model, positions) = pair(.carbon, .carbon, separation: 2.0)
        let overlap = contact - 2.0
        XCTAssertEqual(
            model.stericPairEnergy(0, 1, positions[0], positions[1]),
            6.0 * overlap * overlap, accuracy: 1e-4)
        XCTAssertEqual(
            model.stericPairEnergy(0, 1, positions[0], positions[1]), 4.7526, accuracy: 1e-3)
    }

    /// Exactly at contact the energy is zero, and beyond it stays zero. A term
    /// that went slightly negative outside the cutoff would be an attraction
    /// nobody asked for.
    func testSoftSphereIsZeroAtAndBeyondContact() {
        for separation in [Float(2.890), 2.9, 3.5, 8.0] {
            let (model, positions) = pair(.carbon, .carbon, separation: separation)
            XCTAssertEqual(
                model.stericPairEnergy(0, 1, positions[0], positions[1]), 0, accuracy: 1e-5,
                "at \(separation) A")
        }
    }

    /// Different elements use different radii. Carbon and oxygen: 1.445 and
    /// 1.292, contact 2.737 A. At 2.0 the overlap is 0.737, energy
    /// 6 * 0.737^2 = 3.2585.
    func testSoftSphereUsesPerElementRadii() {
        let contact = Float(1.70 * 0.85) + Float(1.52 * 0.85)
        XCTAssertEqual(contact, 2.737, accuracy: 1e-5)
        let (model, positions) = pair(.carbon, .oxygen, separation: 2.0)
        XCTAssertEqual(
            model.stericPairEnergy(0, 1, positions[0], positions[1]), 3.2585, accuracy: 1e-3)
    }

    /// The elastic network is `k * (r - r0)^2` per pair, with `k` scaled down
    /// by the flexibility prior as `springConstant * (1 - 0.9 * softness)`.
    ///
    /// Two alpha carbons 6 A apart in the reference, at flexibility 0, give
    /// `k = 1.2`. Stretched to 7 A the extension is 1 A, so the energy is 1.2.
    func testElasticNetworkEnergyAgainstAHandComputedValue() {
        let structure = Self.twoAlphaCarbons(separation: 6)
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology, flexibility: [0, 0],
            tables: TorsionTables.flat())

        XCTAssertEqual(model.networkA.count, 1, "the two alpha carbons should be one pair")
        XCTAssertEqual(model.networkRestLength[0], 6, accuracy: 1e-4)
        XCTAssertEqual(model.networkConstant[0], 1.2, accuracy: 1e-5)

        var positions = structure.positions
        positions[1] = SIMD3(7, 0, 0)
        let energy = model.totalEnergy(positions: positions, topology: topology)
        XCTAssertEqual(energy.network, 1.2, accuracy: 1e-4)

        // Compressed by the same amount costs the same: it is a spring.
        positions[1] = SIMD3(5, 0, 0)
        XCTAssertEqual(
            model.totalEnergy(positions: positions, topology: topology).network, 1.2,
            accuracy: 1e-4)
    }

    /// At full flexibility the constant is `1.2 * (1 - 0.9) = 0.12`, a tenth of
    /// the rigid value. This is the build plan's coupling between the neural
    /// layer and the physics, and the exact factor is what decides whether a
    /// floppy loop actually moves.
    func testFlexibilityScalesTheSpringConstantByTheStatedFactor() {
        let structure = Self.twoAlphaCarbons(separation: 6)
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology, flexibility: [1, 1],
            tables: TorsionTables.flat())
        XCTAssertEqual(model.networkConstant[0], 0.12, accuracy: 1e-5)
    }

    /// Beyond the 11 A cutoff there is no pair at all.
    func testPairsBeyondTheCutoffAreNotInTheNetwork() {
        for separation in [Float(10.9), 11.1] {
            let structure = Self.twoAlphaCarbons(separation: separation)
            let topology = TorsionTopology(structure: structure)
            let model = EnergyModel(
                structure: structure, topology: topology, flexibility: [0, 0],
                tables: TorsionTables.flat())
            XCTAssertEqual(
                model.networkA.count, separation < 11 ? 1 : 0,
                "at \(separation) A")
        }
    }

    /// The torsional term is a table lookup, so the hand check is that a known
    /// angle lands in the bin it should. 24 bins over 360 degrees is 15 degrees
    /// each, and bin 0 starts at -180.
    func testTorsionBinningAgainstHandComputedIndices() {
        XCTAssertEqual(TorsionTables.bin(-180, bins: 24), 0)
        XCTAssertEqual(TorsionTables.bin(-172, bins: 24), 0)
        XCTAssertEqual(TorsionTables.bin(-165, bins: 24), 1)
        XCTAssertEqual(TorsionTables.bin(0, bins: 24), 12)
        XCTAssertEqual(TorsionTables.bin(179.9, bins: 24), 23)
        XCTAssertEqual(TorsionTables.bin(180, bins: 24), 0, "180 wraps onto -180")
        XCTAssertEqual(TorsionTables.bin(-60, bins: 36), 12)
    }

    private static func twoAlphaCarbons(separation: Float) -> Structure {
        let atoms = [
            Atom(name: "CA", element: .carbon, position: SIMD3(0, 0, 0), residueIndex: 0),
            Atom(name: "CA", element: .carbon, position: SIMD3(separation, 0, 0),
                 residueIndex: 1),
        ]
        return Structure(
            identifier: "NET", title: "", source: .local, atoms: atoms,
            residues: [
                Residue(
                    kind: .alanine, rawName: "ALA", sequenceNumber: 1, chainIndex: 0,
                    atomRange: 0..<1),
                Residue(
                    kind: .alanine, rawName: "ALA", sequenceNumber: 2, chainIndex: 0,
                    atomRange: 1..<2),
            ],
            chains: [Chain(id: "A", residueRange: 0..<2)])
    }
}

/// The build plan's stability check: no runaway across 50,000 sweeps on three
/// test proteins.
///
/// Opt-in, because at the measured rates it is several minutes of wall clock and
/// does not belong in a suite anyone runs before a commit. Run it after any
/// change to the force field:
///
///     JUMPJET_LONGRUN=1 swift test -c release --filter LongRunTests
final class LongRunTests: XCTestCase {

    func testEnergyIsStableAcrossFiftyThousandSweeps() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_LONGRUN"] != nil,
            "set JUMPJET_LONGRUN=1 to run the 50,000 sweep stability check")

        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        let tables = try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))

        for fixture in [
            "AF-P69905-F1-model_v6.pdb", "AF-P04406-F1-model_v6.pdb", "1bab.pdb",
        ] {
            let structure = try StructureReader.parse(
                Fixtures.text("structures/\(fixture)"),
                source: fixture.hasPrefix("AF") ? .alphaFold : .pdbe
            ).structure
            let prior = (0..<structure.residueCount).map { index -> Float in
                0.15 + 0.7 * (sin(Float(index) / 20) * 0.5 + 0.5)
            }

            let sampler = MonteCarloSampler(
                structure: structure, flexibility: prior, tables: tables,
                configuration: RunConfiguration(
                    sweeps: 50_000, snapshotStride: 5_000, seed: 99))
            let trajectory = sampler.run()
            let energies = trajectory.energies.map(\.total)
            let first = try XCTUnwrap(energies.first)
            let last = try XCTUnwrap(energies.last)
            let final = Array(trajectory.frame(trajectory.frameCount - 1))
            let rmsd = Geometry.superposedRMSD(moving: final, onto: structure.positions)

            print(String(
                format: "  %-30s %6d residues  energy %8.1f -> %8.1f  RMSD %5.2f A  "
                    + "acceptance %.3f",
                (fixture as NSString).utf8String!, structure.residueCount, first, last,
                rmsd, trajectory.acceptanceRatio))

            for energy in energies { XCTAssertTrue(energy.isFinite, "\(fixture) went non-finite") }
            XCTAssertLessThan(last, first + 5_000, "\(fixture) ran away")
            XCTAssertLessThan(rmsd, 12, "\(fixture) came apart")
            XCTAssertGreaterThan(trajectory.acceptanceRatio, 0.15)
            XCTAssertLessThan(trajectory.acceptanceRatio, 0.65)
        }
    }
}
