import Foundation
import JumpjetCore

/// The best experimental structure PDBe knows of for an accession.
public struct PDBeMapping: Sendable, Hashable, Codable {
    public let pdbID: String
    public let chainID: String
    public let experimentalMethod: String
    /// Resolution in angstroms. Absent for NMR and for some cryo-EM entries,
    /// which is why it is optional rather than defaulted to zero: a zero would
    /// sort to the top of a "best resolution first" list.
    public let resolution: Double?
    public let coverage: Double?

    public init(
        pdbID: String, chainID: String, experimentalMethod: String, resolution: Double?,
        coverage: Double?
    ) {
        self.pdbID = pdbID
        self.chainID = chainID
        self.experimentalMethod = experimentalMethod
        self.resolution = resolution
        self.coverage = coverage
    }

    /// The mmCIF for this entry. PDBe serves mmCIF for everything, including
    /// entries too large for the legacy PDB format to express at all.
    public var cifURL: URL? {
        URL(string: "https://www.ebi.ac.uk/pdbe/entry-files/download/\(pdbID.lowercased())_updated.cif")
    }
}

/// The fallback when AlphaFold DB has no model.
public struct PDBeClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    static func url(for accession: Accession) -> URL? {
        URL(
            string:
                "https://www.ebi.ac.uk/pdbe/api/mappings/best_structures/\(accession.value)")
    }

    public func bestStructure(for accession: Accession) async throws -> PDBeMapping? {
        guard let url = Self.url(for: accession) else {
            throw JumpjetError.malformedAccession(accession.value)
        }
        guard
            let payload = try await transport.json(
                [String: [Payload]].self, from: url, accession: accession.value,
                endpoint: "PDBe")
        else { return nil }

        // The response is keyed by accession, but PDBe answers a query for a
        // secondary accession under the PRIMARY one. Taking the first value
        // rather than looking up the key we asked for is deliberate.
        guard let hits = payload.values.first(where: { !$0.isEmpty }) else { return nil }

        // PDBe already returns these best-first, but the ordering is by
        // coverage and resolution together and it costs nothing to be explicit.
        let best = hits.min { left, right in
            (left.coverage ?? 0, -(left.resolution ?? 99))
                > (right.coverage ?? 0, -(right.resolution ?? 99))
        }
        guard let best, let pdbID = best.pdb_id else { return nil }

        return PDBeMapping(
            pdbID: pdbID,
            chainID: best.chain_id ?? "A",
            experimentalMethod: best.experimental_method ?? "Unknown method",
            resolution: best.resolution,
            coverage: best.coverage)
    }

    struct Payload: Decodable {
        let pdb_id: String?
        let chain_id: String?
        let experimental_method: String?
        let resolution: Double?
        let coverage: Double?
    }
}
