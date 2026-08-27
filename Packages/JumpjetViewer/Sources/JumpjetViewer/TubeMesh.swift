import Foundation
import JumpjetCore
import simd

/// A triangulated tube swept along a path, with per-vertex colours.
///
/// Generated as plain arrays rather than straight into SceneKit so the geometry
/// can be checked without a renderer: a tube that self-intersects, twists or
/// has inward-facing normals looks like a lighting bug and is a maths bug.
public struct TubeMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var colours: [SIMD3<Float>]
    /// Triangle indices, three per triangle.
    public var indices: [Int32]

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }

    public init(
        positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [],
        colours: [SIMD3<Float>] = [], indices: [Int32] = []
    ) {
        self.positions = positions
        self.normals = normals
        self.colours = colours
        self.indices = indices
    }

    public var isEmpty: Bool { positions.isEmpty }

    /// Shift every vertex. Normals are directions and are left alone.
    public mutating func translate(by offset: SIMD3<Float>) {
        for index in positions.indices { positions[index] += offset }
    }
}

/// Builds a smooth tube through a backbone trace.
public enum TubeBuilder {

    /// Catmull-Rom interpolation through the control points.
    ///
    /// Catmull-Rom rather than a B-spline because it passes THROUGH its control
    /// points: a backbone that misses its own alpha carbons is a backbone the
    /// user cannot click on.
    public static func interpolate(
        _ controls: [SIMD3<Float>], segmentsPerSpan: Int
    ) -> [SIMD3<Float>] {
        guard controls.count >= 2, segmentsPerSpan >= 1 else { return controls }

        var output: [SIMD3<Float>] = []
        output.reserveCapacity((controls.count - 1) * segmentsPerSpan + 1)

        for span in 0..<(controls.count - 1) {
            // The ends have no neighbour to borrow a tangent from, so they
            // reflect their own segment. Clamping to the endpoint instead
            // flattens the first and last turns of every helix.
            let p0 = controls[max(0, span - 1)]
            let p1 = controls[span]
            let p2 = controls[span + 1]
            let p3 = controls[min(controls.count - 1, span + 2)]

            for step in 0..<segmentsPerSpan {
                let t = Float(step) / Float(segmentsPerSpan)
                output.append(catmullRom(p0, p1, p2, p3, t))
            }
        }
        output.append(controls[controls.count - 1])
        return output
    }

    static func catmullRom(
        _ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float
    ) -> SIMD3<Float> {
        // Written as four explicitly typed basis terms. As one expression the
        // type checker gives up on it: every literal and every operator is
        // overloaded across SIMD3 and its scalar.
        let t2: Float = t * t
        let t3: Float = t2 * t
        let a: SIMD3<Float> = 2 * p1
        let b: SIMD3<Float> = (p2 - p0) * t
        let c: SIMD3<Float> = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        let d: SIMD3<Float> = (3 * p1 - 3 * p2 + p3 - p0) * t3
        return (a + b + c + d) * 0.5
    }

