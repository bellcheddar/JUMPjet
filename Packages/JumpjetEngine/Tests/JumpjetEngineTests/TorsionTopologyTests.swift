import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

final class TorsionTopologyTests: XCTestCase {

    private func haemoglobin() throws -> Structure {
        try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold
        ).structure
    }

    func testEveryStandardTorsionIsFound() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)

        var phi = 0, psi = 0, chi = 0
        for torsion in topology.torsions {
            switch torsion.kind {
            case .phi: phi += 1
            case .psi: psi += 1
            case .chi: chi += 1
            }
        }
        // 142 residues: 141 phi (none for the first) and 141 psi (none for the
        // last), minus the prolines whose phi is locked by their ring.
        let prolines = structure.residues.filter { $0.kind == .proline }.count
        XCTAssertGreaterThan(prolines, 0, "the fixture should contain proline")
        XCTAssertEqual(phi, 141 - prolines)
        XCTAssertEqual(psi, 141)

        let expectedChi = structure.residues.reduce(0) { $0 + $1.kind.chiCount }
        // Proline's chi1 and chi2 are both in the ring, so both are skipped.
        XCTAssertEqual(chi, expectedChi - prolines * 2)
        // Every torsion the chemistry table declares is present, which the
        // assertion above pins exactly. This one only rules out the degenerate
        // case of a structure with no side chains at all: a globin averages
        // about 1.5 rotatable side-chain torsions per residue, because it is
        // rich in alanine, glycine, leucine and valine.
        XCTAssertEqual(Double(chi) / Double(structure.residueCount), 1.5, accuracy: 0.6)
    }

    /// Proline's phi really is locked by its pyrrolidine ring. Sampling it
    /// would tear the ring apart, and a topology that did not notice would do
    /// exactly that on the first accepted move.
    func testProlineRingTorsionsAreSkippedWithAReason() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)

        let prolineIndices = Set(
            structure.residues.indices.filter { structure.residues[$0].kind == .proline })
        XCTAssertFalse(prolineIndices.isEmpty)

        let skippedProlinePhi = topology.skipped.filter {
            prolineIndices.contains($0.residueIndex) && $0.kind == .phi
        }
        XCTAssertEqual(skippedProlinePhi.count, prolineIndices.count)
        XCTAssertTrue(skippedProlinePhi.allSatisfy { $0.reason.contains("ring") })

        for index in prolineIndices {
            for torsionIndex in topology.torsionsByResidue[index] {
                XCTAssertNotEqual(topology.torsions[torsionIndex].kind, .phi)
            }
        }
    }

    /// Rotating a torsion must change THAT torsion by exactly the requested
    /// amount and leave every bond length untouched, because the whole
    /// representation rests on bond lengths being fixed.
    func testRotatingChangesOneTorsionAndNoBondLength() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)
        let bonds = BondFinder.bonds(in: structure)

        var positions = structure.positions
        let before = topology.torsions.map { TorsionTopology.value(of: $0, in: positions) }
        let lengthsBefore = bonds.map {
            simd_distance(positions[$0.a], positions[$0.b])
        }

        // A side-chain torsion in the middle of the protein.
        let target = try XCTUnwrap(
            topology.torsions.indices.first {
                if case .chi(0) = topology.torsions[$0].kind {
                    return topology.torsions[$0].residueIndex > 60
                }
                return false
            })
        TorsionTopology.rotate(&positions, torsion: topology.torsions[target], degrees: 37)

        let after = topology.torsions.map { TorsionTopology.value(of: $0, in: positions) }
        XCTAssertEqual(
            Geometry.angularDifference(from: before[target], to: after[target]), 37,
            accuracy: 1e-2)

        for index in topology.torsions.indices where index != target {
            XCTAssertEqual(
                after[index], before[index], accuracy: 1e-2,
                "torsion \(index) moved when torsion \(target) was rotated")
        }
        for (index, bond) in bonds.enumerated() {
            XCTAssertEqual(
                simd_distance(positions[bond.a], positions[bond.b]), lengthsBefore[index],
                accuracy: 1e-3, "a bond length changed")
        }
    }

    /// The smaller side rotates, which halves the average cost of a backbone
    /// move. Both choices give identical internal geometry, so this is free.
    func testTheSmallerSideIsTheOneThatMoves() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)
        for torsion in topology.torsions {
            XCTAssertLessThanOrEqual(
                torsion.movingAtoms.count, structure.atomCount / 2 + 8,
                "a torsion moves more than half the structure")
        }
    }

    /// A side-chain torsion moves only its own residue's atoms. If it moved
    /// anything else, the whole locality argument the move mix rests on would
    /// be false.
    func testSideChainTorsionsAreLocalToTheirResidue() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)

        for torsion in topology.torsions {
            guard case .chi = torsion.kind else { continue }
            let range = structure.residues[torsion.residueIndex].atomRange
            for atom in torsion.movingAtoms {
                XCTAssertTrue(
                    range.contains(Int(atom)),
                    "chi of residue \(torsion.residueIndex) moves atom \(atom), which "
                        + "is outside \(range)")
            }
            XCTAssertLessThan(torsion.movingAtoms.count, 12)
        }
    }

    /// Only phenylalanine and tyrosine chi2 are flippable, and both are marked
    /// symmetric so the analysis never counts a flip as a jump.
    func testRingFlipsAreMarkedOnPheAndTyrOnly() throws {
        let structure = try haemoglobin()
        let topology = TorsionTopology(structure: structure)

        let flippable = topology.torsions.filter(\.isFlippableRing)
        XCTAssertFalse(flippable.isEmpty)
        for torsion in flippable {
            let kind = structure.residues[torsion.residueIndex].kind
            XCTAssertTrue(kind == .phenylalanine || kind == .tyrosine)
            XCTAssertEqual(torsion.kind, .chi(1))
            XCTAssertTrue(torsion.isSymmetric, "a flippable ring must be symmetric")
        }
    }

    /// A disulfide is covalent, so a naive bond graph puts both cysteines in one
    /// ring and the cycle test then removes BOTH their chi1 torsions. Excluding
    /// S-S from the torsional tree is what keeps them sampling.
    func testDisulfidesDoNotRemoveCysteineSideChainFreedom() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure
        let topology = TorsionTopology(structure: structure)

        let cysteines = structure.residues.indices.filter {
            structure.residues[$0].kind == .cysteine
        }
        guard !cysteines.isEmpty else { throw XCTSkip("no cysteine in the fixture") }
        for index in cysteines {
            let kinds = topology.torsionsByResidue[index].map { topology.torsions[$0].kind }
            XCTAssertTrue(
                kinds.contains(.chi(0)),
                "cysteine \(index) lost its chi1")
        }
    }
}
