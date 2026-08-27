import XCTest
import JumpjetCore
import simd

@testable import JumpjetViewer

final class TubeMeshTests: XCTestCase {

    // MARK: - Spline

    /// Catmull-Rom passes THROUGH its control points. A backbone that misses
    /// its own alpha carbons is a backbone the user cannot click on.
    func testInterpolationPassesThroughEveryControlPoint() {
        let controls: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(3.8, 1, 0), SIMD3(7.0, -1, 2), SIMD3(11, 0.5, 1),
        ]
        let path = TubeBuilder.interpolate(controls, segmentsPerSpan: 5)

        for (index, control) in controls.enumerated() {
            let sample = path[min(index * 5, path.count - 1)]
            XCTAssertEqual(simd_distance(sample, control), 0, accuracy: 1e-4)
        }
    }

    func testInterpolationProducesTheExpectedPointCount() {
        let controls = (0..<10).map { SIMD3<Float>(Float($0), 0, 0) }
        XCTAssertEqual(TubeBuilder.interpolate(controls, segmentsPerSpan: 4).count, 9 * 4 + 1)
        XCTAssertEqual(TubeBuilder.interpolate(controls, segmentsPerSpan: 1).count, 10)
    }

    func testDegenerateInputsAreReturnedUnchanged() {
        XCTAssertEqual(TubeBuilder.interpolate([], segmentsPerSpan: 4).count, 0)
        XCTAssertEqual(TubeBuilder.interpolate([SIMD3(1, 2, 3)], segmentsPerSpan: 4).count, 1)
    }

    /// A straight line must interpolate to a straight line: an overshooting
    /// spline puts kinks in every extended beta strand.
    func testAStraightRunStaysStraight() {
        let controls = (0..<6).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        for point in TubeBuilder.interpolate(controls, segmentsPerSpan: 8) {
            XCTAssertEqual(point.y, 0, accuracy: 1e-5)
            XCTAssertEqual(point.z, 0, accuracy: 1e-5)
        }
    }

    // MARK: - Sweep

    func testSweepProducesConsistentArrayLengths() {
        let path = (0..<20).map { SIMD3<Float>(Float($0), 0, 0) }
        let mesh = TubeBuilder.sweep(
            path: path, colours: [SIMD3(1, 0, 0)], radius: 0.5, sides: 8)

        XCTAssertEqual(mesh.positions.count, 20 * 8)
        XCTAssertEqual(mesh.normals.count, mesh.positions.count)
        XCTAssertEqual(mesh.colours.count, mesh.positions.count)
        XCTAssertEqual(mesh.indices.count, 19 * 8 * 6)
        XCTAssertEqual(mesh.triangleCount, 19 * 8 * 2)
    }

    func testEveryIndexAddressesARealVertex() {
        let path = (0..<12).map { SIMD3<Float>(Float($0), sin(Float($0)), cos(Float($0))) }
        let mesh = TubeBuilder.sweep(path: path, colours: [], radius: 0.4, sides: 7)
        for index in mesh.indices {
            XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertLessThan(Int(index), mesh.vertexCount)
        }
    }

    /// Every vertex sits exactly `radius` from the path point it belongs to,
    /// and its normal points outwards from that point. A normal pointing inwards
    /// renders as a black tube that looks like a lighting problem.
    func testVerticesSitOnTheTubeAndNormalsPointOutwards() {
        let path = (0..<15).map { SIMD3<Float>(Float($0), Float($0) * 0.3, sin(Float($0) * 0.5)) }
        let sides = 9
        let radius: Float = 0.42
        let mesh = TubeBuilder.sweep(path: path, colours: [], radius: radius, sides: sides)

        for ring in path.indices {
            for side in 0..<sides {
                let vertex = mesh.positions[ring * sides + side]
                let normal = mesh.normals[ring * sides + side]
                XCTAssertEqual(simd_distance(vertex, path[ring]), radius, accuracy: 1e-4)
                XCTAssertEqual(simd_length(normal), 1, accuracy: 1e-4)
                XCTAssertGreaterThan(simd_dot(normal, vertex - path[ring]), 0)
            }
        }
    }

    /// Parallel transport must not let the cross-section spin about the path.
    ///
    /// A frame rebuilt from a fixed up-vector at each point corkscrews wherever
    /// the path turns towards that vector, which on a helix is a visible twist
    /// that is not in the protein. Along a straight path the frame must not
    /// rotate at all.
    func testTheCrossSectionDoesNotTwistAlongAStraightPath() {
        let path = (0..<30).map { SIMD3<Float>(0, 0, Float($0)) }
        let sides = 8
        let mesh = TubeBuilder.sweep(path: path, colours: [], radius: 1, sides: sides)

        let first = mesh.normals[0]
        for ring in path.indices {
            let normal = mesh.normals[ring * sides]
            XCTAssertEqual(simd_dot(normal, first), 1, accuracy: 1e-3, "ring \(ring) has twisted")
        }
    }

    /// A helix is the case a fixed up-vector gets wrong. The frame must rotate
    /// smoothly with no sudden flip: consecutive rings agreeing to within a few
    /// degrees is what "smooth" means here.
    func testTheFrameTurnsSmoothlyAroundAHelix() {
        let path = (0..<120).map { step -> SIMD3<Float> in
            let t = Float(step) * 0.15
            return SIMD3(cos(t) * 5, sin(t) * 5, t * 1.5)
        }
        let sides = 8
        let mesh = TubeBuilder.sweep(path: path, colours: [], radius: 0.4, sides: sides)

        for ring in 1..<path.count {
            let previous = mesh.normals[(ring - 1) * sides]
            let current = mesh.normals[ring * sides]
            let cosine = simd_dot(previous, current)
            XCTAssertGreaterThan(cosine, 0.97, "the frame flipped between rings \(ring - 1) and \(ring)")
        }
    }

    func testTooFewSidesOrPointsYieldsAnEmptyMesh() {
        XCTAssertTrue(TubeBuilder.sweep(path: [SIMD3(0, 0, 0)], colours: [], radius: 1, sides: 8).isEmpty)
        XCTAssertTrue(
            TubeBuilder.sweep(
                path: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)], colours: [], radius: 1, sides: 2
            ).isEmpty)
    }

    /// Two identical consecutive points give a zero-length tangent. The sweep
    /// must carry on rather than emitting NaN positions, which render as
    /// nothing at all and look like a missing chain.
    func testRepeatedPathPointsDoNotProduceNaNs() {
        let path: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0),
        ]
        let mesh = TubeBuilder.sweep(path: path, colours: [], radius: 0.5, sides: 6)
        XCTAssertFalse(mesh.isEmpty)
        for position in mesh.positions { XCTAssertTrue(position.x.isFinite && position.y.isFinite) }
        for normal in mesh.normals { XCTAssertTrue(simd_length(normal).isFinite) }
    }

    /// Colour bands must stay sharp. Blending a pLDDT scale into invented
    /// intermediate colours would show confidence values the model never had.
    func testColourSamplingKeepsDiscreteBandsSharp() {
        let controls: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let sampled = TubeBuilder.interpolateColours(
            controls, segmentsPerSpan: 4, total: 9)
        XCTAssertEqual(sampled.count, 9)
        for colour in sampled {
            XCTAssertTrue(controls.contains(colour), "an intermediate colour was invented")
        }
    }
}
