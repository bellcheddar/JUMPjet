import Foundation

/// Every failure a user can be shown, with copy written for the HUD rather than
/// for a log file. The build plan asks for sensible errors on bad accessions
/// and offline mode, so the message is part of the type.
public enum JumpjetError: Error, Sendable, Equatable {
    /// The accession did not look like a UniProt accession at all.
    case malformedAccession(String)
    /// The accession was well formed but no such entry exists.
    case unknownAccession(String)
    /// UniProt knows the entry, but neither AlphaFold DB nor PDBe has a model.
    case noStructureAvailable(accession: String)
    /// The network is unreachable and nothing is cached.
    case offlineAndUncached(accession: String)
    /// A server answered, but not with success.
    case serverError(status: Int, endpoint: String)
    /// The file downloaded but could not be read.
    case parseFailure(reason: String)
    /// The structure parsed but is beyond what v1 will sample.
    case tooLarge(residues: Int, limit: Int)
    /// The file parsed to nothing usable.
    case emptyStructure

    public var title: String {
        switch self {
        case .malformedAccession: "Accession not recognised"
        case .unknownAccession: "No such entry"
        case .noStructureAvailable: "No structure available"
        case .offlineAndUncached: "Offline"
        case .serverError: "Server unavailable"
        case .parseFailure: "Could not read the model"
        case .tooLarge: "Structure too large"
        case .emptyStructure: "Nothing to show"
        }
    }

    public var message: String {
        switch self {
        case .malformedAccession(let text):
            "\"\(text)\" is not a UniProt accession. Try something like P69905 or P0DTD1."
        case .unknownAccession(let accession):
            "UniProt has no entry for \(accession). Check the accession and try again."
        case .noStructureAvailable(let accession):
            "\(accession) exists, but neither AlphaFold DB nor PDBe has a model for it."
        case .offlineAndUncached(let accession):
            "There is no network connection and \(accession) is not in the cache."
        case .serverError(let status, let endpoint):
            "\(endpoint) answered with HTTP \(status). It may be busy, so try again shortly."
        case .parseFailure(let reason):
            "The downloaded model could not be read: \(reason)"
        case .tooLarge(let residues, let limit):
            """
            This chain has \(residues) residues and JUMPjet v1 samples up to \(limit). \
            Pick a shorter chain, or wait for a build that can take it.
            """
        case .emptyStructure:
            "The model downloaded but contained no atoms."
        }
    }
}

extension JumpjetError: LocalizedError {
    public var errorDescription: String? { title }
    public var failureReason: String? { message }
}
