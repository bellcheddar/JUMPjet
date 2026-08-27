import XCTest
import JumpjetCore

@testable import JumpjetFetch

final class ClientTests: XCTestCase {

    func testUniProtEntryIsDecodedFromARecordedResponse() async throws {
        let client = UniProtClient(transport: Recorded.complete())
        let entry = try await client.entry(for: try Accession("P69905"))

        XCTAssertEqual(entry.accession, "P69905")
        XCTAssertEqual(entry.entryName, "HBA_HUMAN")
        XCTAssertEqual(entry.proteinName, "Hemoglobin subunit alpha")
        XCTAssertEqual(entry.organism, "Homo sapiens")
        XCTAssertEqual(entry.length, 142)
        XCTAssertTrue(entry.sequence.hasPrefix("MVLSPADKTNVKAAWGKVGAHAGEYGAEALERMFLSFPTT"))
    }

    /// The request must ask for a field list. Fetching the whole entry pulls
    /// roughly 270 kB for a 142-residue protein, almost all cross-references,
    /// on a phone that is about to download a structure as well.
    func testUniProtRequestAsksForOnlyTheFieldsItUses() async throws {
        let transport = Recorded.complete()
        _ = try await UniProtClient(transport: transport).entry(for: try Accession("P69905"))

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first { $0.contains("uniprot") })
        XCTAssertTrue(request.contains("fields="))
        XCTAssertTrue(request.contains("sequence"))
        XCTAssertFalse(request.contains("xref"))
    }

    func testUnknownAccessionIsDistinguishedFromAServerFailure() async {
        let transport = Recorded.complete().replacing(Recorded.uniProt, with: .status(404))
        do {
            _ = try await UniProtClient(transport: transport).entry(for: try Accession("P69905"))
            XCTFail("expected an unknownAccession error")
        } catch {
            XCTAssertEqual(error as? JumpjetError, .unknownAccession("P69905"))
        }

        let broken = Recorded.complete().replacing(Recorded.uniProt, with: .status(503))
        do {
            _ = try await UniProtClient(transport: broken).entry(for: try Accession("P69905"))
            XCTFail("expected a serverError")
        } catch {
            XCTAssertEqual(error as? JumpjetError, .serverError(status: 503, endpoint: "UniProt"))
        }
    }

    /// The version is READ from the response, never assumed. The build plan was
    /// written when v4 was current; the fixture recorded in August 2026 is v6.
    func testAlphaFoldVersionComesFromTheResponse() async throws {
        let client = AlphaFoldClient(transport: Recorded.complete())
        let prediction = try await client.prediction(for: try Accession("P69905"))
        let unwrapped = try XCTUnwrap(prediction)

        XCTAssertEqual(unwrapped.entryID, "AF-P69905-F1")
        XCTAssertEqual(unwrapped.version, "v6")
        XCTAssertTrue(unwrapped.cifURL.absoluteString.hasSuffix("AF-P69905-F1-model_v6.cif"))
        XCTAssertEqual(unwrapped.description, "Hemoglobin subunit alpha")
    }

    /// No model is a normal outcome to fall back from, not an error to show.
    func testAlphaFoldMissIsNilRatherThanAnError() async throws {
        let transport = Recorded.complete().replacing(Recorded.alphaFoldAPI, with: .status(404))
        let prediction = try await AlphaFoldClient(transport: transport)
            .prediction(for: try Accession("P69905"))
        XCTAssertNil(prediction)
    }

    func testAlphaFoldEmptyArrayIsAlsoAMiss() async throws {
        let transport = Recorded.complete().replacing(Recorded.alphaFoldAPI, with: .body("[]"))
        let prediction = try await AlphaFoldClient(transport: transport)
            .prediction(for: try Accession("P69905"))
        XCTAssertNil(prediction)
    }

    func testPDBeBestStructureIsDecoded() async throws {
        let client = PDBeClient(transport: Recorded.complete())
        let fetched = try await client.bestStructure(for: try Accession("P69905"))
        let mapping = try XCTUnwrap(fetched)

        XCTAssertEqual(mapping.pdbID, "1bab")
        XCTAssertEqual(mapping.chainID, "A")
        XCTAssertEqual(mapping.experimentalMethod, "X-ray diffraction")
        XCTAssertEqual(mapping.resolution ?? 0, 1.5, accuracy: 1e-6)
        XCTAssertEqual(
            mapping.cifURL?.absoluteString,
            "https://www.ebi.ac.uk/pdbe/entry-files/download/1bab_updated.cif")
    }

    /// An NMR entry has no resolution. Defaulting the missing value to zero
    /// would sort it to the top of a best-resolution-first ranking, so it stays
    /// optional all the way through.
    func testMissingResolutionStaysMissing() async throws {
        let body = """
            {"P69905": [{"pdb_id": "2xyz", "chain_id": "B",
             "experimental_method": "Solution NMR", "coverage": 1.0}]}
            """
        let transport = Recorded.complete().replacing(Recorded.pdbeAPI, with: .body(body))
        let fetched = try await PDBeClient(transport: transport)
            .bestStructure(for: try Accession("P69905"))
        let mapping = try XCTUnwrap(fetched)
        XCTAssertNil(mapping.resolution)
        XCTAssertEqual(mapping.pdbID, "2xyz")
    }

    /// PDBe answers a query for a secondary accession under the PRIMARY one, so
    /// looking up the key we asked for returns nothing at all.
    func testPDBeResponseKeyedUnderADifferentAccessionIsStillRead() async throws {
        let body = """
            {"P01922": [{"pdb_id": "1bab", "chain_id": "A",
             "experimental_method": "X-ray diffraction", "resolution": 1.5, "coverage": 1.0}]}
            """
        let transport = Recorded.complete().replacing(Recorded.pdbeAPI, with: .body(body))
        let mapping = try await PDBeClient(transport: transport)
            .bestStructure(for: try Accession("P69905"))
        XCTAssertEqual(mapping?.pdbID, "1bab")
    }
}
