import Foundation
import JumpjetCore

/// The two secondary-structure centroid DIRECTIONS, and the scale the disorder
/// proxy is normalised against.
///
/// Computed offline by `Tools/coreml/compute_centroids.py` and shipped as JSON.
/// Directions rather than points, and mean-removed, for a reason that is worth
/// stating here as well as in the script: the raw Euclidean distance to the
/// nearer centroid separates nothing at all (Cohen's d of -0.023 between coil
/// and regular secondary structure). The two centroids sit 1.32 apart against a
/// within-class spread of 4.60, so relative to the noise they are the same
/// point, and the measurement is swamped by a global mean every residue shares.
/// Removing that mean and comparing directions gives Cohen's d +1.024 and an
/// AUC of 0.801.
public struct FlexibilityCentroids: Sendable, Hashable, Codable {
    public let model: String
    public let embeddingDimension: Int
    public let globalMean: [Float]
    public let helixDirection: [Float]
    public let sheetDirection: [Float]
    /// The 5th and 95th percentiles of the proxy over the reference set, used
    /// to map it to 0 to 1. Percentiles rather than the extremes, because one
    /// outlying residue would otherwise set the whole scale.
    public let proxyPercentile5: Float
    public let proxyPercentile95: Float

    enum CodingKeys: String, CodingKey {
        case model
        case embeddingDimension = "embedding_dimension"
        case globalMean = "global_mean"
        case helixDirection = "helix_direction"
        case sheetDirection = "sheet_direction"
        case proxyPercentile5 = "proxy_percentile_5"
        case proxyPercentile95 = "proxy_percentile_95"
    }

    public static func load(from url: URL) throws -> FlexibilityCentroids {
        let centroids = try JSONDecoder().decode(
            FlexibilityCentroids.self, from: try Data(contentsOf: url))
        try centroids.validate()
        return centroids
    }

    /// Fail loudly on a shape mismatch rather than producing a plausible number
    /// from a truncated dot product.
    public func validate() throws {
        guard globalMean.count == embeddingDimension,
            helixDirection.count == embeddingDimension,
            sheetDirection.count == embeddingDimension
        else {
            throw JumpjetError.parseFailure(
                reason: "centroid file declares dimension \(embeddingDimension) but "
                    + "carries vectors of \(globalMean.count), \(helixDirection.count) "
                    + "and \(sheetDirection.count)")
        }
        guard proxyPercentile95 > proxyPercentile5 else {
            throw JumpjetError.parseFailure(
                reason: "centroid file has a degenerate proxy scale "
                    + "(\(proxyPercentile5) to \(proxyPercentile95))")
        }
    }

    /// The raw disorder proxy for one residue embedding: one minus the cosine
    /// similarity to the nearer of the two centroid directions.
    ///
    /// Higher means less like regular secondary structure.
    public func rawProxy(embedding: ArraySlice<Float>) -> Float {
        precondition(
            embedding.count == embeddingDimension,
            "embedding has \(embedding.count) components, expected \(embeddingDimension)")

        var residualNorm: Float = 0
        var helixDot: Float = 0
        var sheetDot: Float = 0
        for (offset, value) in embedding.enumerated() {
            let residual = value - globalMean[offset]
            residualNorm += residual * residual
            helixDot += residual * helixDirection[offset]
            sheetDot += residual * sheetDirection[offset]
        }
        residualNorm = residualNorm.squareRoot()
        // An embedding exactly at the global mean has no direction. Treat it as
        // maximally unlike either centroid rather than dividing by zero.
        guard residualNorm > 1e-6 else { return 1 }
        return 1 - max(helixDot, sheetDot) / residualNorm
    }

    /// The proxy mapped to 0 to 1 against the reference distribution.
    public func normalisedProxy(embedding: ArraySlice<Float>) -> Float {
        let raw = rawProxy(embedding: embedding)
        let span = proxyPercentile95 - proxyPercentile5
        return min(1, max(0, (raw - proxyPercentile5) / span))
    }
}
