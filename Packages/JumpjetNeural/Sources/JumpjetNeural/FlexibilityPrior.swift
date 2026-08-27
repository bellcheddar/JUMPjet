import Foundation
import JumpjetCore

/// Per-residue flexibility in 0 to 1, which parameterises the Phase 2 physics:
/// spring constants are scaled DOWN by it so floppy loops move and cores hold,
/// and move amplitudes are scaled UP by it.
public struct FlexibilityPrior: Sendable, Hashable {
    /// One value per residue, 0 rigid to 1 floppy.
    public let values: [Float]
    /// How it was computed, so the HUD can say so rather than implying more
    /// than was measured.
    public let blend: Blend

    public enum Blend: String, Sendable, Hashable, Codable {
        /// The build plan's v1 recipe: 70% normalised inverse pLDDT, 30%
        /// embedding-derived disorder proxy.
        case confidenceAndEmbedding
        /// An experimental structure has no pLDDT. Its B-factors are real
        /// B-factors and putting them on a prediction's certainty axis is the
        /// same category error the viewer already refuses to make, so the
        /// prior falls back to the embedding proxy alone.
        case embeddingOnly

        public var caption: String {
            switch self {
            case .confidenceAndEmbedding: "pLDDT 70% + embedding 30%"
            case .embeddingOnly: "embedding only (no pLDDT)"
            }
        }
    }

    /// The build plan's weighting.
    public static let confidenceWeight: Float = 0.70
    public static let embeddingWeight: Float = 0.30

    /// AlphaFold's own band boundaries, reused as the normalisation range: at
    /// or above 90 is "very high" and reads as rigid, at or below 50 is "very
    /// low" and reads as floppy. Normalising over the full 0 to 100 instead
    /// would compress every real structure into the top third of the scale.
    public static let rigidPLDDT: Float = 90
    public static let floppyPLDDT: Float = 50

    /// Residues either side that the smoothing window spans.
    ///
    /// A prior that jumps residue to residue makes the sampler jitter: the
    /// elastic network would have a stiff residue wedged between two soft ones
    /// and spend its moves fighting itself. Flexibility is a property of a
    /// stretch of chain, so it is smoothed over one.
    public static let smoothingRadius = 2

    public init(values: [Float], blend: Blend) {
        self.values = values
        self.blend = blend
    }

    /// Build the prior from per-residue pLDDT and per-residue embeddings.
    ///
    /// - Parameters:
    ///   - plddt: per-residue pLDDT on 0 to 100, or `nil` for a structure that
    ///     has none, which selects ``Blend/embeddingOnly``.
    ///   - embeddings: flat, `residueCount * dimension` values.
    public static func make(
        plddt: [Float]?,
        embeddings: [Float],
        centroids: FlexibilityCentroids,
        residueCount: Int
    ) throws -> FlexibilityPrior {
        let dimension = centroids.embeddingDimension
        guard embeddings.count == residueCount * dimension else {
            throw JumpjetError.parseFailure(
                reason: "expected \(residueCount * dimension) embedding values for "
                    + "\(residueCount) residues, got \(embeddings.count)")
        }
        if let plddt, plddt.count != residueCount {
            throw JumpjetError.parseFailure(
                reason: "expected \(residueCount) pLDDT values, got \(plddt.count)")
        }

        var disorder = [Float](repeating: 0, count: residueCount)
        for residue in 0..<residueCount {
            let start = residue * dimension
            disorder[residue] = centroids.normalisedProxy(
                embedding: embeddings[start..<(start + dimension)])
        }

        let blend: Blend = plddt == nil ? .embeddingOnly : .confidenceAndEmbedding
        var combined = [Float](repeating: 0, count: residueCount)
        for residue in 0..<residueCount {
            if let plddt {
                combined[residue] =
                    confidenceWeight * invertedConfidence(plddt[residue])
                    + embeddingWeight * disorder[residue]
            } else {
                combined[residue] = disorder[residue]
            }
        }

        return FlexibilityPrior(values: smoothed(combined), blend: blend)
    }

    /// pLDDT to a 0-to-1 flexibility contribution, clamped at the band edges.
    public static func invertedConfidence(_ plddt: Float) -> Float {
        let span = rigidPLDDT - floppyPLDDT
        return min(1, max(0, (rigidPLDDT - plddt) / span))
    }

    /// A triangular window over `smoothingRadius` residues either side.
    ///
    /// Triangular rather than a box: a box window gives every residue in range
    /// equal say, so a single very floppy residue raises its neighbours by as
    /// much as it raises itself, and a sharp boundary between a helix and a
    /// loop smears symmetrically across it.
    public static func smoothed(_ values: [Float]) -> [Float] {
        guard smoothingRadius > 0, values.count > 2 * smoothingRadius else { return values }
        var output = [Float](repeating: 0, count: values.count)
        for index in values.indices {
            var total: Float = 0
            var weightSum: Float = 0
            for offset in -smoothingRadius...smoothingRadius {
                let neighbour = index + offset
                guard values.indices.contains(neighbour) else { continue }
                let weight = Float(smoothingRadius + 1 - abs(offset))
                total += values[neighbour] * weight
                weightSum += weight
            }
            output[index] = weightSum > 0 ? total / weightSum : values[index]
        }
        return output
    }

    // MARK: - Summary

    public var mean: Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Indices of the most flexible residues, most flexible first.
    public func hotspots(limit: Int = 10) -> [Int] {
        values.indices.sorted { values[$0] > values[$1] }.prefix(limit).map { $0 }
    }
}
