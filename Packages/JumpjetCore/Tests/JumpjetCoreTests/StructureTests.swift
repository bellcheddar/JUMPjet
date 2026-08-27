import XCTest
import simd

@testable import JumpjetCore

final class StructureTests: XCTestCase {

    /// A three-residue, two-chain toy structure built by hand so every index
    /// relationship in it is known.
    private func makeStructure() -> Structure {
        var atoms: [Atom] = []
        func backbone(residueIndex: Int, at origin: SIMD3<Float>, plddt: Float) {
            for (offset, name) in [("N"), ("CA"), ("C"), ("O")].enumerated() {
                atoms.append(
                    Atom(
                        name: name,
                        element: name == "O" ? .oxygen : (name == "N" ? .nitrogen : .carbon),
                        position: origin + SIMD3(Float(offset), 0, 0),
                        temperatureFactor: plddt,
                        residueIndex: residueIndex))
            }
        }
        backbone(residueIndex: 0, at: SIMD3(0, 0, 0), plddt: 90)
        backbone(residueIndex: 1, at: SIMD3(4, 0, 0), plddt: 70)
        backbone(residueIndex: 2, at: SIMD3(8, 0, 0), plddt: 50)

        let residues = [
            Residue(
                kind: .alanine, rawName: "ALA", sequenceNumber: 10, chainIndex: 0,
                atomRange: 0..<4),
            Residue(
                kind: .glycine, rawName: "GLY", sequenceNumber: 11, chainIndex: 0,
                atomRange: 4..<8),
            Residue(
                kind: .serine, rawName: "SER", sequenceNumber: 1, insertionCode: "A",
                chainIndex: 1, atomRange: 8..<12),
        ]
        let chains = [Chain(id: "A", residueRange: 0..<2), Chain(id: "B", residueRange: 2..<3)]

        return Structure(
            identifier: "TEST", title: "Toy", source: .alphaFold, modelVersion: "v4",
            atoms: atoms, residues: residues, chains: chains)
    }

    func testCountsAndLongestChain() {
        let structure = makeStructure()
        XCTAssertEqual(structure.atomCount, 12)
        XCTAssertEqual(structure.residueCount, 3)
        XCTAssertEqual(structure.longestChainIndex, 0)
    }

    func testAtomLookupIsScopedToItsResidue() {
        let structure = makeStructure()
        XCTAssertEqual(structure.alphaCarbonIndex(ofResidue: 0), 1)
        XCTAssertEqual(structure.alphaCarbonIndex(ofResidue: 1), 5)
        XCTAssertEqual(structure.alphaCarbonIndex(ofResidue: 2), 9)
        XCTAssertNil(structure.atomIndex(named: "CB", inResidue: 0))
        XCTAssertNil(structure.alphaCarbonIndex(ofResidue: 99))
    }

    func testSequencePerChain() {
        let structure = makeStructure()
        XCTAssertEqual(structure.sequence(ofChain: 0), "AG")
        XCTAssertEqual(structure.sequence(ofChain: 1), "S")
        XCTAssertEqual(structure.sequence(ofChain: 9), "")
    }

    func testResidueLabelIncludesInsertionCode() {
        let structure = makeStructure()
        XCTAssertEqual(structure.residues[0].label(chainID: "A"), "A:ALA 10")
        XCTAssertEqual(structure.residues[2].label(chainID: "B"), "B:SER 1A")
    }

    /// pLDDT is per residue, so the mean must average residues and not atoms.
    /// Averaging atoms would silently weight big residues more heavily.
    func testMeanPLDDTAveragesResiduesNotAtoms() {
        let structure = makeStructure()
        XCTAssertEqual(structure.meanPLDDT ?? 0, 70, accuracy: 1e-4)
        XCTAssertEqual(structure.perResiduePLDDT, [90, 70, 50])
    }

    /// An experimental entry's B-factors are not confidence scores, so the
    /// structure must decline to report a mean pLDDT for one.
    func testExperimentalStructuresReportNoPLDDT() {
        let source = makeStructure()
        let experimental = Structure(
            identifier: "1ABC", title: "Real", source: .pdbe,
            atoms: source.atoms, residues: source.residues, chains: source.chains)
        XCTAssertNil(experimental.meanPLDDT)
    }

    func testSetPositionsReplacesEveryCoordinate() {
        var structure = makeStructure()
        let shifted = structure.positions.map { $0 + SIMD3<Float>(0, 5, 0) }
        structure.setPositions(shifted)
        XCTAssertEqual(structure.atoms[0].position, SIMD3<Float>(0, 5, 0))
        XCTAssertEqual(structure.centroid.y, 5, accuracy: 1e-5)
    }

    func testCodableRoundTrip() throws {
        let structure = makeStructure()
        let data = try JSONEncoder().encode(structure)
        let restored = try JSONDecoder().decode(Structure.self, from: data)
        XCTAssertEqual(restored, structure)
    }

    func testBoundingRadiusCoversEveryAtom() {
        let structure = makeStructure()
        let centre = structure.centroid
        let radius = structure.boundingRadius
        for atom in structure.atoms {
            XCTAssertLessThanOrEqual(simd_distance(atom.position, centre), radius + 1e-4)
        }
    }
}
