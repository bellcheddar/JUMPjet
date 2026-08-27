import Foundation
import JumpjetCore
import JumpjetParse

/// Where a loaded model came from, in enough detail for the HUD to say it out
/// loud. JUMPjet never shows a structure without saying which one it is.
public struct Provenance: Sendable, Hashable, Codable {
    public let source: StructureSource
    public let entryID: String
    public let version: String
    /// A one-line description: "AlphaFold DB v6" or "PDBe 1BAB chain A, X-ray 1.50 A".
    public let detail: String
    public let fetchedAt: Date
    public let fromCache: Bool

    public init(
        source: StructureSource, entryID: String, version: String, detail: String,
        fetchedAt: Date, fromCache: Bool
    ) {
        self.source = source
        self.entryID = entryID
        self.version = version
        self.detail = detail
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
    }
}

/// A structure, its metadata and its provenance.
public struct LoadedModel: Sendable {
    public let accession: Accession
    public let entry: UniProtEntry?
    public let structure: Structure
    public let report: ParseReport
    public let provenance: Provenance

    public init(
        accession: Accession, entry: UniProtEntry?, structure: Structure, report: ParseReport,
        provenance: Provenance
    ) {
        self.accession = accession
        self.entry = entry
        self.structure = structure
        self.report = report
        self.provenance = provenance
    }
}

/// What the loader is doing, so the HUD can show it rather than a spinner.
public enum LoadPhase: Sendable, Hashable {
    case validating
    case readingMetadata
    case locatingStructure
    case downloading(source: StructureSource)
    case parsing
    case servingFromCache
    case done

    public var caption: String {
        switch self {
        case .validating: "CHECKING ACCESSION"
        case .readingMetadata: "READING UNIPROT"
        case .locatingStructure: "LOCATING STRUCTURE"
        case .downloading(let source): "DOWNLOADING FROM \(source.displayName.uppercased())"
        case .parsing: "PARSING MODEL"
        case .servingFromCache: "SERVING FROM CACHE"
        case .done: "READY"
        }
    }
}

