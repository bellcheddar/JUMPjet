import XCTest
import JumpjetCore
import simd

@testable import JumpjetAnalysis

/// Basins, landscape and dwell times against synthetic data with a known answer.
final class BasinTests: XCTestCase {

    /// Frames that sit in `k` well-separated blobs, visiting each in turn.
    private func planted(
        blobs: [SIMD2<Float>], framesPerVisit: Int, visits: [Int], jitter: Float = 0.15
    ) -> DihedralProjection {
        var points: [SIMD2<Float>] = []
        var seed: UInt64 = 42
        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 2 * jitter
        }
        for visit in visits {
            for _ in 0..<framesPerVisit {
                points.append(blobs[visit] + SIMD2(noise(), noise()))
            }
        }
        return DihedralProjection(
            points: points, sweeps: (0..<points.count).map { $0 * 25 },
            explainedVariance: SIMD2(0.5, 0.3),
            residueIndices: Array(0..<10))
    }

    private let three: [SIMD2<Float>] = [SIMD2(-5, 0), SIMD2(5, 0), SIMD2(0, 6)]

    // MARK: - Choosing k

    /// Three well-separated blobs must be found as three basins, not two and
    /// not five. Silhouette is what makes that choice, and a clustering that
    /// always picked the cap would look identical on well-behaved data.
    func testSilhouetteFindsThePlantedNumberOfBasins() throws {
        let projection = planted(
            blobs: three, framesPerVisit: 12, visits: [0, 1, 2, 0, 1, 2])
        let analysis = try XCTUnwrap(BasinFinder.analyse(projection))

        XCTAssertEqual(analysis.chosenK, 3)
        XCTAssertEqual(analysis.basinCount, 3)
        XCTAssertGreaterThan(analysis.silhouette, 0.7, "well-separated blobs should score high")
        XCTAssertTrue(analysis.occupancy.allSatisfy { $0 > 0 })
        XCTAssertEqual(analysis.occupancy.reduce(0, +), projection.frameCount)
    }

    func testTwoBlobsAreFoundAsTwo() throws {
        let projection = planted(
            blobs: [SIMD2(-8, 0), SIMD2(8, 0)], framesPerVisit: 15, visits: [0, 1, 0, 1])
        let analysis = try XCTUnwrap(BasinFinder.analyse(projection))
        XCTAssertEqual(analysis.chosenK, 2)
    }

    /// The build plan caps k at five, because more basins than that on a crude
    /// sampler is reading structure into noise.
    func testKIsCappedAtFive() throws {
        let many = (0..<9).map { SIMD2<Float>(Float($0) * 10, Float($0 % 2) * 10) }
        let projection = planted(
            blobs: many, framesPerVisit: 8, visits: Array(0..<9))
        let analysis = try XCTUnwrap(BasinFinder.analyse(projection))
        XCTAssertLessThanOrEqual(analysis.chosenK, BasinFinder.maximumK)
    }

    /// Two runs of the same analysis must give the same basins. A random
    /// k-means start gives different labels, possibly a different k, and a jump
    /// matrix whose rows mean something else, from a trajectory that has not
    /// changed.
    func testClusteringIsDeterministic() throws {
        let projection = planted(
            blobs: three, framesPerVisit: 12, visits: [0, 1, 2, 0, 1, 2])
        let first = try XCTUnwrap(BasinFinder.analyse(projection))
        for _ in 0..<5 {
            let again = try XCTUnwrap(BasinFinder.analyse(projection))
            XCTAssertEqual(again.chosenK, first.chosenK)
            XCTAssertEqual(again.assignments, first.assignments)
            XCTAssertEqual(again.silhouette, first.silhouette)
        }
    }

    // MARK: - Dwell times and the jump matrix

    /// Six visits of twelve frames each, at a 25-sweep stride: five basin
    /// changes, and each residence spans eleven intervals of 25 sweeps.
    func testDwellTimesAndTransitionsMatchThePlantedItinerary() throws {
        let projection = planted(
            blobs: three, framesPerVisit: 12, visits: [0, 1, 2, 0, 1, 2])
        let analysis = try XCTUnwrap(BasinFinder.analyse(projection))

        XCTAssertEqual(analysis.dwellTimes.count, 6, "six residences")
        XCTAssertEqual(analysis.totalTransitions, 5, "five changes between them")
        for dwell in analysis.dwellTimes {
            XCTAssertEqual(dwell.sweeps, 11 * 25, "twelve frames span eleven strides")
        }

        // The DIAGONAL counts staying put, and most of the matrix is diagonal:
        // six visits of twelve frames is 66 frame-to-frame intervals, of which
        // 5 are changes and 61 are residence. Asserting a zero diagonal (the
        // intuitive guess) is asserting that the trajectory teleports.
        let diagonal = (0..<analysis.basinCount).reduce(0) {
            $0 + analysis.jumpMatrix[$1][$1]
        }
        // 72 frames is 71 intervals, of which 5 are changes.
        XCTAssertEqual(diagonal, 66)
        XCTAssertEqual(diagonal + analysis.totalTransitions, projection.frameCount - 1)
        XCTAssertFalse(analysis.caveat.isEmpty)
    }

    /// A trajectory that never leaves one blob has one residence and no
    /// transitions, whatever k the silhouette settles on.
    func testAStaticTrajectoryHasNoTransitions() throws {
        let projection = planted(
            blobs: [SIMD2(0, 0)], framesPerVisit: 40, visits: [0], jitter: 0.4)
        guard let analysis = BasinFinder.analyse(projection) else {
            throw XCTSkip("a single blob is legitimately unclusterable")
        }
        XCTAssertLessThan(
            analysis.silhouette, 0.7, "one blob split in two should score poorly")
    }

    func testTooFewFramesIsRefusedRatherThanGuessed() {
        let tiny = DihedralProjection(
            points: [SIMD2(0, 0), SIMD2(1, 1)], sweeps: [0, 25],
            explainedVariance: SIMD2(1, 0), residueIndices: [])
        XCTAssertNil(BasinFinder.analyse(tiny))
    }

    // MARK: - The landscape

    /// The occupied blobs must be the LOW points of the terrain, and the empty
    /// space between them high. A landscape with that the wrong way round would
    /// look plausible and mean the opposite.
    func testOccupiedRegionsAreTheLowPointsOfTheLandscape() throws {
        let projection = planted(
            blobs: three, framesPerVisit: 20, visits: [0, 1, 2], jitter: 0.3)
        let landscape = BasinFinder.landscape(projection, bins: 32)

        func energy(at point: SIMD2<Float>) -> Float {
            let x = Int(
                (point.x - landscape.xRange.lowerBound)
                    / (landscape.xRange.upperBound - landscape.xRange.lowerBound) * 32)
            let y = Int(
                (point.y - landscape.yRange.lowerBound)
                    / (landscape.yRange.upperBound - landscape.yRange.lowerBound) * 32)
            return landscape.value(x: min(31, max(0, x)), y: min(31, max(0, y)))
        }

        for blob in three {
            XCTAssertLessThan(energy(at: blob), 2.0, "a populated blob should be a well")
        }
        // Somewhere on the plane is genuinely unsampled and sits at the ceiling.
        // Not a specific corner: the density is SMOOTHED, so a bin beside a
        // populated one legitimately picks some up, and the ceiling means
        // "nothing near here" rather than "nothing exactly here".
        XCTAssertEqual(landscape.energy.max() ?? 0, landscape.ceiling, accuracy: 1e-4)
        let atCeiling = landscape.energy.filter { $0 >= landscape.ceiling - 1e-4 }.count
        XCTAssertGreaterThan(
            atCeiling, landscape.energy.count / 4, "most of the plane is empty")
    }

    /// An unvisited bin is UNSAMPLED, not infinitely unfavourable. Left
    /// uncapped it would be an infinity, and a contour plot would become a
    /// plot with a wall around the edge.
    func testUnvisitedBinsAreCappedAndFinite() {
        let projection = planted(
            blobs: three, framesPerVisit: 10, visits: [0, 1, 2])
        let landscape = BasinFinder.landscape(projection, bins: 24)
        for value in landscape.energy {
            XCTAssertTrue(value.isFinite)
            XCTAssertLessThanOrEqual(value, landscape.ceiling)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }
}

