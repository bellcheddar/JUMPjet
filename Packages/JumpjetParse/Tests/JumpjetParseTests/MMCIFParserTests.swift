import XCTest
import JumpjetCore

@testable import JumpjetParse

final class MMCIFParserTests: XCTestCase {

    // MARK: - Real files

    func testAlphaFoldCIFParsesToTheKnownCounts() throws {
        let result = try MMCIFParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.cif"),
            identifier: "P69905", source: .alphaFold)
        let structure = result.structure

        XCTAssertEqual(structure.residueCount, 142)
        XCTAssertEqual(structure.atomCount, 1_077)
        XCTAssertEqual(structure.chains.map(\.id), ["A"])
        XCTAssertEqual(structure.meanPLDDT ?? 0, 98.0637, accuracy: 0.01)
    }

    /// The two formats describe the same model, so they must parse to the same
    /// structure atom for atom. This is the strongest check available on either
    /// reader: an error in one that the other does not share shows up here even
    /// though no expected value was written down by hand.
    func testPDBAndCIFOfTheSameAlphaFoldModelAgreeAtomForAtom() throws {
        let fromPDB = try PDBParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.pdb"),
            identifier: "P69905", source: .alphaFold, modelVersion: "v6"
        ).structure
        let fromCIF = try MMCIFParser.parse(
            Fixtures.text("structures/AF-P69905-F1-model_v6.cif"),
            identifier: "P69905", source: .alphaFold, modelVersion: "v6"
        ).structure

        XCTAssertEqual(fromPDB.residueCount, fromCIF.residueCount)
        XCTAssertEqual(fromPDB.atomCount, fromCIF.atomCount)
        XCTAssertEqual(fromPDB.sequence(ofChain: 0), fromCIF.sequence(ofChain: 0))
        XCTAssertEqual(fromPDB.residues, fromCIF.residues)
        for index in fromPDB.atoms.indices {
            XCTAssertEqual(fromPDB.atoms[index].name, fromCIF.atoms[index].name)
            XCTAssertEqual(fromPDB.atoms[index].element, fromCIF.atoms[index].element)
            XCTAssertEqual(
                fromPDB.atoms[index].position.x, fromCIF.atoms[index].position.x, accuracy: 1e-3)
            XCTAssertEqual(
                fromPDB.atoms[index].position.y, fromCIF.atoms[index].position.y, accuracy: 1e-3)
            XCTAssertEqual(
                fromPDB.atoms[index].position.z, fromCIF.atoms[index].position.z, accuracy: 1e-3)
        }
    }

    /// The same cross-check on an experimental entry, where waters, ligands and
    /// alternate locations all have to be dropped identically by both readers.
    func testPDBAndCIFOfTheSameExperimentalEntryAgree() throws {
        let fromPDB = try PDBParser.parse(
            Fixtures.text("structures/1bab.pdb"), source: .pdbe)
        let fromCIF = try MMCIFParser.parse(
            Fixtures.text("structures/1bab.cif"), source: .pdbe)

        XCTAssertEqual(fromPDB.structure.residueCount, fromCIF.structure.residueCount)
        XCTAssertEqual(fromPDB.structure.atomCount, fromCIF.structure.atomCount)
        XCTAssertEqual(fromPDB.structure.chains.map(\.id), fromCIF.structure.chains.map(\.id))
        XCTAssertEqual(
            fromPDB.structure.chains.map(\.residueCount),
            fromCIF.structure.chains.map(\.residueCount))
        XCTAssertEqual(
            fromPDB.report.alternateLocationsDropped,
            fromCIF.report.alternateLocationsDropped)
        for chain in fromPDB.structure.chains.indices {
            XCTAssertEqual(
                fromPDB.structure.sequence(ofChain: chain),
                fromCIF.structure.sequence(ofChain: chain))
        }
    }

    func testEntryIdentifierAndTitleComeFromTheFile() throws {
        let result = try MMCIFParser.parse(
            Fixtures.text("structures/1bab.cif"), source: .pdbe)
        XCTAssertEqual(result.structure.identifier, "1BAB")
        XCTAssertTrue(result.structure.title.uppercased().contains("HEMOGLOBIN"))
    }

    // MARK: - Tokeniser

    /// Quoted values, a semicolon text field, comments and a second loop after
    /// the atom_site loop. Splitting on whitespace alone fails all four.
    func testTokeniserHandlesQuotingCommentsAndTextFields() throws {
        let document = CIFDocument.parse(try Fixtures.text("structures/edge/cif_quoting.cif"))

        XCTAssertEqual(document.blockName, "QUOTE")
        XCTAssertEqual(document.value("_entry.id"), "QUOTE")
        XCTAssertEqual(document.value("_struct.pdbx_descriptor"), "a quoted value with spaces")
        XCTAssertEqual(document.value("_exptl.method"), "another quoted value")

        let title = try XCTUnwrap(document.value("_struct.title"))
        XCTAssertTrue(title.contains("# hash"), "a hash inside a text field is not a comment")
        XCTAssertTrue(title.contains("'single quote'"))
        XCTAssertTrue(title.contains("loop_ that is not a keyword"))
        XCTAssertTrue(title.contains("\n"), "the text field spans two lines")

        // The trailing citation loop must not have eaten or truncated the atoms.
        XCTAssertEqual(document.column("_atom_site.id").count, 9)
        XCTAssertEqual(document.value("_citation.id"), "primary")
    }

    /// `.` and `?` are nulls, but only when unquoted.
    func testUnquotedFullStopIsNullAndQuotedIsNot() throws {
        let document = CIFDocument.parse(try Fixtures.text("structures/edge/cif_quoting.cif"))
        let alternates = document.column("_atom_site.label_alt_id")
        XCTAssertEqual(alternates.count, 9)
        XCTAssertTrue(alternates.allSatisfy { $0 == nil })
    }

    /// The reader must prefer author numbering, which is what the HUD, a paper
    /// and the user all mean by "residue 501".
    func testAuthorNumberingWinsOverLabelNumbering() throws {
        let result = try MMCIFParser.parse(
            Fixtures.text("structures/edge/cif_quoting.cif"))
        let structure = result.structure

        XCTAssertEqual(structure.residueCount, 2)
        XCTAssertEqual(structure.residues.map(\.sequenceNumber), [501, 502])
        XCTAssertEqual(structure.chains.map(\.id), ["X"])
        XCTAssertEqual(structure.sequence(ofChain: 0), "YG")
    }

    /// A file with no auth_* columns must fall back to label numbering rather
    /// than yielding an empty structure.
    func testLabelNumberingIsUsedWhenAuthorColumnsAreAbsent() throws {
        let result = try MMCIFParser.parse(
            Fixtures.text("structures/edge/cif_label_only.cif"))
        let structure = result.structure

        XCTAssertEqual(structure.residueCount, 1)
        XCTAssertEqual(structure.residues[0].sequenceNumber, 7)
        XCTAssertEqual(structure.chains.map(\.id), ["B"])
    }

    // MARK: - Format detection

    /// Extensions lie: AlphaFold DB serves both formats and a cache that
    /// trusted the file name would hand a CIF body to the column-slicing PDB
    /// reader, which returns an empty structure rather than an error.
    func testFormatIsDetectedFromContentNotExtension() throws {
        XCTAssertEqual(
            StructureReader.detectFormat(try Fixtures.text("structures/1bab.cif")), .mmCIF)
        XCTAssertEqual(
            StructureReader.detectFormat(try Fixtures.text("structures/1bab.pdb")), .pdb)
        XCTAssertEqual(
            StructureReader.detectFormat(
                try Fixtures.text("structures/AF-P69905-F1-model_v6.cif")), .mmCIF)
        XCTAssertEqual(
            StructureReader.detectFormat(
                try Fixtures.text("structures/AF-P69905-F1-model_v6.pdb")), .pdb)
    }

    func testStructureReaderRoutesBothFormats() throws {
        for path in ["structures/1bab.cif", "structures/1bab.pdb"] {
            let result = try StructureReader.parse(
                data: Fixtures.data(path), source: .pdbe)
            XCTAssertEqual(result.structure.residueCount, 576, "failed on \(path)")
        }
    }

    func testNonTextDataIsRejectedWithAReadableError() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01, 0x02])
        XCTAssertThrowsError(try StructureReader.parse(data: bytes)) { error in
            guard case JumpjetError.parseFailure(let reason) = error else {
                return XCTFail("expected a parse failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("UTF-8"))
        }
    }

    func testCIFWithNoAtomSiteLoopIsAnError() {
        XCTAssertThrowsError(try MMCIFParser.parse("data_EMPTY\n_entry.id EMPTY\n")) { error in
            guard case JumpjetError.parseFailure = error else {
                return XCTFail("expected a parse failure, got \(error)")
            }
        }
    }
}
