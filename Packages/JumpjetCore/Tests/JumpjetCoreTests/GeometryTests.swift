import XCTest
import simd

@testable import JumpjetCore

final class GeometryTests: XCTestCase {

    // MARK: - Dihedral

    /// Four atoms placed so the answer is known by construction, not by running
    /// the function and writing down what it said.
    ///
    /// With the central bond b-c along +x, `a` fixed at +y off `b`, and `d`
    /// swung about that bond by theta, the IUPAC torsion IS theta. Getting the
    /// sign wrong here would flip every chi1 well in the app from g- to g+, and
    /// a suite that only checked self-consistency would pass regardless.
    func testDihedralMatchesConstructedAngle() {
        let a = SIMD3<Float>(0, 1, 0)
        let b = SIMD3<Float>(0, 0, 0)
        let c = SIMD3<Float>(1, 0, 0)

        for theta in stride(from: Float(-170), through: 170, by: 10) {
            let radians = Geometry.degreesToRadians(theta)
            let d = SIMD3<Float>(1, cos(radians), sin(radians))
            XCTAssertEqual(
                Geometry.dihedral(a, b, c, d), theta, accuracy: 1e-3,
                "dihedral disagreed at theta = \(theta)")
        }
    }

    /// Cis is zero and trans is 180, with the magnitude of 180 rather than its
    /// sign being what matters at the wrap point.
    func testDihedralCisAndTrans() {
        let a = SIMD3<Float>(0, 1, 0)
        let b = SIMD3<Float>(0, 0, 0)
        let c = SIMD3<Float>(1, 0, 0)

        XCTAssertEqual(Geometry.dihedral(a, b, c, SIMD3(1, 1, 0)), 0, accuracy: 1e-4)
        XCTAssertEqual(abs(Geometry.dihedral(a, b, c, SIMD3(1, -1, 0))), 180, accuracy: 1e-3)
    }

    /// A torsion is INVARIANT under reversing the atom order, not negated:
    /// d-c-b-a describes the same twist about the same central bond viewed from
    /// the other end. Asserting antisymmetry here (the intuitive guess) fails
    /// against a correct implementation.
    func testDihedralIsInvariantUnderReversal() {
        let a = SIMD3<Float>(0.7, 1.2, -0.3)
        let b = SIMD3<Float>(0, 0, 0)
        let c = SIMD3<Float>(1.5, 0.1, 0.2)
        let d = SIMD3<Float>(2.0, 1.1, 1.4)

        XCTAssertEqual(
            Geometry.dihedral(a, b, c, d), Geometry.dihedral(d, c, b, a), accuracy: 1e-3)
    }

