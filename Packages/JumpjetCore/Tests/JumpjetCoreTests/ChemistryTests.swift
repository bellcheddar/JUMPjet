import XCTest

@testable import JumpjetCore

final class ChemistryTests: XCTestCase {

    func testElementResolutionIsCaseAndPaddingTolerant() {
        XCTAssertEqual(Element.named(" c "), .carbon)
        XCTAssertEqual(Element.named("se"), .selenium)
        XCTAssertEqual(Element.named("ZN"), .zinc)
        XCTAssertEqual(Element.named(""), .unknown)
        XCTAssertEqual(Element.named("Xx"), .unknown)
    }

    /// "CA" in an atom name is an alpha carbon, not calcium. Guessing from the
    /// name alone must not turn every residue's backbone into a metal ion.
    func testElementGuessedFromAtomNameDoesNotConfuseAlphaCarbonWithCalcium() {
        XCTAssertEqual(Element.guessed(fromAtomName: "CA"), .carbon)
        XCTAssertEqual(Element.guessed(fromAtomName: "CB"), .carbon)
        XCTAssertEqual(Element.guessed(fromAtomName: "OG1"), .oxygen)
        XCTAssertEqual(Element.guessed(fromAtomName: "SD"), .sulphur)
        XCTAssertEqual(Element.guessed(fromAtomName: "NZ"), .nitrogen)
        XCTAssertEqual(Element.guessed(fromAtomName: "1HB"), .hydrogen)
        XCTAssertEqual(Element.guessed(fromAtomName: "SE"), .selenium)
    }

    func testSelenomethionineSamplesAsMethionine() {
        XCTAssertEqual(AminoAcid.named("MSE"), .methionine)
        XCTAssertEqual(AminoAcid.named("mse"), .methionine)
        XCTAssertEqual(AminoAcid.named("HIE"), .histidine)
        XCTAssertEqual(AminoAcid.named("HOH"), .other)
    }

    func testOneLetterCodesAreUniqueAcrossTheTwentyStandardResidues() {
        let standard = AminoAcid.allCases.filter(\.isStandard)
        XCTAssertEqual(standard.count, 20)
        XCTAssertEqual(Set(standard.map(\.oneLetterCode)).count, 20)
    }

    /// Every chi definition must name four atoms, and each successive chi must
    /// overlap the previous one by three, because they walk the same chain of
    /// bonds outwards. A typo in the table shows up here rather than as a
    /// nonsense torsion three phases later.
    func testChiDefinitionsAreWellFormedAndOverlapping() {
        for residue in AminoAcid.allCases {
            let definitions = residue.chiDefinitions
            for definition in definitions {
                XCTAssertEqual(definition.count, 4, "\(residue.rawValue) chi is not four atoms")
                XCTAssertEqual(
                    Set(definition).count, 4, "\(residue.rawValue) chi repeats an atom")
            }
            for index in definitions.indices.dropFirst() {
                XCTAssertEqual(
                    Array(definitions[index - 1].dropFirst()),
                    Array(definitions[index].dropLast()),
                    "\(residue.rawValue) chi\(index + 1) does not follow chi\(index)")
            }
        }
    }

    func testChiCounts() {
        XCTAssertEqual(AminoAcid.glycine.chiCount, 0)
        XCTAssertEqual(AminoAcid.alanine.chiCount, 0)
        XCTAssertEqual(AminoAcid.serine.chiCount, 1)
        XCTAssertEqual(AminoAcid.phenylalanine.chiCount, 2)
        XCTAssertEqual(AminoAcid.methionine.chiCount, 3)
        XCTAssertEqual(AminoAcid.lysine.chiCount, 4)
        XCTAssertEqual(AminoAcid.arginine.chiCount, 4)
    }

    /// Only phenylalanine and tyrosine have a twofold symmetric ring. Histidine
    /// and tryptophan look aromatic but their rings are not symmetric, so
    /// treating them as flippable would erase real conformational changes.
    func testOnlyPheAndTyrRingsFlip() {
        let flippable = AminoAcid.allCases.filter(\.hasFlippableRing)
        XCTAssertEqual(Set(flippable), [.phenylalanine, .tyrosine])
        XCTAssertFalse(AminoAcid.histidine.hasFlippableRing)
        XCTAssertFalse(AminoAcid.tryptophan.hasFlippableRing)
    }

    /// A symmetric chi index must actually exist on that residue.
    func testSymmetricChiIndicesAreInRange() {
        for residue in AminoAcid.allCases {
            for index in residue.symmetricChiIndices {
                XCTAssertTrue(
                    (0..<residue.chiCount).contains(index),
                    "\(residue.rawValue) marks chi\(index + 1) symmetric but has only "
                        + "\(residue.chiCount) torsions")
            }
        }
    }

    func testMetalIonsAreFlagged() {
        XCTAssertTrue(Element.zinc.isMetalIon)
        XCTAssertTrue(Element.magnesium.isMetalIon)
        XCTAssertFalse(Element.carbon.isMetalIon)
        XCTAssertFalse(Element.chlorine.isMetalIon)
    }
}