    /// Sweep a circular cross-section along a path.
    ///
    /// The cross-section frame is carried forward by parallel transport rather
    /// than rebuilt from a fixed up-vector at each point. Rebuilding it makes
    /// the tube spin about its own axis wherever the path turns towards the up
    /// vector, and on a helix that is a visible corkscrew that is not in the
    /// protein.
    public static func sweep(
        path: [SIMD3<Float>], colours: [SIMD3<Float>], radius: Float, sides: Int
    ) -> TubeMesh {
        guard path.count >= 2, sides >= 3 else { return TubeMesh() }

        var mesh = TubeMesh()
        let ringCount = path.count
        mesh.positions.reserveCapacity(ringCount * sides)
        mesh.normals.reserveCapacity(ringCount * sides)
        mesh.colours.reserveCapacity(ringCount * sides)

        var previousTangent = safeNormalize(path[1] - path[0]) ?? SIMD3(0, 0, 1)
        var reference = anyPerpendicular(to: previousTangent)

        for index in path.indices {
            let tangent: SIMD3<Float>
            if index == 0 {
                tangent = safeNormalize(path[1] - path[0]) ?? previousTangent
            } else if index == path.count - 1 {
                tangent = safeNormalize(path[index] - path[index - 1]) ?? previousTangent
            } else {
                tangent = safeNormalize(path[index + 1] - path[index - 1]) ?? previousTangent
            }

            // Rotate the reference vector by the same rotation that takes the
            // previous tangent to this one. That is what parallel transport is.
            let axis = simd_cross(previousTangent, tangent)
            let sine = simd_length(axis)
            if sine > 1e-6 {
                let angle = atan2(sine, simd_dot(previousTangent, tangent))
                let rotation = simd_quatf(angle: angle, axis: axis / sine)
                reference = rotation.act(reference)
            }
            // Re-orthogonalise: a thousand small rotations accumulate enough
            // drift to visibly pinch the tube by the end of a long chain.
            reference = safeNormalize(reference - tangent * simd_dot(reference, tangent))
                ?? anyPerpendicular(to: tangent)
            previousTangent = tangent

            let bitangent = simd_cross(tangent, reference)
            let colour = colours.isEmpty
                ? SIMD3<Float>(1, 1, 1)
                : colours[min(colours.count - 1, index * colours.count / max(1, ringCount))]

            for side in 0..<sides {
                let angle = Float(side) / Float(sides) * 2 * .pi
                let normal = reference * cos(angle) + bitangent * sin(angle)
                mesh.positions.append(path[index] + normal * radius)
                mesh.normals.append(normal)
                mesh.colours.append(colour)
            }
        }

        mesh.indices.reserveCapacity((ringCount - 1) * sides * 6)
        for ring in 0..<(ringCount - 1) {
            for side in 0..<sides {
                let next = (side + 1) % sides
                let a = Int32(ring * sides + side)
                let b = Int32(ring * sides + next)
                let c = Int32((ring + 1) * sides + side)
                let d = Int32((ring + 1) * sides + next)
                // Counter-clockwise when viewed from outside, so back-face
                // culling keeps the outside rather than the inside.
                mesh.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return mesh
    }

    /// Build the backbone tube for one chain of a structure.
    public static func backboneTube(
        structure: Structure,
        chainIndex: Int,
        residueColours: [SIMD3<Float>],
        radius: Float = 0.42,
        sides: Int = 10,
        segmentsPerResidue: Int = 6
    ) -> TubeMesh {
        guard structure.chains.indices.contains(chainIndex) else { return TubeMesh() }
        let range = structure.chains[chainIndex].residueRange

        var controls: [SIMD3<Float>] = []
        var controlColours: [SIMD3<Float>] = []
        for residueIndex in range {
            guard let alphaCarbon = structure.alphaCarbonIndex(ofResidue: residueIndex) else {
                continue
            }
            controls.append(structure.atoms[alphaCarbon].position)
            controlColours.append(
                residueIndex < residueColours.count
                    ? residueColours[residueIndex] : SIMD3(0.6, 0.6, 0.6))
        }
        guard controls.count >= 2 else { return TubeMesh() }

        let path = interpolate(controls, segmentsPerSpan: segmentsPerResidue)
        // Interpolate the colours along the same parameterisation as the path,
        // so a residue's colour lands on the part of the tube that is that
        // residue rather than a fraction of a residue away from it.
        let pathColours = interpolateColours(
            controlColours, segmentsPerSpan: segmentsPerResidue, total: path.count)
        return sweep(path: path, colours: pathColours, radius: radius, sides: sides)
    }

    /// Nearest-control colour sampling, which keeps the bands of a discrete
    /// scale (pLDDT) sharp instead of smearing them into invented intermediate
    /// colours that mean nothing.
    static func interpolateColours(
        _ controls: [SIMD3<Float>], segmentsPerSpan: Int, total: Int
    ) -> [SIMD3<Float>] {
        guard !controls.isEmpty, total > 0 else { return [] }
        return (0..<total).map { index in
            let control = min(controls.count - 1, index / max(1, segmentsPerSpan))
            return controls[control]
        }
    }

    // MARK: - Vector helpers

    static func safeNormalize(_ vector: SIMD3<Float>) -> SIMD3<Float>? {
        let length = simd_length(vector)
        guard length > 1e-6, length.isFinite else { return nil }
        return vector / length
    }

    /// Any unit vector perpendicular to the argument, chosen from the axis it
    /// leans on least so the cross product does not underflow.
    static func anyPerpendicular(to vector: SIMD3<Float>) -> SIMD3<Float> {
        let magnitudes = SIMD3<Float>(abs(vector.x), abs(vector.y), abs(vector.z))
        let smallest = magnitudes.x <= magnitudes.y
            ? (magnitudes.x <= magnitudes.z ? 0 : 2)
            : (magnitudes.y <= magnitudes.z ? 1 : 2)
        var axis = SIMD3<Float>.zero
        axis[smallest] = 1
        return safeNormalize(simd_cross(vector, axis)) ?? SIMD3(1, 0, 0)
    }
}