    /// Four collinear atoms have no defined torsion plane. The function must
    /// return a finite number rather than a NaN that poisons an energy sum.
    func testDihedralOfCollinearAtomsIsFinite() {
        let value = Geometry.dihedral(
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3, 0, 0))
        XCTAssertTrue(value.isFinite)
    }

    // MARK: - Angles

    func testBondAngleOfARightAngle() {
        let value = Geometry.angle(SIMD3(1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1, 0))
        XCTAssertEqual(value, 90, accuracy: 1e-4)
    }

    func testWrapDegrees() {
        XCTAssertEqual(Geometry.wrapDegrees(190), -170, accuracy: 1e-4)
        XCTAssertEqual(Geometry.wrapDegrees(-190), 170, accuracy: 1e-4)
        XCTAssertEqual(Geometry.wrapDegrees(540), 180, accuracy: 1e-4)
        XCTAssertEqual(Geometry.wrapDegrees(45), 45, accuracy: 1e-4)
    }

    func testAngularDifferenceTakesTheShortWayRound() {
        XCTAssertEqual(Geometry.angularDifference(from: 170, to: -170), 20, accuracy: 1e-4)
        XCTAssertEqual(Geometry.angularDifference(from: -170, to: 170), -20, accuracy: 1e-4)
    }

    /// A phenylalanine ring rotated by 180 degrees is the same structure, so a
    /// symmetry-aware comparison must report no change at all.
    func testSymmetricAngularDifferenceIgnoresRingFlips() {
        XCTAssertEqual(Geometry.symmetricAngularDifference(from: 60, to: -120), 0, accuracy: 1e-4)
        XCTAssertEqual(Geometry.symmetricAngularDifference(from: 60, to: 90), 30, accuracy: 1e-4)
        XCTAssertEqual(Geometry.symmetricAngularDifference(from: 10, to: 175), 15, accuracy: 1e-4)
    }

    // MARK: - Kabsch

    /// A rigid rotation and translation must superpose to zero RMSD.
    func testKabschRecoversARigidTransform() {
        let points = Self.scatter(count: 40, seed: 7)
        let rotation = Self.rotation(axis: simd_normalize(SIMD3<Float>(0.3, 1, -0.4)), degrees: 47)
        let translation = SIMD3<Float>(12, -3, 5)
        let moved = points.map { rotation * $0 + translation }

        XCTAssertEqual(Geometry.superposedRMSD(moving: moved, onto: points), 0, accuracy: 1e-3)
    }

    /// A mirror image is NOT superposable by a rotation. If the reflection
    /// correction were missing, this would come back as a perfect fit and the
    /// app would happily report a D-amino-acid protein as unchanged.
    func testKabschRefusesToFitAReflection() {
        let points = Self.scatter(count: 40, seed: 11)
        let mirrored = points.map { SIMD3<Float>(-$0.x, $0.y, $0.z) }

        XCTAssertGreaterThan(Geometry.superposedRMSD(moving: mirrored, onto: points), 1)
    }

    /// A known displacement of exactly one atom gives an RMSD we can write down:
    /// sqrt(d^2 / n).
    func testRMSDOfASingleDisplacement() {
        var a = Self.scatter(count: 9, seed: 3)
        let b = a
        a[4] += SIMD3<Float>(3, 0, 0)
        XCTAssertEqual(Geometry.rmsd(a, b), (9.0 / 9.0 as Float).squareRoot(), accuracy: 1e-5)
    }

    /// Three points on a line have a degenerate covariance matrix. The fit must
    /// still be a proper rotation rather than a NaN or a reflection.
    func testKabschHandlesCollinearPoints() {
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        let rotation = Self.rotation(axis: SIMD3(0, 0, 1), degrees: 90)
        let moved = points.map { rotation * $0 }

        let fit = Geometry.kabschSuperposition(moving: moved, onto: points)
        XCTAssertEqual(fit.rotation.determinant, 1, accuracy: 1e-3)
        XCTAssertEqual(Geometry.superposedRMSD(moving: moved, onto: points), 0, accuracy: 1e-3)
    }

    /// Radius of gyration of a cube's eight corners at +/-1 is sqrt(3).
    func testRadiusOfGyrationOfACube() {
        var corners: [SIMD3<Float>] = []
        for x in [Float(-1), 1] {
            for y in [Float(-1), 1] {
                for z in [Float(-1), 1] { corners.append(SIMD3(x, y, z)) }
            }
        }
        XCTAssertEqual(Geometry.radiusOfGyration(corners), Float(3).squareRoot(), accuracy: 1e-5)
    }

    // MARK: - Helpers

    /// A deterministic pseudo-random point cloud. Tests must be reproducible,
    /// so this is a fixed linear congruential sequence rather than `random(in:)`.
    private static func scatter(count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) * 20 - 10
        }
        return (0..<count).map { _ in SIMD3(next(), next(), next()) }
    }

    private static func rotation(axis: SIMD3<Float>, degrees: Float) -> simd_float3x3 {
        simd_float3x3(simd_quatf(angle: Geometry.degreesToRadians(degrees), axis: axis))
    }
}
