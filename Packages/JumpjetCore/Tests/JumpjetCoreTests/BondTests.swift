import XCTest
import simd

@testable import JumpjetCore

final class BondTests: XCTestCase {

    /// A two-residue alanine peptide with real bond lengths, plus whatever the
    /// caller wants appended.
    private func peptide(gapBetweenResidues: Float = 1.33) -> Structure {
        var atoms: [Atom] = []
        func add(_ name: String, _ element: Element, _ position: SIMD3<Float>, _ residue: Int) {
            atoms.append(
                Atom(name: name, element: element, position: position, residueIndex: residue))
        }
        // Residue 0: N-CA-C-O with 1.46, 1.52 and 1.23 angstrom bonds.
        add("N", .nitrogen, SIMD3(0, 0, 0), 0)
        add("CA", .carbon, SIMD3(1.46, 0, 0), 0)
        add("C", .carbon, SIMD3(2.98, 0, 0), 0)
        add("O", .oxygen, SIMD3(3.60, 1.06, 0), 0)
        add("CB", .carbon, SIMD3(1.96, 1.44, 0), 0)
        // Residue 1: its N sits `gapBetweenResidues` from the previous C.
        let start = 2.98 + gapBetweenResidues
        add("N", .nitrogen, SIMD3(start, 0, 0), 1)
        add("CA", .carbon, SIMD3(start + 1.46, 0, 0), 1)
        add("C", .carbon, SIMD3(start + 2.98, 0, 0), 1)
        add("O", .oxygen, SIMD3(start + 3.60, 1.06, 0), 1)
        add("CB", .carbon, SIMD3(start + 1.96, 1.44, 0), 1)

        let residues = [
            Residue(
                kind: .alanine, rawName: "ALA", sequenceNumber: 1, chainIndex: 0,
                atomRange: 0..<5),
            Residue(
                kind: .alanine, rawName: "ALA", sequenceNumber: 2, chainIndex: 0,
                atomRange: 5..<10),
        ]
        return Structure(
            identifier: "PEP", title: "Dipeptide", source: .local, atoms: atoms,
            residues: residues, chains: [Chain(id: "A", residueRange: 0..<2)])
    }

    func testBondIsOrderIndependent() {
        XCTAssertEqual(Bond(3, 7), Bond(7, 3))
        XCTAssertEqual(Set([Bond(3, 7), Bond(7, 3)]).count, 1)
        XCTAssertEqual(Bond(7, 3).a, 3)
    }

    func testBackboneAndSideChainBondsAreFound() {
        let bonds = Set(BondFinder.bonds(in: peptide()))
        // Within residue 0: N-CA, CA-C, C-O, CA-CB.
        XCTAssertTrue(bonds.contains(Bond(0, 1)))
        XCTAssertTrue(bonds.contains(Bond(1, 2)))
        XCTAssertTrue(bonds.contains(Bond(2, 3)))
        XCTAssertTrue(bonds.contains(Bond(1, 4)))
        // Not bonded: N to C across the residue, 2.98 angstroms apart.
        XCTAssertFalse(bonds.contains(Bond(0, 2)))
    }

    /// The peptide bond joins C of one residue to N of the next.
    func testThePeptideBondIsFound() {
        let bonds = Set(BondFinder.bonds(in: peptide()))
        XCTAssertTrue(bonds.contains(Bond(2, 5)), "C(i) to N(i+1) should be bonded")
    }

    /// A chain break leaves a gap of many angstroms. Joining across it draws a
    /// stick through empty space that reads as a real bond.
    func testAChainBreakIsNotBondedAcross() {
        let bonds = Set(BondFinder.bonds(in: peptide(gapBetweenResidues: 8)))
        XCTAssertFalse(bonds.contains(Bond(2, 5)), "a chain break must not be bridged")
        // The rest of the chemistry is unaffected.
        XCTAssertTrue(bonds.contains(Bond(0, 1)))
        XCTAssertTrue(bonds.contains(Bond(6, 7)))
    }

