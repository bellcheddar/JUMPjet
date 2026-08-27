import CoreML
import Foundation
import JumpjetCore

/// Runs the converted ESM-2 model and returns per-residue embeddings.
///
/// Build plan ground rule 2: the Neural Engine only executes Core ML graphs, so
/// the physics cannot run there. This is the ANE's genuine job in JUMPjet, and
/// ``ComputePlanReport`` is how the claim gets checked rather than asserted.
public final class ESMEmbedder: @unchecked Sendable {

    public struct Resources: Sendable {
        public let modelURL: URL
        public let tokeniserURL: URL
        public let centroidsURL: URL

        public init(modelURL: URL, tokeniserURL: URL, centroidsURL: URL) {
            self.modelURL = modelURL
            self.tokeniserURL = tokeniserURL
            self.centroidsURL = centroidsURL
        }

        /// The three files as they are laid out in the app bundle.
        public static func inBundle(
            _ bundle: Bundle = .main, model: String = "esm2_t6_8M_UR50D"
        ) throws -> Resources {
            func find(_ name: String, _ ext: String) throws -> URL {
                guard let url = bundle.url(forResource: name, withExtension: ext) else {
                    throw JumpjetError.parseFailure(
                        reason: "\(name).\(ext) is missing from the app bundle")
                }
                return url
            }
            return Resources(
                modelURL: try find(model, "mlmodelc"),
                tokeniserURL: try find("\(model).tokeniser", "json"),
                centroidsURL: try find("flexibility_centroids", "json"))
        }
    }

    private let model: MLModel
    public let tokeniser: Tokeniser
    public let centroids: FlexibilityCentroids
    public let embeddingDimension: Int

    public init(resources: Resources) throws {
        self.tokeniser = try Tokeniser.load(from: resources.tokeniserURL)
        self.centroids = try FlexibilityCentroids.load(from: resources.centroidsURL)
        self.embeddingDimension = centroids.embeddingDimension

        let configuration = MLModelConfiguration()
        // `.all` as the build plan specifies. The model was converted with
        // CPU_AND_NE, so an operation the Neural Engine cannot take falls back
        // to the CPU and shows up in the compute plan, rather than landing
        // quietly on the GPU and looking fast while defeating the point.
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: resources.modelURL, configuration: configuration)
    }

    /// Per-residue embeddings for a sequence, flat and `count * dimension` long.
    ///
    /// - Parameter bucket: force a specific padded length. Only the tests use
    ///   this, to embed one sequence at two lengths and prove the padding mask
    ///   survived tracing. In the app the smallest bucket that fits is always
    ///   the right one, and a larger one is pure wasted attention.
    public func embed(sequence: String, bucket forcedBucket: Int? = nil) throws -> [Float] {
        let residueCount = sequence.count
        guard residueCount > 0 else { return [] }
        guard let bucket = forcedBucket ?? tokeniser.bucket(forResidues: residueCount) else {
            throw JumpjetError.tooLarge(
                residues: residueCount, limit: tokeniser.maximumResidues)
        }
        guard tokeniser.buckets.contains(bucket) else {
            throw JumpjetError.parseFailure(
                reason: "bucket \(bucket) is not one the model accepts "
                    + "(\(tokeniser.buckets))")
        }

        let (tokens, residueRange) = try tokeniser.encode(sequence, bucket: bucket)
        let input = try MLMultiArray(shape: [1, NSNumber(value: bucket)], dataType: .int32)
        // The input is dense and one-dimensional in practice, but write it
        // through the same stride-aware path as the output: a shape Core ML
        // decides to pad is not something to discover from wrong numbers.
        let inputStrides = input.strides.map(\.intValue)
        let inputPointer = input.dataPointer.bindMemory(
            to: Int32.self, capacity: input.count)
        for position in 0..<bucket {
            inputPointer[inputStrides[0] * 0 + inputStrides[1] * position] = tokens[position]
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["tokens": input])
        let output = try model.prediction(from: provider)
        guard let hidden = output.featureValue(for: "hidden_states")?.multiArrayValue else {
            throw JumpjetError.parseFailure(
                reason: "the model returned no hidden_states output")
        }

        return try Self.readEmbeddings(
            from: hidden, residueRange: residueRange, dimension: embeddingDimension)
    }

    /// Extract the real residues' embeddings from a `(1, S, D)` output.
    ///
    /// **Index by `strides`, never by `position * dimension`.** Core ML pads
    /// rows for alignment, so the flat backing store is not simply row-major
    /// packed. Position 0 reads correctly either way, which is exactly what
    /// makes the bug so hard to see: everything after it is silently shifted,
    /// and the result is a complete, plausible, entirely wrong per-residue
    /// profile. This has already produced a perfect-looking heatmap of garbage
    /// in a sibling project.
    static func readEmbeddings(
        from array: MLMultiArray, residueRange: Range<Int>, dimension: Int
    ) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == 3, shape[2] == dimension else {
            throw JumpjetError.parseFailure(
                reason: "hidden_states has shape \(shape), expected (1, S, \(dimension))")
        }
        guard residueRange.upperBound <= shape[1] else {
            throw JumpjetError.parseFailure(
                reason: "residues \(residueRange) fall outside a sequence axis of \(shape[1])")
        }

        var output = [Float](repeating: 0, count: residueRange.count * dimension)

        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for (residue, position) in residueRange.enumerated() {
                let base = strides[0] * 0 + strides[1] * position
                for component in 0..<dimension {
                    output[residue * dimension + component] =
                        pointer[base + strides[2] * component]
                }
            }
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for (residue, position) in residueRange.enumerated() {
                let base = strides[0] * 0 + strides[1] * position
                for component in 0..<dimension {
                    output[residue * dimension + component] =
                        Float(pointer[base + strides[2] * component])
                }
            }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            for (residue, position) in residueRange.enumerated() {
                let base = strides[0] * 0 + strides[1] * position
                for component in 0..<dimension {
                    output[residue * dimension + component] =
                        Float(pointer[base + strides[2] * component])
                }
            }
        default:
            throw JumpjetError.parseFailure(
                reason: "hidden_states has an unsupported data type")
        }
        return output
    }

    /// The whole Phase 2 neural path: sequence and confidence in, prior out.
    public func flexibilityPrior(
        sequence: String, plddt: [Float]?
    ) throws -> FlexibilityPrior {
        let embeddings = try embed(sequence: sequence)
        return try FlexibilityPrior.make(
            plddt: plddt, embeddings: embeddings, centroids: centroids,
            residueCount: sequence.count)
    }
}