/// The one entry point Phase 1's UI calls: accession in, structure out.
///
/// The order is AlphaFold DB first, PDBe second, cache last, per the build plan.
/// The cache is a fallback rather than a first stop because a model's version is
/// only knowable by asking, and serving a stale prediction silently is exactly
/// the sort of quiet wrongness ground rule 3 exists to prevent. When the network
/// is unavailable the cache serves and the provenance says so.
public struct StructureService: Sendable {
    private let uniProt: UniProtClient
    private let alphaFold: AlphaFoldClient
    private let pdbe: PDBeClient
    private let transport: any HTTPTransport
    private let cache: ModelCache
    private let residueLimit: Int
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport = URLSessionTransport.standard(),
        cache: ModelCache = ModelCache(),
        residueLimit: Int = Limits.maximumResidues,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.uniProt = UniProtClient(transport: transport)
        self.alphaFold = AlphaFoldClient(transport: transport)
        self.pdbe = PDBeClient(transport: transport)
        self.cache = cache
        self.residueLimit = residueLimit
        self.now = now
    }

    public func load(
        _ rawAccession: String,
        progress: (@Sendable (LoadPhase) -> Void)? = nil
    ) async throws -> LoadedModel {
        progress?(.validating)
        let accession = try Accession(rawAccession)

        // Metadata is nice to have, not required: an accession that UniProt is
        // slow about should not stop a structure that AlphaFold DB will serve.
        progress?(.readingMetadata)
        let entry = try? await uniProt.entry(for: accession)

        do {
            progress?(.locatingStructure)
            if let model = try await loadFromAlphaFold(accession, entry: entry, progress: progress) {
                return model
            }
            if let model = try await loadFromPDBe(accession, entry: entry, progress: progress) {
                return model
            }
            // Both sources answered and neither has a model. That is a real
            // answer about the accession, so do not paper over it with a cache
            // hit from a previous run.
            if entry == nil {
                throw JumpjetError.unknownAccession(accession.value)
            }
            throw JumpjetError.noStructureAvailable(accession: accession.value)
        } catch let error as JumpjetError {
            // Only network failures fall back to the cache. A structure that is
            // genuinely too large is too large whether it came off disk or not.
            switch error {
            case .offlineAndUncached, .serverError:
                progress?(.servingFromCache)
                if let cached = try await loadFromCache(accession, entry: entry) {
                    progress?(.done)
                    return cached
                }
                throw JumpjetError.offlineAndUncached(accession: accession.value)
            default:
                throw error
            }
        }
    }

    // MARK: - Sources

    private func loadFromAlphaFold(
        _ accession: Accession, entry: UniProtEntry?,
        progress: (@Sendable (LoadPhase) -> Void)?
    ) async throws -> LoadedModel? {
        guard let prediction = try await alphaFold.prediction(for: accession) else { return nil }

        if let cached = await cache.read(
            accession: accession.value, source: .alphaFold, version: prediction.version)
        {
            progress?(.parsing)
            return try model(
                from: cached.1, accession: accession, entry: entry, manifest: cached.0,
                fromCache: true)
        }

        progress?(.downloading(source: .alphaFold))
        let text = try await download(prediction.cifURL, accession: accession)

        let manifest = CachedModel(
            accession: accession.value, source: .alphaFold, version: prediction.version,
            entryID: prediction.entryID,
            detail: "AlphaFold DB \(prediction.version)",
            fetchedAt: now(), entry: entry)

        progress?(.parsing)
        let loaded = try model(
            from: text, accession: accession, entry: entry, manifest: manifest, fromCache: false)
        try? await cache.write(manifest, body: text)
        progress?(.done)
        return loaded
    }

    private func loadFromPDBe(
        _ accession: Accession, entry: UniProtEntry?,
        progress: (@Sendable (LoadPhase) -> Void)?
    ) async throws -> LoadedModel? {
        guard let mapping = try await pdbe.bestStructure(for: accession),
            let url = mapping.cifURL
        else { return nil }

        var detail = "PDBe \(mapping.pdbID.uppercased()) chain \(mapping.chainID), "
            + mapping.experimentalMethod
        if let resolution = mapping.resolution {
            detail += String(format: " %.2f A", resolution)
        }

        if let cached = await cache.read(
            accession: accession.value, source: .pdbe, version: mapping.pdbID.uppercased())
        {
            progress?(.parsing)
            return try model(
                from: cached.1, accession: accession, entry: entry, manifest: cached.0,
                fromCache: true)
        }

        progress?(.downloading(source: .pdbe))
        let text = try await download(url, accession: accession)

        let manifest = CachedModel(
            accession: accession.value, source: .pdbe, version: mapping.pdbID.uppercased(),
            entryID: mapping.pdbID.uppercased(), detail: detail, fetchedAt: now(), entry: entry)

        progress?(.parsing)
        let loaded = try model(
            from: text, accession: accession, entry: entry, manifest: manifest, fromCache: false)
        try? await cache.write(manifest, body: text)
        progress?(.done)
        return loaded
    }

    private func loadFromCache(
        _ accession: Accession, entry: UniProtEntry?
    ) async throws -> LoadedModel? {
        guard let (manifest, text) = await cache.newest(accession: accession.value) else {
            return nil
        }
        return try model(
            from: text, accession: accession, entry: entry ?? manifest.entry, manifest: manifest,
            fromCache: true)
    }

    // MARK: - Plumbing

    private func download(_ url: URL, accession: Accession) async throws -> String {
        let (data, status) = try await transport.get(url)
        guard status == 200 else {
            throw JumpjetError.serverError(status: status, endpoint: url.host ?? "the server")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw JumpjetError.parseFailure(reason: "the downloaded model is not UTF-8 text")
        }
        return text
    }

    private func model(
        from text: String, accession: Accession, entry: UniProtEntry?, manifest: CachedModel,
        fromCache: Bool
    ) throws -> LoadedModel {
        let result = try StructureReader.parse(
            text,
            identifier: manifest.source == .alphaFold ? accession.value : manifest.entryID,
            source: manifest.source,
            modelVersion: manifest.version,
            residueLimit: residueLimit)

        return LoadedModel(
            accession: accession,
            entry: entry ?? manifest.entry,
            structure: result.structure,
            report: result.report,
            provenance: Provenance(
                source: manifest.source,
                entryID: manifest.entryID,
                version: manifest.version,
                detail: manifest.detail,
                fetchedAt: manifest.fetchedAt,
                fromCache: fromCache))
    }
}