    func testSideChainBondsExcludeThePureBackbone() {
        let sideChain = Set(BondFinder.sideChainBonds(in: peptide()))
        XCTAssertTrue(sideChain.contains(Bond(1, 4)), "CA-CB is a side-chain bond")
        XCTAssertFalse(sideChain.contains(Bond(0, 1)), "N-CA is pure backbone")
        XCTAssertFalse(sideChain.contains(Bond(2, 5)), "the peptide bond is pure backbone")
    }

    /// Two ions in the same site sit close enough for a radius test to join
    /// them. They are not covalently bonded and a stick between them is a
    /// chemical claim the structure does not make.
    func testMetalIonsAreNeverBonded() {
        let atoms = [
            Atom(name: "ZN", element: .zinc, position: SIMD3(0, 0, 0), residueIndex: 0),
            Atom(name: "ZN", element: .zinc, position: SIMD3(2.5, 0, 0), residueIndex: 0),
            Atom(name: "SG", element: .sulphur, position: SIMD3(1.2, 1.6, 0), residueIndex: 0),
        ]
        let structure = Structure(
            identifier: "ION", title: "Site", source: .local, atoms: atoms,
            residues: [
                Residue(
                    kind: .cysteine, rawName: "CYS", sequenceNumber: 1, chainIndex: 0,
                    atomRange: 0..<3)
            ],
            chains: [Chain(id: "A", residueRange: 0..<1)])

        let bonds = Set(BondFinder.bonds(in: structure))
        XCTAssertFalse(bonds.contains(Bond(0, 1)), "two ions must not be bonded")
        XCTAssertFalse(bonds.contains(Bond(0, 2)), "a metal coordination is not a covalent bond")
    }

    /// Two atoms sitting on top of each other is what an unfiltered alternate
    /// location looks like geometrically. Bonding them puts a degenerate
    /// zero-length stick in the mesh.
    func testCoincidentAtomsAreNotBonded() {
        let atoms = [
            Atom(name: "CA", element: .carbon, position: SIMD3(0, 0, 0), residueIndex: 0),
            Atom(name: "CB", element: .carbon, position: SIMD3(0.01, 0, 0), residueIndex: 0),
        ]
        let structure = Structure(
            identifier: "DUP", title: "Duplicate", source: .local, atoms: atoms,
            residues: [
                Residue(
                    kind: .alanine, rawName: "ALA", sequenceNumber: 1, chainIndex: 0,
                    atomRange: 0..<2)
            ],
            chains: [Chain(id: "A", residueRange: 0..<1)])
        XCTAssertTrue(BondFinder.bonds(in: structure).isEmpty)
    }

    /// The long C-S bonds of methionine (1.80 angstroms) must be admitted, and
    /// a 3 angstrom van der Waals contact must not be.
    func testToleranceAdmitsSulphurAndRejectsContacts() {
        func separated(by distance: Float, _ first: Element, _ second: Element) -> Bool {
            let atoms = [
                Atom(name: "A", element: first, position: SIMD3(0, 0, 0), residueIndex: 0),
                Atom(name: "B", element: second, position: SIMD3(distance, 0, 0), residueIndex: 0),
            ]
            let structure = Structure(
                identifier: "X", title: "", source: .local, atoms: atoms,
                residues: [
                    Residue(
                        kind: .methionine, rawName: "MET", sequenceNumber: 1, chainIndex: 0,
                        atomRange: 0..<2)
                ],
                chains: [Chain(id: "A", residueRange: 0..<1)])
            return BondFinder.isBonded(structure, 0, 1)
        }

        XCTAssertTrue(separated(by: 1.80, .carbon, .sulphur), "a C-S bond must be found")
        XCTAssertTrue(separated(by: 1.52, .carbon, .carbon))
        XCTAssertFalse(separated(by: 3.0, .carbon, .carbon), "a contact is not a bond")
        XCTAssertFalse(separated(by: 2.8, .carbon, .oxygen), "a hydrogen bond is not covalent")
    }
}
