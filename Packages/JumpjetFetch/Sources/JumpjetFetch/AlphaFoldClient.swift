import Foundation
import JumpjetCore

/// One AlphaFold DB prediction, as the API describes it.
public struct AlphaFoldPrediction: Sendable, Hashable, Codable {
    /// For example `AF-P69905-F1`.
    public let entryID: String
    public let accession: String
    public let description: String
    /// The model version, as `v6`. Read from the API, never assumed: the build
    /// plan was written when v4 was current and the database has moved on twice
    /// since, so a hard-coded URL would silently serve a stale model.
    public let version: String
    public let cifURL: URL
    public let pdbURL: URL?

    public init(
        entryID: String, accession: String, description: String, version: String,
        cifURL: URL, pdbURL: URL?
    ) {
        self.entryID = entryID
        self.accession = accession
        self.description = description
        self.version = version
        self.cifURL = cifURL
        self.pdbURL = pdbURL
    }
}

/// Reads AlphaFold DB, which is JUMPjet's first choice of structure: it covers
/// almost every accession, it is a single complete chain with no crystallographic
/// gaps, and it carries pLDDT that Phase 2's flexibility prior needs.
public struct AlphaFoldClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    static func url(for accession: Accession) -> URL? {
        URL(string: "https://alphafold.ebi.ac.uk/api/prediction/\(accession.value)")
    }

    /// Returns `nil` when AlphaFold DB has no model, which is a normal outcome
    /// worth falling back from rather than an error worth showing.
    public func prediction(for accession: Accession) async throws -> AlphaFoldPrediction? {
        guard let url = Self.url(for: accession) else {
            throw JumpjetError.malformedAccession(accession.value)
        }
        guard
            let payloads = try await transport.json(
                [Payload].self, from: url, accession: accession.value, endpoint: "AlphaFold DB"),
            let payload = payloads.first,
            let cif = payload.cifUrl.flatMap(URL.init(string:))
        else { return nil }

        return AlphaFoldPrediction(
            entryID: payload.entryId ?? "AF-\(accession.value)-F1",
            accession: payload.uniprotAccession ?? accession.value,
            description: payload.uniprotDescription ?? "",
            version: payload.latestVersion.map { "v\($0)" } ?? "unknown",
            cifURL: cif,
            pdbURL: payload.pdbUrl.flatMap(URL.init(string:)))
    }

    struct Payload: Decodable {
        let entryId: String?
        let uniprotAccession: String?
        let uniprotDescription: String?
        let latestVersion: Int?
        let cifUrl: String?
        let pdbUrl: String?
    }
}
