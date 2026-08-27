import Foundation
import simd

/// Geometry primitives shared by the parser, the engine and the analysis layer.
///
/// These are free functions rather than methods because they are pure maths on
/// coordinates and have no business knowing about a `Structure`.
public enum Geometry {

    /// Bond angle at `b`, in degrees, over the range 0 to 180.
    public static func angle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
    ) -> Float {
        let u = a - b
        let v = c - b
        let denominator = simd_length(u) * simd_length(v)
        guard denominator > .ulpOfOne else { return 0 }
        let cosine = simd_dot(u, v) / denominator
        return radiansToDegrees(acos(min(1, max(-1, cosine))))
    }

    /// Dihedral angle across four atoms, in degrees over the range -180 to 180,
    /// using the IUPAC sign convention.
    ///
    /// This is the single most load-bearing function in JUMPjet: chi1 wells,
    /// ring flips and the Ramachandran bias are all read off it, so it is
    /// tested against hand-computed cases rather than against itself.
    public static func dihedral(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>
    ) -> Float {
        let b1 = b - a
        let b2 = c - b
        let b3 = d - c

        let n1 = simd_cross(b1, b2)
        let n2 = simd_cross(b2, b3)
        // The cross order here IS the sign convention. `b2 x n1` gives the
        // IUPAC sign (positive when the far bond must turn clockwise, viewed
        // from b towards c); `n1 x b2` silently gives every torsion in the app
        // the wrong sign, which a self-consistent test suite would never catch.
        let m1 = simd_cross(simd_normalize(b2), n1)

        let x = simd_dot(n1, n2)
        let y = simd_dot(m1, n2)
        guard abs(x) > .ulpOfOne || abs(y) > .ulpOfOne else { return 0 }
        return radiansToDegrees(atan2(y, x))
    }

    /// Wrap an angle in degrees into -180 to 180.
    public static func wrapDegrees(_ value: Float) -> Float {
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped <= -180 { wrapped += 360 }
        return wrapped
    }

    /// The signed shortest angular separation from `from` to `to`, in degrees.
    public static func angularDifference(from: Float, to: Float) -> Float {
        wrapDegrees(to - from)
    }

    /// Angular separation treating `theta` and `theta + 180` as the same state.
    ///
    /// Aromatic ring flips need this: without it a phenylalanine that has
    /// rotated by 180 degrees reads as a large conformational change when the
    /// two structures are superimposable.
    public static func symmetricAngularDifference(from: Float, to: Float) -> Float {
        let direct = abs(wrapDegrees(to - from))
        let flipped = abs(wrapDegrees(to + 180 - from))
        return min(direct, flipped)
    }

    public static func radiansToDegrees(_ radians: Float) -> Float { radians * 180 / .pi }
    public static func degreesToRadians(_ degrees: Float) -> Float { degrees * .pi / 180 }

    /// Radius of gyration in angstroms, unweighted by mass.
    public static func radiusOfGyration(_ points: [SIMD3<Float>]) -> Float {
        guard !points.isEmpty else { return 0 }
        var centre = SIMD3<Float>.zero
        for point in points { centre += point }
        centre /= Float(points.count)
        var sum: Float = 0
        for point in points { sum += simd_length_squared(point - centre) }
        return (sum / Float(points.count)).squareRoot()
    }

    /// Root mean square deviation between two equal-length coordinate sets,
    /// without superposition. Call ``kabschSuperposition(moving:onto:)`` first
    /// if the frames are not already in a common reference.
    public static func rmsd(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        precondition(a.count == b.count, "RMSD needs matching point counts")
        guard !a.isEmpty else { return 0 }
        var sum: Float = 0
        for index in a.indices { sum += simd_length_squared(a[index] - b[index]) }
        return (sum / Float(a.count)).squareRoot()
    }

    /// The rigid-body transform that best superposes `moving` onto `reference`,
    /// by the Kabsch algorithm.
    ///
    /// Returns the rotation to apply about `moving`'s centroid and the two
    /// centroids, so a caller can transform other point sets with the same fit.
    /// Reflections are corrected, so the result is always a proper rotation.
    public static func kabschSuperposition(
        moving: [SIMD3<Float>], onto reference: [SIMD3<Float>]
    ) -> (rotation: simd_float3x3, movingCentroid: SIMD3<Float>, referenceCentroid: SIMD3<Float>) {
        precondition(moving.count == reference.count, "Kabsch needs matching point counts")
        guard !moving.isEmpty else { return (matrix_identity_float3x3, .zero, .zero) }

        var movingCentre = SIMD3<Float>.zero
        var referenceCentre = SIMD3<Float>.zero
        for index in moving.indices {
            movingCentre += moving[index]
            referenceCentre += reference[index]
        }
        movingCentre /= Float(moving.count)
        referenceCentre /= Float(moving.count)

        // Covariance matrix in double precision: the SVD of a nearly singular
        // 3x3 is where a Float pipeline loses its accuracy, and this runs once
        // per frame rather than once per atom pair.
        var covariance = simd_double3x3()
        for index in moving.indices {
            let p = SIMD3<Double>(moving[index] - movingCentre)
            let q = SIMD3<Double>(reference[index] - referenceCentre)
            covariance.columns.0 += p * q.x
            covariance.columns.1 += p * q.y
            covariance.columns.2 += p * q.z
        }

        let rotation = Self.rotationFromCovariance(covariance)
        // simd has no double-to-float matrix conversion; narrow column by column.
        let narrowed = simd_float3x3(
            SIMD3<Float>(rotation[0]), SIMD3<Float>(rotation[1]), SIMD3<Float>(rotation[2]))
        return (narrowed, movingCentre, referenceCentre)
    }

    /// RMSD after optimal superposition.
    public static func superposedRMSD(
        moving: [SIMD3<Float>], onto reference: [SIMD3<Float>]
    ) -> Float {
        let fit = kabschSuperposition(moving: moving, onto: reference)
        let transformed = moving.map { fit.rotation * ($0 - fit.movingCentroid) + fit.referenceCentroid }
        return rmsd(transformed, reference)
    }

    /// Apply a superposition to an arbitrary point set.
    public static func apply(
        _ fit: (rotation: simd_float3x3, movingCentroid: SIMD3<Float>, referenceCentroid: SIMD3<Float>),
        to points: [SIMD3<Float>]
    ) -> [SIMD3<Float>] {
        points.map { fit.rotation * ($0 - fit.movingCentroid) + fit.referenceCentroid }
    }

    // MARK: - Private

    /// The proper rotation maximising trace(R * covariance), found by one-sided
    /// Jacobi eigen-decomposition of `covariance^T * covariance`.
    ///
    /// Apple's LAPACK is not available to a package that must also build for
    /// iOS without linking Accelerate's Fortran surface, so the 3x3 case is
    /// solved directly. Three sweeps converge a 3x3 to machine precision.
    private static func rotationFromCovariance(_ covariance: simd_double3x3) -> simd_double3x3 {
        var u = covariance
        var v = simd_double3x3(diagonal: SIMD3(1, 1, 1))

        for _ in 0..<12 {
            var offDiagonal = 0.0
            for p in 0..<2 {
                for q in (p + 1)..<3 {
                    let alpha = simd_length_squared(u[p])
                    let beta = simd_length_squared(u[q])
                    let gamma = simd_dot(u[p], u[q])
                    offDiagonal += abs(gamma)
                    guard abs(gamma) > 1e-15 else { continue }

                    let zeta = (beta - alpha) / (2 * gamma)
                    let t = (zeta >= 0 ? 1.0 : -1.0) / (abs(zeta) + (1 + zeta * zeta).squareRoot())
                    let c = 1 / (1 + t * t).squareRoot()
                    let s = c * t

                    let up = u[p]
                    let uq = u[q]
                    u[p] = c * up - s * uq
                    u[q] = s * up + c * uq

                    let vp = v[p]
                    let vq = v[q]
                    v[p] = c * vp - s * vq
                    v[q] = s * vp + c * vq
                }
            }
            if offDiagonal < 1e-14 { break }
        }

        // Columns of u are now orthogonal; their norms are the singular
        // values. Jacobi does not sort them, and both the degeneracy test and
        // the reflection fix below need the SMALLEST one, so sort first: doing
        // the fix on a fixed index quietly corrupts the rotation whenever the
        // smallest singular value did not land in column 2.
        var order = [0, 1, 2]
        let norms = SIMD3<Double>(
            simd_length(u[0]), simd_length(u[1]), simd_length(u[2]))
        order.sort { norms[$0] > norms[$1] }

        var singularValues = SIMD3<Double>.zero
        var left = simd_double3x3()
        var right = simd_double3x3()
        for column in 0..<3 {
            let source = order[column]
            singularValues[column] = norms[source]
            right[column] = v[source]
            left[column] = norms[source] > 1e-12 ? u[source] / norms[source] : .zero
        }

        // Rank deficiency leaves the left columns for the vanishing singular
        // values UNDETERMINED, and Jacobi returns zero vectors for them. Three
        // collinear atoms make the covariance rank 1, so two columns arrive
        // empty; substituting fixed basis vectors (the obvious fix) destroys
        // orthonormality and yields a "rotation" with determinant 0 that maps
        // the points nowhere near each other. Complete the basis instead.
        //
        // `right` needs no such repair: it is a product of Givens rotations
        // starting from the identity, so it is orthonormal with determinant +1
        // whatever the rank of the input.
        if singularValues[0] <= 1e-12 {
            // No structure at all: every point sits on the centroid.
            return simd_double3x3(diagonal: SIMD3(1, 1, 1))
        }
        if singularValues[1] <= 1e-12 {
            left[1] = Self.anyUnitVectorOrthogonal(to: left[0])
        }
        if singularValues[2] <= 1e-12 {
            // Completing right-handedly forces determinant +1, which is what
            // makes the degenerate fit a proper rotation rather than a
            // reflection. The correction below is then a no-op, correctly.
            left[2] = simd_cross(left[0], left[1])
        }

        var rotation = right * left.transpose
        if rotation.determinant < 0 {
            // A reflection fits the points better than any rotation. Flip the
            // least significant direction, which is now column 2 by sorting.
            right[2] = -right[2]
            rotation = right * left.transpose
        }
        return rotation
    }

    /// An arbitrary unit vector perpendicular to `vector`, chosen from the axis
    /// the vector leans on least so the cross product never underflows.
    private static func anyUnitVectorOrthogonal(to vector: SIMD3<Double>) -> SIMD3<Double> {
        let magnitudes = SIMD3<Double>(abs(vector.x), abs(vector.y), abs(vector.z))
        let smallest = magnitudes.x <= magnitudes.y
            ? (magnitudes.x <= magnitudes.z ? 0 : 2)
            : (magnitudes.y <= magnitudes.z ? 1 : 2)
        var axis = SIMD3<Double>.zero
        axis[smallest] = 1
        return simd_normalize(simd_cross(vector, axis))
    }
}
