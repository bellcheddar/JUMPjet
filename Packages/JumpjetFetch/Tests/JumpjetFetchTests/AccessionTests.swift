import XCTest
import JumpjetCore

@testable import JumpjetFetch

final class AccessionTests: XCTestCase {

    func testRealAccessionsValidate() throws {
        for text in ["P69905", "P0DTD1", "Q9Y6K9", "A0A0A0MRZ7", "O95793", "P04406"] {
            XCTAssertNoThrow(try Accession(text), "\(text) should be a valid accession")
        }
    }

    func testCaseAndWhitespaceAreTolerated() throws {
        XCTAssertEqual(try Accession("  p69905 ").value, "P69905")
    }

    /// An isoform suffix is kept rather than rejected: the user typed something
    /// meaningful, AlphaFold DB keys on the base accession, and silently
    /// dropping it would lose the fact that they asked for isoform 2.
    func testIsoformSuffixIsSplitOffNotRejected() throws {
        let accession = try Accession("P69905-2")
        XCTAssertEqual(accession.value, "P69905")
        XCTAssertEqual(accession.isoform, 2)
    }

    func testGarbageIsRejectedBeforeAnyNetworkCall() {
        for text in ["", "  ", "HBA_HUMAN", "1BAB", "P6990", "P699055X", "P69905-", "P69905-x"] {
            XCTAssertThrowsError(try Accession(text), "\(text) should be rejected") { error in
                guard case JumpjetError.malformedAccession = error else {
                    return XCTFail("expected malformedAccession for \(text), got \(error)")
                }
            }
        }
    }

    func testIsValidMatchesTheThrowingInitialiser() {
        XCTAssertTrue(Accession.isValid("P69905"))
        XCTAssertFalse(Accession.isValid("nonsense"))
    }
}