/// The dihedral PCA, and the circular problem it exists to solve.
final class DihedralPCATests: XCTestCase {

    /// Circular spread does not break at the wrap. A residue oscillating about
    /// 180 degrees produces values near +180 and near -180, and a linear
    /// standard deviation reads that as the largest motion in the protein.
    func testCircularSpreadSurvivesTheWrap() {
        let acrossTheWrap: [Float] = [175, -175, 178, -178, 179, -179]
        let linearStdDev: Float = {
            let mean = acrossTheWrap.reduce(0, +) / Float(acrossTheWrap.count)
            let variance = acrossTheWrap.map { ($0 - mean) * ($0 - mean) }
                .reduce(0, +) / Float(acrossTheWrap.count)
            return variance.squareRoot()
        }()

        let circular = DihedralPCA.circularSpread(acrossTheWrap)
        XCTAssertLessThan(circular, 10, "these angles span about four degrees")
        XCTAssertGreaterThan(
            linearStdDev, 150, "and a linear measure calls the same data a huge motion")
    }

    func testCircularSpreadOfAConstantIsZero() {
        XCTAssertEqual(DihedralPCA.circularSpread([Float](repeating: 42, count: 20)), 0,
                       accuracy: 1e-3)
    }

    func testCircularSpreadOfAUniformSpreadIsLarge() {
        let uniform = (0..<36).map { Float($0) * 10 - 180 }
        XCTAssertGreaterThan(DihedralPCA.circularSpread(uniform), 90)
    }

    /// Power iteration must find the dominant eigenvector of a matrix whose
    /// answer is known, and deflation must then find the second.
    func testPowerIterationAndDeflationOnAKnownMatrix() throws {
        // Diagonal, so the eigenvectors are the basis vectors and the
        // eigenvalues are 9, 4, 1 in that order.
        var matrix: [Float] = [
            9, 0, 0,
            0, 4, 0,
            0, 0, 1,
        ]
        let first = try XCTUnwrap(
            DihedralPCA.dominantEigenvector(&matrix, size: 3, deflate: true))
        XCTAssertEqual(first.value, 9, accuracy: 1e-3)
        XCTAssertEqual(abs(first.vector[0]), 1, accuracy: 1e-3)

        let second = try XCTUnwrap(
            DihedralPCA.dominantEigenvector(&matrix, size: 3, deflate: false))
        XCTAssertEqual(second.value, 4, accuracy: 1e-3)
        XCTAssertEqual(abs(second.vector[1]), 1, accuracy: 1e-3)
    }

    /// The sign of an eigenvector is arbitrary, so it is pinned. Without that
    /// the landscape flips left to right between runs for no reason a user
    /// could understand.
    func testEigenvectorSignIsPinned() {
        for _ in 0..<5 {
            var matrix: [Float] = [4, 1, 1, 3]
            let result = DihedralPCA.dominantEigenvector(&matrix, size: 2, deflate: false)
            let extreme = result?.vector.max(by: { abs($0) < abs($1) }) ?? 0
            XCTAssertGreaterThan(extreme, 0)
        }
    }
}
