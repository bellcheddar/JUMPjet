import Foundation
import JumpjetCore
import simd

/// A trajectory projected onto its two largest modes of backbone motion.
public struct DihedralProjection: Sendable {
    /// One point per frame.
    public let points: [SIMD2<Float>]
    public let sweeps: [Int]
    /// Fraction of the total variance each of the two components explains.
    public let explainedVariance: SIMD2<Float>
    /// Residues that went into the analysis.
    public let residueIndices: [Int]

    public var frameCount: Int { points.count }
}

/// Dihedral principal component analysis.
///
/// On sin and cos of phi and psi, not on the angles themselves. An angle is
/// circular: a residue oscillating about 180 degrees produces values near +180
/// and near -180, and a linear method reads that as the largest motion in the
/// protein when nothing has moved at all. Taking the sine and cosine puts the
/// angle on a circle where it belongs, at the cost of two numbers per torsion
/// instead of one.
public enum DihedralPCA {

    /// Residues whose backbone actually moves are the ones worth projecting.
    ///
    /// A structure's rigid core contributes a column of near-constants to the
    /// feature matrix, which adds nothing to the variance and a great deal to
    /// the cost. The threshold is on the circular spread of the angle, so it is
    /// immune to the same wrap problem the sin/cos encoding solves.
    public static let minimumSpreadDegrees: Float = 8

    public static func project(
        structure: Structure, trajectory: TrajectoryFrames, maximumResidues: Int = 400
    ) -> DihedralProjection? {
        guard trajectory.frameCount >= 4 else { return nil }
        let backbone = TorsionSeries.backboneTracks(
            structure: structure, trajectory: trajectory)
        guard !backbone.isEmpty else { return nil }

        // Rank by how much each residue's backbone moves, then keep the most
        // mobile. A cap, because the feature matrix is four columns per residue
        // and the whole point is the modes, not the inventory.
        let scored = backbone.map { entry -> (Int, [Float], [Float], Float) in
            (entry.residueIndex, entry.phi, entry.psi,
             max(circularSpread(entry.phi), circularSpread(entry.psi)))
        }
        let kept = scored
            .filter { $0.3 >= minimumSpreadDegrees }
            .sorted { $0.3 > $1.3 }
            .prefix(maximumResidues)
            .sorted { $0.0 < $1.0 }
        guard kept.count >= 2 else { return nil }

        let frames = trajectory.frameCount
        let featureCount = kept.count * 4
        var matrix = [Float](repeating: 0, count: frames * featureCount)
        for (column, entry) in kept.enumerated() {
            for frame in 0..<frames {
                let phi = Geometry.degreesToRadians(entry.1[frame])
                let psi = Geometry.degreesToRadians(entry.2[frame])
                let base = frame * featureCount + column * 4
                matrix[base] = cos(phi)
                matrix[base + 1] = sin(phi)
                matrix[base + 2] = cos(psi)
                matrix[base + 3] = sin(psi)
            }
        }

        // Centre each feature.
        for feature in 0..<featureCount {
            var mean: Float = 0
            for frame in 0..<frames { mean += matrix[frame * featureCount + feature] }
            mean /= Float(frames)
            for frame in 0..<frames { matrix[frame * featureCount + feature] -= mean }
        }

        // The Gram trick. There are always far fewer FRAMES than features here
        // (a 200-frame trajectory of 300 mobile residues is 200 by 1,200), and
        // the frames-by-frames Gram matrix has the same non-zero eigenvalues as
        // the enormous feature covariance. 200 by 200 against 1,200 by 1,200 is
        // thirty-six times less work for the same answer.
        var gram = [Float](repeating: 0, count: frames * frames)
        for i in 0..<frames {
            for j in i..<frames {
                var total: Float = 0
                for feature in 0..<featureCount {
                    total += matrix[i * featureCount + feature] * matrix[j * featureCount + feature]
                }
                gram[i * frames + j] = total
                gram[j * frames + i] = total
            }
        }

        var trace: Float = 0
        for index in 0..<frames { trace += gram[index * frames + index] }

        guard let first = dominantEigenvector(&gram, size: frames, deflate: true) else {
            return nil
        }
        let second = dominantEigenvector(&gram, size: frames, deflate: false)

        // The eigenvector of the Gram matrix, scaled by the square root of its
        // eigenvalue, IS the projection of the frames onto that component.
        let scaleFirst = max(first.value, 0).squareRoot()
        let scaleSecond = max(second?.value ?? 0, 0).squareRoot()
        var points = [SIMD2<Float>](repeating: .zero, count: frames)
        for frame in 0..<frames {
            points[frame] = SIMD2(
                first.vector[frame] * scaleFirst,
                (second?.vector[frame] ?? 0) * scaleSecond)
        }

        let explained = trace > 1e-9
            ? SIMD2(first.value / trace, (second?.value ?? 0) / trace)
            : SIMD2<Float>(0, 0)

        return DihedralProjection(
            points: points, sweeps: trajectory.sweeps, explainedVariance: explained,
            residueIndices: kept.map(\.0))
    }

    /// Circular standard deviation in degrees, which does not break at the wrap.
    static func circularSpread(_ degrees: [Float]) -> Float {
        guard !degrees.isEmpty else { return 0 }
        var x: Float = 0
        var y: Float = 0
        for value in degrees {
            let radians = Geometry.degreesToRadians(value)
            x += cos(radians)
            y += sin(radians)
        }
        let resultant = (x * x + y * y).squareRoot() / Float(degrees.count)
        guard resultant > 1e-6, resultant < 1 else { return resultant >= 1 ? 0 : 180 }
        return Geometry.radiansToDegrees((-2 * log(resultant)).squareRoot())
    }

    /// Power iteration, optionally deflating the matrix afterwards so the next
    /// call returns the second component.
    ///
    /// Deterministic: the starting vector is fixed rather than random, because
    /// two runs of the same analysis on the same trajectory must give the same
    /// picture, and a random start gives the same subspace with an arbitrary
    /// sign and ordering among near-degenerate modes.
    static func dominantEigenvector(
        _ matrix: inout [Float], size: Int, deflate: Bool
    ) -> (value: Float, vector: [Float])? {
        guard size > 1 else { return nil }
        var vector = (0..<size).map { Float(($0 % 7) + 1) }
        normalise(&vector)

        var value: Float = 0
        for _ in 0..<200 {
            var next = [Float](repeating: 0, count: size)
            for i in 0..<size {
                var total: Float = 0
                for j in 0..<size { total += matrix[i * size + j] * vector[j] }
                next[i] = total
            }
            let norm = length(next)
            guard norm > 1e-12 else { return nil }
            for index in 0..<size { next[index] /= norm }
            let change = zip(next, vector).map { abs($0 - $1) }.max() ?? 0
            vector = next
            value = norm
            if change < 1e-7 { break }
        }
        // Sign is arbitrary in an eigenvector, so pin it: the largest-magnitude
        // component is made positive. Without this the landscape flips left to
        // right between runs for no reason a user could understand.
        if let extreme = vector.max(by: { abs($0) < abs($1) }), extreme < 0 {
            for index in 0..<size { vector[index] = -vector[index] }
        }

        if deflate {
            for i in 0..<size {
                for j in 0..<size {
                    matrix[i * size + j] -= value * vector[i] * vector[j]
                }
            }
        }
        return (value, vector)
    }

    private static func normalise(_ vector: inout [Float]) {
        let norm = length(vector)
        guard norm > 1e-12 else { return }
        for index in vector.indices { vector[index] /= norm }
    }

    private static func length(_ vector: [Float]) -> Float {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}
