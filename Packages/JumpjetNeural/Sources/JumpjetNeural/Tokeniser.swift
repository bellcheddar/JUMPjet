import Foundation
import JumpjetCore

/// The ESM-2 alphabet, loaded from the JSON the conversion script exported.
///
/// Loaded rather than hard-coded, because a tokeniser mismatch does not crash:
/// it produces confident, wrong embeddings, which is the worst failure mode
/// available. The exported file is the same object the PyTorch model used, so
/// the two cannot drift.
public struct Tokeniser: Sendable, Hashable, Codable {
    public let tokens: [String]
    public let tokenToIndex: [String: Int]
    public let paddingIndex: Int
    public let clsIndex: Int
    public let eosIndex: Int
    public let maskIndex: Int
    public let unknownIndex: Int
    public let prependBOS: Bool
    public let appendEOS: Bool
    /// The sequence lengths the converted model accepts. Must match `BUCKETS`
    /// in `convert_esm2.py`: a bucket in one and not the other fails at
    /// prediction time, on device.
    public let buckets: [Int]

    enum CodingKeys: String, CodingKey {
        case tokens
        case tokenToIndex = "token_to_index"
        case paddingIndex = "padding_index"
        case clsIndex = "cls_index"
        case eosIndex = "eos_index"
        case maskIndex = "mask_index"
        case unknownIndex = "unknown_index"
        case prependBOS = "prepend_bos"
        case appendEOS = "append_eos"
        case buckets
    }

    public static func load(from url: URL) throws -> Tokeniser {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Tokeniser.self, from: data)
    }

    /// The smallest bucket that fits a sequence, or `nil` when none does.
    ///
    /// Token count is residues plus cls plus eos, and forgetting those two is
    /// how a sequence that exactly fills a bucket overflows it by two.
    public func bucket(forResidues count: Int) -> Int? {
        let needed = count + (prependBOS ? 1 : 0) + (appendEOS ? 1 : 0)
        return buckets.sorted().first { $0 >= needed }
    }

    public var maximumResidues: Int {
        (buckets.max() ?? 0) - (prependBOS ? 1 : 0) - (appendEOS ? 1 : 0)
    }

    public func index(of residue: Character) -> Int {
        tokenToIndex[String(residue)] ?? unknownIndex
    }

    /// Token ids for a sequence, padded to `bucket`.
    ///
    /// Returns the ids and the range of positions holding real residues, so a
    /// caller slicing the model's output never has to recompute the offset.
    /// Recomputing it is how an embedding array ends up shifted by one and
    /// every per-residue value lands on its neighbour.
    public func encode(_ sequence: String, bucket: Int) throws -> (
        tokens: [Int32], residueRange: Range<Int>
    ) {
        let residues = Array(sequence)
        let leading = prependBOS ? 1 : 0
        let trailing = appendEOS ? 1 : 0
        guard residues.count + leading + trailing <= bucket else {
            throw JumpjetError.tooLarge(
                residues: residues.count, limit: bucket - leading - trailing)
        }

        var ids = [Int32](repeating: Int32(paddingIndex), count: bucket)
        if prependBOS { ids[0] = Int32(clsIndex) }
        for (offset, residue) in residues.enumerated() {
            ids[leading + offset] = Int32(index(of: residue))
        }
        if appendEOS { ids[leading + residues.count] = Int32(eosIndex) }
        return (ids, leading..<(leading + residues.count))
    }
}
