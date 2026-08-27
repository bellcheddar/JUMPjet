import Foundation
import XCTest
import JumpjetCore

@testable import JumpjetFetch

/// A transport that answers from recorded fixtures.
///
/// The fetch layer is tested with no network at all: the suite has to pass in a
/// tunnel, and a test that depends on what EBI is serving this morning tells
/// you about EBI rather than about JUMPjet.
struct RecordedTransport: HTTPTransport {

    enum Response: Sendable {
        case fixture(String)
        case status(Int)
        case offline
        case body(String)
    }

    /// Rules are matched by substring in order, so a specific rule listed before
    /// a general one wins. They are fixed at construction: a transport whose
    /// rules could change mid-run would need locking, and locks are unavailable
    /// from the async context `get` runs in.
    private let rules: [(match: String, response: Response)]
    private let log: RequestLog

    init(rules: [(match: String, response: Response)] = []) {
        self.rules = rules
        self.log = RequestLog()
    }

    func replacing(_ match: String, with response: Response) -> RecordedTransport {
        RecordedTransport(rules: [(match, response)] + rules)
    }

    func without(_ match: String) -> RecordedTransport {
        RecordedTransport(rules: rules.filter { $0.match != match })
    }

    func requests() async -> [String] { await log.entries }

    func requests(containing needle: String) async -> Int {
        await log.entries.filter { $0.contains(needle) }.count
    }

    func get(_ url: URL) async throws -> (Data, Int) {
        await log.record(url.absoluteString)

        guard let matched = rules.first(where: { url.absoluteString.contains($0.match) })?.response
        else {
            // An unmatched URL means the test has drifted from the code, so it
            // fails loudly rather than reading as a 404 the code handles.
            XCTFail("no recorded response for \(url.absoluteString)")
            return (Data(), 599)
        }

        switch matched {
        case .fixture(let path):
            return (try Fixtures.data(path), 200)
        case .body(let text):
            return (Data(text.utf8), 200)
        case .status(let code):
            return (Data(), code)
        case .offline:
            throw JumpjetError.offlineAndUncached(accession: url.lastPathComponent)
        }
    }
}

/// The request log, isolated so concurrent fetches cannot race on it.
actor RequestLog {
    private(set) var entries: [String] = []
    func record(_ url: String) { entries.append(url) }
}

/// The five fixture endpoints, in one place so a URL change breaks once.
enum Recorded {
    static let uniProt = "rest.uniprot.org/uniprotkb/P69905"
    static let alphaFoldAPI = "alphafold.ebi.ac.uk/api/prediction/P69905"
    static let alphaFoldCIF = "AF-P69905-F1-model_v6.cif"
    static let pdbeAPI = "pdbe/api/mappings/best_structures/P69905"
    static let pdbeCIF = "1bab_updated.cif"

    /// A transport where every request fails as if the device were offline.
    ///
    /// Matched on "http" rather than on "": `"abc".contains("")` is FALSE in
    /// Swift, so an empty match string silently matches nothing and every
    /// request falls through to the unmatched branch instead.
    static func offline() -> RecordedTransport {
        RecordedTransport(rules: [("http", .offline)])
    }

    static func complete() -> RecordedTransport {
        RecordedTransport(rules: [
            (uniProt, .fixture("api/uniprot_P69905.json")),
            (alphaFoldAPI, .fixture("api/afdb_P69905.json")),
            (alphaFoldCIF, .fixture("structures/AF-P69905-F1-model_v6.cif")),
            (pdbeAPI, .fixture("api/pdbe_best_P69905.json")),
            (pdbeCIF, .fixture("structures/1bab.cif")),
        ])
    }
}

/// A cache rooted in a fresh temporary directory, removed when the test ends.
func makeTemporaryCache(_ testCase: XCTestCase) -> ModelCache {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jumpjet-tests-\(UUID().uuidString)", isDirectory: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: directory)
    }
    return ModelCache(directory: directory)
}
