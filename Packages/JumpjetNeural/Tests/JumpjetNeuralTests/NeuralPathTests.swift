import CoreML
import XCTest
import JumpjetCore

@testable import JumpjetNeural

/// The Swift path against the PyTorch reference.
///
/// `validate_parity.py` proves Core ML reproduces PyTorch. It says nothing
/// about whether Swift drives Core ML correctly, and the two ways of getting
/// that wrong both produce confident, plausible, entirely wrong numbers rather
/// than an error: a tokeniser that has drifted, and reading an MLMultiArray by
/// `position * dimension` when Core ML has padded the rows.
final class NeuralPathTests: XCTestCase {

    /// The three shipped artefacts, at their repository paths. `Fixtures` walks
    /// up from this source file, so `Models` is its sibling.
    private static var resources: ESMEmbedder.Resources {
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        return ESMEmbedder.Resources(
            modelURL: models.appendingPathComponent("esm2_t6_8M_UR50D.mlmodelc"),
            tokeniserURL: models.appendingPathComponent("esm2_t6_8M_UR50D.tokeniser.json"),
            centroidsURL: models.appendingPathComponent("flexibility_centroids.json"))
    }

    private struct Reference: Decodable {
        let sequence: String
        let residues: Int
        let dimension: Int
        let tokenIDs: [Int32]
        let rawProxy: [Float]

        enum CodingKeys: String, CodingKey {
            case sequence, residues, dimension
            case tokenIDs = "token_ids"
            case rawProxy = "raw_proxy"
        }
    }

    private func loadReference() throws -> (Reference, [Float]) {
        let header = try JSONDecoder().decode(
            Reference.self, from: try Fixtures.data("neural/ubiquitin_reference.json"))
        let raw = try Fixtures.data("neural/ubiquitin_reference.bin")
        let floats = raw.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
        XCTAssertEqual(floats.count, header.residues * header.dimension)
        return (header, floats)
    }

    // MARK: - Tokeniser

    /// Swift builds the token ids itself. Off by one on the cls offset, or a
    /// residue mapped to the unknown token, and every embedding after it is
    /// wrong with no error anywhere.
    func testSwiftTokenisationMatchesPyTorchExactly() throws {
        let (reference, _) = try loadReference()
        let tokeniser = try Tokeniser.load(from: Self.resources.tokeniserURL)

        let bucket = try XCTUnwrap(tokeniser.bucket(forResidues: reference.residues))
        let (tokens, range) = try tokeniser.encode(reference.sequence, bucket: bucket)

        XCTAssertEqual(range.count, reference.residues)
        XCTAssertEqual(Array(tokens[0..<reference.tokenIDs.count]), reference.tokenIDs)
        // Everything past the reference's own tokens must be padding.
        for position in reference.tokenIDs.count..<bucket {
            XCTAssertEqual(tokens[position], Int32(tokeniser.paddingIndex))
        }
    }

    /// A bucket must fit residues PLUS the cls and eos tokens. Forgetting those
    /// two is how a sequence that exactly fills a bucket overflows it.
    func testBucketSelectionAccountsForTheWrapperTokens() throws {
        let tokeniser = try Tokeniser.load(from: Self.resources.tokeniserURL)
        let buckets = tokeniser.buckets.sorted()
        let smallest = try XCTUnwrap(buckets.first)

        XCTAssertEqual(tokeniser.bucket(forResidues: smallest - 2), smallest)
        XCTAssertEqual(tokeniser.bucket(forResidues: smallest - 1), buckets[1])
        XCTAssertNil(tokeniser.bucket(forResidues: tokeniser.maximumResidues + 1))
    }

    func testEncodingBeyondTheBucketThrows() throws {
        let tokeniser = try Tokeniser.load(from: Self.resources.tokeniserURL)
        XCTAssertThrowsError(
            try tokeniser.encode(String(repeating: "A", count: 200), bucket: 128))
    }

    // MARK: - Embeddings

