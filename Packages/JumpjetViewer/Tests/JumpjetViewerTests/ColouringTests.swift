import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetViewer

final class ColouringTests: XCTestCase {

    /// The bands are written as hex literals divided by 255. In integer
    /// arithmetic `0x53 / 255` is ZERO, and every band would come out black
    /// while still compiling and still rendering. Check an actual channel.
    func testConfidenceColoursAreNotAccidentallyBlack() {
        let veryHigh = ResidueColouring.confidenceColour(plddt: 95)
        XCTAssertEqual(veryHigh.x, 0x00 / 255.0, accuracy: 1e-4)
        XCTAssertEqual(veryHigh.y, 0x53 / 255.0, accuracy: 1e-4)
        XCTAssertEqual(veryHigh.z, 0xD6 / 255.0, accuracy: 1e-4)
        XCTAssertGreaterThan(veryHigh.z, 0.5)
    }

    /// The four AlphaFold bands, at their boundaries. Off-by-one on a boundary
    /// puts a confident residue in the low-confidence colour on every model.
    func testConfidenceBandBoundaries() {
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 100), "Very high")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 90), "Very high")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 89.99), "Confident")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 70), "Confident")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 69.99), "Low")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 50), "Low")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 49.99), "Very low")
        XCTAssertEqual(ResidueColouring.confidenceBand(plddt: 0), "Very low")
    }

    func testEachConfidenceBandHasItsOwnColour() {
        let colours = [95, 80, 60, 30].map {
            ResidueColouring.confidenceColour(plddt: Float($0))
        }
        for i in colours.indices {
            for j in (i + 1)..<colours.count {
                XCTAssertGreaterThan(simd_distance(colours[i], colours[j]), 0.1)
            }
        }
    }

    /// N-terminus blue, C-terminus red. Reversed, every published figure the
    /// user compares against would read backwards.
    func testChainbowRunsBlueToRed() {
        let start = ResidueColouring.chainbowColour(fraction: 0)
        let end = ResidueColouring.chainbowColour(fraction: 1)
        XCTAssertGreaterThan(start.z, start.x, "the N-terminus should be blue")
        XCTAssertGreaterThan(end.x, end.z, "the C-terminus should be red")
    }

    func testChainbowIsClampedOutsideZeroToOne() {
        XCTAssertEqual(
            ResidueColouring.chainbowColour(fraction: -5),
            ResidueColouring.chainbowColour(fraction: 0))
        XCTAssertEqual(
            ResidueColouring.chainbowColour(fraction: 5),
            ResidueColouring.chainbowColour(fraction: 1))
    }

    func testFlexibilityRunsFromPhosphorGreenToAfterburnerAmber() {
        let rigid = ResidueColouring.flexibilityColour(0)
        let floppy = ResidueColouring.flexibilityColour(1)
        XCTAssertEqual(rigid, SIMD3<Float>(0, 0xE6 / 255.0, 0x76 / 255.0))
        XCTAssertEqual(floppy, SIMD3<Float>(1, 0xB3 / 255.0, 0))
    }

    func testChainColoursAreDistinct() {
        let colours = (0..<8).map { ResidueColouring.chainColour(index: $0, of: 8) }
        for i in colours.indices {
            for j in (i + 1)..<colours.count {
                XCTAssertGreaterThan(
                    simd_distance(colours[i], colours[j]), 0.15,
                    "chains \(i) and \(j) look the same")
            }
        }
    }

    /// The chainbow must restart at each chain, not run once across the file.
    /// Measured across the file, a four-chain haemoglobin's second chain starts
    /// green, and the rainbow stops meaning "start to end of this chain".
    func testChainbowRestartsForEachChain() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure
        let colours = ResidueColouring.colours(for: structure, mode: .chainbow)

        XCTAssertEqual(colours.count, structure.residueCount)
        for chain in structure.chains {
            let first = colours[chain.residueRange.lowerBound]
            let last = colours[chain.residueRange.upperBound - 1]
            XCTAssertGreaterThan(first.z, first.x, "chain \(chain.id) should start blue")
            XCTAssertGreaterThan(last.x, last.z, "chain \(chain.id) should end red")
        }
    }

    /// A confidence scale on a crystal structure would put B-factors on a
    /// prediction's certainty axis, which is the category error the model layer
    /// already refuses to make.
    func testConfidenceIsOfferedOnlyForPredictions() throws {
        let prediction = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"), source: .alphaFold).structure
        let experimental = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe).structure

        XCTAssertTrue(ColourMode.confidence.isAvailable(for: prediction))
        XCTAssertFalse(ColourMode.confidence.isAvailable(for: experimental))
        XCTAssertTrue(ColourMode.chainbow.isAvailable(for: experimental))
    }

    func testConfidenceColoursOnARealModelSpanMoreThanOneBand() throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"), source: .alphaFold).structure
        let bands = Set(structure.perResiduePLDDT.map(ResidueColouring.confidenceBand))
        XCTAssertGreaterThan(bands.count, 1, "the fixture should exercise more than one band")
        XCTAssertTrue(bands.contains("Very high"))
    }
}
