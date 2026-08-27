import Foundation
import JumpjetCore

/// What JUMPjet needs to know about an entry before it fetches a structure.
public struct UniProtEntry: Sendable, Hashable, Codable {
    public let accession: String
    /// The mnemonic, such as HBA_HUMAN.
    public let entryName: String
    public let proteinName: String
    public let organism: String
    public let sequence: String

    public var length: Int { sequence.count }

    public init(
        accession: String, entryName: String, proteinName: String, organism: String,
        sequence: String
    ) {
        self.accession = accession
        self.entryName = entryName
        self.proteinName = proteinName
        self.organism = organism
        self.sequence = sequence
    }
}

/// Reads UniProtKB entry metadata.
public struct UniProtClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// The fields JUMPjet actually displays.
    ///
    /// Asking for the whole entry returns roughly 270 kB for a 142-residue
    /// protein, almost all of it cross-references, on a phone that is about to
    /// download a structure file as well.
    static let fields = "accession,id,protein_name,organism_name,sequence,length"

    static func url(for accession: Accession) -> URL? {
        var components = URLComponents(string: "https://rest.uniprot.org/uniprotkb/\(accession.value).json")
        components?.queryItems = [URLQueryItem(name: "fields", value: fields)]
        return components?.url
    }

    public func entry(for accession: Accession) async throws -> UniProtEntry {
        guard let url = Self.url(for: accession) else {
            throw JumpjetError.malformedAccession(accession.value)
        }
        guard
            let payload = try await transport.json(
                Payload.self, from: url, accession: accession.value, endpoint: "UniProt")
        else {
            throw JumpjetError.unknownAccession(accession.value)
        }
        return payload.entry
    }

    /// The slice of UniProt's JSON that JUMPjet reads.
    ///
    /// Decoded structurally rather than with `JSONSerialization` lookups so a
    /// change in the API shape fails loudly at the boundary instead of quietly
    /// producing an entry named "".
    struct Payload: Decodable {
        struct ProteinDescription: Decodable {
            struct Name: Decodable {
                struct Value: Decodable { let value: String }
                let fullName: Value
            }
            let recommendedName: Name?
            let submissionNames: [Name]?
        }
        struct Organism: Decodable {
            let scientificName: String?
            let commonName: String?
        }
        struct Sequence: Decodable {
            let value: String
        }

        let primaryAccession: String
        let uniProtkbId: String?
        let proteinDescription: ProteinDescription?
        let organism: Organism?
        let sequence: Sequence

        var entry: UniProtEntry {
            // An unreviewed entry has no recommended name, only a submission
            // name. Falling straight through to "" would give TrEMBL entries a
            // blank title in the HUD, which reads as a bug rather than as a
            // less well annotated protein.
            let name = proteinDescription?.recommendedName?.fullName.value
                ?? proteinDescription?.submissionNames?.first?.fullName.value
                ?? primaryAccession
            return UniProtEntry(
                accession: primaryAccession,
                entryName: uniProtkbId ?? primaryAccession,
                proteinName: name,
                organism: organism?.scientificName ?? organism?.commonName ?? "Unknown organism",
                sequence: sequence.value)
        }
    }
}