    /// The gate that catches the stride bug.
    ///
    /// Tolerance is on cosine per residue rather than on absolute values,
    /// because fp16 conversion moves the magnitudes and the parity script has
    /// already established that it does so within 0.9999. A stride error does
    /// not produce a small deviation: it produces a DIFFERENT residue's
    /// embedding, whose cosine to the right answer is around zero.
    func testEmbeddingsMatchPyTorchResidueForResidue() throws {
        let (reference, expected) = try loadReference()
        let embedder = try ESMEmbedder(resources: Self.resources)
        let actual = try embedder.embed(sequence: reference.sequence)

        XCTAssertEqual(actual.count, expected.count)
        let dimension = reference.dimension

        var worst: Float = 1
        for residue in 0..<reference.residues {
            let start = residue * dimension
            var dot: Float = 0
            var expectedNorm: Float = 0
            var actualNorm: Float = 0
            for component in 0..<dimension {
                let e = expected[start + component]
                let a = actual[start + component]
                dot += e * a
                expectedNorm += e * e
                actualNorm += a * a
            }
            let cosine = dot / (expectedNorm.squareRoot() * actualNorm.squareRoot())
            worst = min(worst, cosine)
            XCTAssertGreaterThan(
                cosine, 0.999,
                "residue \(residue) diverged from the PyTorch reference (cosine \(cosine))")
        }
        print("worst per-residue cosine against PyTorch: \(worst)")
    }

    /// The SAME sequence at two padded lengths must give the same embeddings.
    ///
    /// This is the padding-mask check on the Swift side. If the mask had been
    /// baked out at trace time, the 384-token run would attend to 306 pad
    /// tokens that the 128-token run never sees, and the two would diverge.
    ///
    /// The first version of this test appended 200 glycines instead of forcing
    /// a bucket, and failed at cosine 0.65. That was the test being wrong, not
    /// the model: 200 extra REAL residues are a different protein, and a
    /// transformer is supposed to notice. Padding has to be padding.
    func testTheSameSequenceAgreesAcrossBuckets() throws {
        let (reference, _) = try loadReference()
        let embedder = try ESMEmbedder(resources: Self.resources)
        let dimension = embedder.embeddingDimension

        let small = try embedder.embed(sequence: reference.sequence, bucket: 128)
        let large = try embedder.embed(sequence: reference.sequence, bucket: 384)
        XCTAssertEqual(small.count, large.count)

        var worst: Float = 1
        for residue in 0..<reference.residues {
            let start = residue * dimension
            var dot: Float = 0, a2: Float = 0, b2: Float = 0
            for component in 0..<dimension {
                let a = small[start + component]
                let b = large[start + component]
                dot += a * b
                a2 += a * a
                b2 += b * b
            }
            let cosine = dot / (a2.squareRoot() * b2.squareRoot())
            worst = min(worst, cosine)
            XCTAssertGreaterThan(
                cosine, 0.999,
                "residue \(residue) changed with the padding (cosine \(cosine))")
        }
        print("worst cross-bucket cosine: \(worst)")
    }

    func testAnUnknownBucketIsRejected() throws {
        let embedder = try ESMEmbedder(resources: Self.resources)
        XCTAssertThrowsError(try embedder.embed(sequence: "MQIFV", bucket: 200))
    }

    // MARK: - Disorder proxy

    /// The Swift cosine against the same arithmetic done in numpy.
    func testDisorderProxyMatchesTheReferenceCalculation() throws {
        let (reference, expected) = try loadReference()
        let centroids = try FlexibilityCentroids.load(from: Self.resources.centroidsURL)

        for residue in 0..<reference.residues {
            let start = residue * reference.dimension
            let slice = expected[start..<(start + reference.dimension)]
            XCTAssertEqual(
                centroids.rawProxy(embedding: slice), reference.rawProxy[residue],
                accuracy: 1e-4, "residue \(residue)")
        }
    }

