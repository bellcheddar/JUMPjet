import XCTest
import JumpjetCore

@testable import JumpjetParse

final class PDBParserTests: XCTestCase {

    // MARK: - Real AlphaFold model

    /// Counts checked against an independent census of the same file, not
    /// against what the parser happened to produce.
    func testAlphaFoldPDBParsesToTheKnownCounts() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold, modelVersion: "v6")
        let structure = result.structure

        XCTAssertEqual(structure.residueCount, 142)
        XCTAssertEqual(structure.atomCount, 1_077)
        XCTAssertEqual(structure.chains.count, 1)
        XCTAssertEqual(structure.chains[0].id, "A")
        XCTAssertEqual(structure.source, .alphaFold)
        XCTAssertEqual(structure.modelVersion, "v6")
    }

    /// The parsed sequence must equal UniProt's own sequence for P69905. This
    /// catches residue ordering, residue dropping and one-letter mapping in a
    /// single assertion against an external ground truth.
    func testAlphaFoldSequenceMatchesUniProt() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"), source: .alphaFold)
        XCTAssertEqual(
            result.structure.sequence(ofChain: 0),
            "MVLSPADKTNVKAAWGKVGAHAGEYGAEALERMFLSFPTTKTYFPHFDLSHGSAQVKGHGKKVADALTNAVAHVDDMPNAL"
                + "SALSDLHAHKLRVDPVNFKLLSHCLLVTLAAHLPAEFTPAVHASLDKFLASVSTVLTSKYR")
    }

    /// pLDDT arrives in the B-factor column and must survive to the model, in
    /// range and per residue. Phase 2's flexibility prior is built from it.
    func testAlphaFoldPLDDTSurvivesParsing() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"), source: .alphaFold)
        let structure = result.structure

        XCTAssertEqual(structure.meanPLDDT ?? 0, 98.0637, accuracy: 0.01)
        let perResidue = structure.perResiduePLDDT
        XCTAssertEqual(perResidue.count, 142)
        XCTAssertEqual(perResidue.min() ?? 0, 65.38, accuracy: 0.01)
        XCTAssertEqual(perResidue.max() ?? 0, 98.88, accuracy: 0.01)
    }

    // MARK: - Real experimental entry

    /// 1BAB is a haemoglobin tetramer with waters, haems, sulphates, an acetyl
    /// cap and four alternate locations. Every dropping policy fires at once.
    func testExperimentalPDBAppliesEveryDroppingPolicy() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe)
        let structure = result.structure

        XCTAssertEqual(structure.residueCount, 576)
        XCTAssertEqual(structure.atomCount, 4_404)
        XCTAssertEqual(structure.chains.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(structure.chains.map(\.residueCount), [142, 146, 142, 146])
        XCTAssertEqual(result.report.alternateLocationsDropped, 4)
        XCTAssertGreaterThan(result.report.watersDropped, 0)
        XCTAssertGreaterThan(result.report.nonPolymerResiduesDropped, 0)
        XCTAssertFalse(result.report.summary.isEmpty)
    }

    /// An experimental entry's B-factors are real B-factors. Reporting them as
    /// confidence would put a 1.5 angstrom crystal structure's disorder on the
    /// same axis as a prediction's certainty.
    func testExperimentalEntryReportsNoPLDDT() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe)
        XCTAssertNil(result.structure.meanPLDDT)
    }

    /// The title is assembled from the wrapped TITLE records rather than only
    /// the first one.
    func testTitleIsJoinedAcrossContinuationRecords() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe)
        XCTAssertTrue(result.structure.title.uppercased().contains("HEMOGLOBIN THIONVILLE"))
        XCTAssertTrue(result.structure.title.count > 40)
    }

    // MARK: - Edge cases

    /// The minor conformer appears FIRST in the file with the lower occupancy.
    /// A reader that keeps whichever it saw first, or whichever it saw last,
    /// puts the side chain in the wrong place without any error.
    func testHighestOccupancyAlternateLocationWins() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/edge/altloc_occupancy.pdb"))
        let structure = result.structure

        XCTAssertEqual(structure.residueCount, 1)
        XCTAssertEqual(result.report.alternateLocationsDropped, 1)
        let cb = try XCTUnwrap(structure.atomIndex(named: "CB", inResidue: 0))
        XCTAssertEqual(structure.atoms[cb].position.x, 5.555, accuracy: 1e-4)
        XCTAssertEqual(structure.atoms[cb].occupancy, 0.70, accuracy: 1e-4)
    }

    /// Truncated files carry no element column. The atom name's column
    /// alignment then decides, which is the only thing that separates an alpha
    /// carbon from a calcium ion.
    func testElementIsRecoveredFromColumnAlignmentWhenTheColumnIsMissing() throws {
        let text = try Fixtures.text("structures/edge/no_element_column.pdb")
        for line in text.split(separator: "\n") where line.hasPrefix("ATOM") {
            XCTAssertLessThanOrEqual(line.count, 66, "fixture is meant to be truncated")
        }

        let result = try PDBParser.parse(text)
        let structure = result.structure
        XCTAssertEqual(structure.residueCount, 1)
        let alphaCarbon = try XCTUnwrap(structure.alphaCarbonIndex(ofResidue: 0))
        XCTAssertEqual(structure.atoms[alphaCarbon].element, .carbon)
        XCTAssertEqual(structure.atoms[alphaCarbon].name, "CA")
        // The calcium HETATM is dropped as non-polymer, but the census must
        // still show it was seen rather than silently vanishing.
        XCTAssertEqual(result.report.nonPolymerResiduesDropped, 1)
    }

    /// An ensemble is many structures in one file. Sampling must start from
    /// exactly one of them.
    func testOnlyTheFirstModelSurvives() throws {
        let result = try PDBParser.parse(Fixtures.text("structures/edge/two_models.pdb"))
        XCTAssertEqual(result.report.modelsSeen, 2)
        XCTAssertEqual(result.report.extraModelsDropped, 4)
        XCTAssertEqual(result.structure.residueCount, 1)
        XCTAssertEqual(result.structure.atomCount, 4)
        // Model 2 was translated by 50 angstroms, so the coordinate says which
        // model survived far more clearly than the count does.
        XCTAssertEqual(result.structure.atoms[0].position.x, 1, accuracy: 1e-4)
    }

    func testWatersLigandsAndIonsAreCountedAsTheyAreDropped() throws {
        let result = try PDBParser.parse(
            Fixtures.text("structures/edge/polymer_with_heteroatoms.pdb"))
        XCTAssertEqual(result.structure.residueCount, 2)
        XCTAssertEqual(result.structure.atomCount, 10)
        XCTAssertEqual(result.report.watersDropped, 3)
        XCTAssertEqual(result.report.nonPolymerResiduesDropped, 2)
    }

    // MARK: - Failure modes

    func testEmptyTextIsAnError() {
        XCTAssertThrowsError(try PDBParser.parse("")) { error in
            guard case JumpjetError.parseFailure = error else {
                return XCTFail("expected a parse failure, got \(error)")
            }
        }
    }

    func testAFileOfOnlyWatersIsAnEmptyStructure() {
        let text = try? Fixtures.text("structures/edge/polymer_with_heteroatoms.pdb")
        let watersOnly = (text ?? "")
            .split(separator: "\n")
            .filter { !$0.hasPrefix("ATOM") }
            .joined(separator: "\n")
        XCTAssertThrowsError(try PDBParser.parse(watersOnly)) { error in
            XCTAssertEqual(error as? JumpjetError, .emptyStructure)
        }
    }

    func testResidueLimitIsEnforced() {
        XCTAssertThrowsError(
            try PDBParser.parse(
                Fixtures.text("structures/1bab.pdb"), source: .pdbe, residueLimit: 100)
        ) { error in
            XCTAssertEqual(error as? JumpjetError, .tooLarge(residues: 146, limit: 100))
        }
    }
}
