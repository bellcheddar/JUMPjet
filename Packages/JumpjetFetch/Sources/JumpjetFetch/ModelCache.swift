import Foundation
import JumpjetCore

/// Where a cached model came from and what it is, stored beside the bytes.
public struct CachedModel: Sendable, Hashable, Codable {
    public let accession: String
    public let source: StructureSource
    /// `v6` for an AlphaFold model, the PDB ID for an experimental one.
    public let version: String
    public let entryID: String
    public let detail: String
    public let fetchedAt: Date
    public let entry: UniProtEntry?

    public init(
        accession: String, source: StructureSource, version: String, entryID: String,
        detail: String, fetchedAt: Date, entry: UniProtEntry?
    ) {
        self.accession = accession
        self.source = source
        self.version = version
        self.entryID = entryID
        self.detail = detail
        self.fetchedAt = fetchedAt
        self.entry = entry
    }

    /// The on-disk stem, keyed by accession, source AND version as the build
    /// plan asks. Including the version is what makes a new AlphaFold release
    /// a cache miss rather than a stale model served forever.
    var stem: String {
        let safeVersion = version.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "\(accession)__\(source.rawValue)__\(safeVersion)"
    }
}

/// The on-disk model cache.
///
/// An actor because the app can have a fetch in flight while the user starts
/// another, and two writers on the same file is a corrupted model rather than a
/// crash, which is far harder to notice.
public actor ModelCache {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            // Caches, not Application Support: these are re-downloadable and
            // marking them otherwise means the system cannot reclaim the space
            // and iCloud tries to back them up.
            let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("JUMPjet/Models", isDirectory: true)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Reading

    /// The exact model, when the version is known.
    public func read(accession: String, source: StructureSource, version: String) -> (
        CachedModel, String
    )? {
        let stem = CachedModel(
            accession: accession, source: source, version: version, entryID: "", detail: "",
            fetchedAt: .distantPast, entry: nil
        ).stem
        return read(stem: stem)
    }

    /// The newest cached model for an accession, whatever its version or source.
    ///
    /// This is the offline path: with no network there is no way to ask which
    /// version is current, so the most recently fetched one is the right answer
    /// and the HUD says how old it is.
    public func newest(accession: String) -> (CachedModel, String)? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let prefix = "\(accession)__"
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .compactMap { read(stem: $0) }
            // Prefer AlphaFold on a tie: it is the primary source, so a stale
            // experimental fallback should not outrank a prediction fetched in
            // the same second.
            .max { left, right in
                (left.0.fetchedAt, left.0.source == .alphaFold ? 1 : 0)
                    < (right.0.fetchedAt, right.0.source == .alphaFold ? 1 : 0)
            }
    }

    private func read(stem: String) -> (CachedModel, String)? {
        let manifestURL = directory.appendingPathComponent("\(stem).json")
        let bodyURL = directory.appendingPathComponent("\(stem).model")
        guard let manifestData = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder.jumpjet.decode(CachedModel.self, from: manifestData),
            let body = try? String(contentsOf: bodyURL, encoding: .utf8)
        else { return nil }
        return (manifest, body)
    }

    // MARK: - Writing

    public func write(_ model: CachedModel, body: String) throws {
        try ensureDirectory()
        let manifestURL = directory.appendingPathComponent("\(model.stem).json")
        let bodyURL = directory.appendingPathComponent("\(model.stem).model")

        // Body first, manifest second. A manifest without a body reads as a
        // cache hit and then fails; a body without a manifest is invisible and
        // harmless, so this is the safe order to be interrupted in.
        try body.write(to: bodyURL, atomically: true, encoding: .utf8)
        try JSONEncoder.jumpjet.encode(model).write(to: manifestURL, options: .atomic)

        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutableBody = bodyURL
        var mutableManifest = manifestURL
        try? mutableBody.setResourceValues(resource)
        try? mutableManifest.setResourceValues(resource)
    }

    // MARK: - Housekeeping

    public func removeAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    public func totalBytes() -> Int {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        return names.reduce(0) { running, name in
            let attributes = try? fileManager.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path)
            return running + ((attributes?[.size] as? Int) ?? 0)
        }
    }

    public var cacheDirectory: URL { directory }
}

extension JSONDecoder {
    static let jumpjet: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let jumpjet: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