    func testNormalisedProxyIsBounded() throws {
        let (reference, expected) = try loadReference()
        let centroids = try FlexibilityCentroids.load(from: Self.resources.centroidsURL)
        for residue in 0..<reference.residues {
            let start = residue * reference.dimension
            let value = centroids.normalisedProxy(
                embedding: expected[start..<(start + reference.dimension)])
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    func testCentroidFileValidatesItsOwnShape() throws {
        let centroids = try FlexibilityCentroids.load(from: Self.resources.centroidsURL)
        XCTAssertEqual(centroids.embeddingDimension, 320)
        XCTAssertEqual(centroids.globalMean.count, 320)
        XCTAssertEqual(centroids.model, "esm2_t6_8M_UR50D")
        XCTAssertGreaterThan(centroids.proxyPercentile95, centroids.proxyPercentile5)
    }

    // MARK: - The whole prior

    func testFlexibilityPriorFromTheRealModel() throws {
        let (reference, _) = try loadReference()
        let embedder = try ESMEmbedder(resources: Self.resources)

        // Ubiquitin as a prediction would report it: high confidence through
        // the fold, collapsing across the flexible C-terminal tail that reaches
        // into the proteasome.
        var plddt = [Float](repeating: 96, count: reference.residues)
        for index in (reference.residues - 6)..<reference.residues { plddt[index] = 45 }

        let prior = try embedder.flexibilityPrior(
            sequence: reference.sequence, plddt: plddt)

        XCTAssertEqual(prior.values.count, reference.residues)
        XCTAssertEqual(prior.blend, .confidenceAndEmbedding)
        for value in prior.values {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
        // The tail must come out as the floppiest part, which is the one thing
        // about ubiquitin's dynamics everybody already knows.
        let tail = prior.values.suffix(4).reduce(0, +) / 4
        let core = prior.values.dropLast(10).reduce(0, +) / Float(reference.residues - 10)
        XCTAssertGreaterThan(
            tail, core, "the C-terminal tail should be more flexible than the fold")
    }

    /// An experimental structure has no pLDDT, and its B-factors are not a
    /// substitute. The prior must fall back rather than inventing confidence.
    func testExperimentalStructuresFallBackToTheEmbeddingAlone() throws {
        let (reference, _) = try loadReference()
        let embedder = try ESMEmbedder(resources: Self.resources)
        let prior = try embedder.flexibilityPrior(
            sequence: reference.sequence, plddt: nil)

        XCTAssertEqual(prior.blend, .embeddingOnly)
        XCTAssertEqual(prior.values.count, reference.residues)
        XCTAssertFalse(prior.blend.caption.isEmpty)
    }

    func testMismatchedInputLengthsAreRejected() throws {
        let centroids = try FlexibilityCentroids.load(from: Self.resources.centroidsURL)
        XCTAssertThrowsError(
            try FlexibilityPrior.make(
                plddt: [90, 90], embeddings: [Float](repeating: 0, count: 320),
                centroids: centroids, residueCount: 2))
        XCTAssertThrowsError(
            try FlexibilityPrior.make(
                plddt: [90], embeddings: [Float](repeating: 0, count: 640),
                centroids: centroids, residueCount: 2))
    }

    // MARK: - Compute plan

    /// Ground rule 2 says to verify ANE dispatch rather than claim it.
    func testComputePlanReportsWhereTheModelWillRun() async throws {
        let report = await ComputePlanReport.plan(for: Self.resources.modelURL)
        print("compute plan: \(report.caption)")
        print("  total \(report.totalOperations)  ANE \(report.neuralEngineOperations)"
            + "  GPU \(report.gpuOperations)  CPU \(report.cpuOperations)")

        guard !report.isUnavailable else {
            throw XCTSkip("MLComputePlan needs macOS 14.4 or later")
        }
        XCTAssertGreaterThan(report.totalOperations, 0)
        XCTAssertEqual(
            report.neuralEngineOperations + report.gpuOperations + report.cpuOperations,
            report.totalOperations)
        XCTAssertFalse(report.caption.isEmpty)
    }
}
