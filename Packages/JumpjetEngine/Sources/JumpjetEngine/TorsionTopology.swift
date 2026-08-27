import Foundation
import JumpjetCore
import simd

/// One rotatable torsion, and everything the sampler needs to move it.
public struct Torsion: Sendable {
    public enum Kind: Sendable, Hashable {
        case phi
        case psi
        /// Zero-based, so `.chi(0)` is chi1.
        case chi(Int)

        public var isBackbone: Bool { self != .chi(0) && (self == .phi || self == .psi) }
    }

    public let kind: Kind
    public let residueIndex: Int
    /// The bond the rotation happens about, as atom indices.
    public let axisStart: Int
    public let axisEnd: Int
    /// The four atoms whose dihedral this torsion IS, for reading its value.
    public let dihedralAtoms: SIMD4<Int32>
    /// Atoms carried by the rotation.
    public let movingAtoms: [Int32]
    /// True when a 180 degree change produces an identical structure, so the
    /// analysis must not count it as a jump.
    public let isSymmetric: Bool
    /// True for the chi2 of a phenylalanine or tyrosine, which is what a ring
    /// flip proposal targets.
    public let isFlippableRing: Bool

    public var isBackboneTorsion: Bool {
        switch kind {
        case .phi, .psi: true
        case .chi: false
        }
    }
}

/// The torsional degrees of freedom of a structure.
///
/// Representation, from the build plan: all-atom, torsional degrees of freedom
/// only. Bond lengths and angles are fixed. That is what keeps rotamers and ring
/// flips first-class citizens, which a Cα-only model cannot do at all.
public struct TorsionTopology: Sendable {
    public let torsions: [Torsion]
    /// Indices into ``torsions``, grouped by residue, for picking a move.
    public let torsionsByResidue: [[Int]]
    public let atomCount: Int

    /// Torsions that move nothing, or whose rotation is blocked by a ring.
    public let skipped: [(residueIndex: Int, kind: Torsion.Kind, reason: String)]

    public init(structure: Structure, chainIndex: Int? = nil) {
        let bonds = BondFinder.bonds(in: structure)
        var adjacency = [[Int32]](repeating: [], count: structure.atomCount)
        for bond in bonds {
            // Disulfides are covalent and are NOT part of the torsional tree.
            // Left in, a cystine's chi1 appears to rotate the far chain, the
            // cycle detection below rejects it, and both cysteines silently
            // lose their side-chain freedom.
            if structure.atoms[bond.a].name == "SG", structure.atoms[bond.b].name == "SG" {
                continue
            }
            adjacency[bond.a].append(Int32(bond.b))
            adjacency[bond.b].append(Int32(bond.a))
        }

        var built: [Torsion] = []
        var byResidue = [[Int]](repeating: [], count: structure.residueCount)
        var skippedTorsions: [(Int, Torsion.Kind, String)] = []

        let residueRange: Range<Int>
        if let chainIndex, structure.chains.indices.contains(chainIndex) {
            residueRange = structure.chains[chainIndex].residueRange
        } else {
            residueRange = 0..<structure.residueCount
        }

        for residueIndex in residueRange {
            let residue = structure.residues[residueIndex]

            func atom(_ name: String, _ index: Int) -> Int? {
                structure.atomIndex(named: name, inResidue: index)
            }

            // Backbone phi: C(i-1) - N(i) - CA(i) - C(i), about N-CA.
            let hasPrevious = residueIndex > 0
                && structure.residues[residueIndex - 1].chainIndex == residue.chainIndex
            if hasPrevious,
                let previousC = atom("C", residueIndex - 1), let n = atom("N", residueIndex),
                let ca = atom("CA", residueIndex), let c = atom("C", residueIndex),
                BondFinder.isBonded(structure, previousC, n)
            {
                Self.append(
                    kind: .phi, residueIndex: residueIndex, axisStart: n, axisEnd: ca,
                    dihedral: SIMD4(Int32(previousC), Int32(n), Int32(ca), Int32(c)),
                    isSymmetric: false, isFlippableRing: false,
                    adjacency: adjacency, atomCount: structure.atomCount,
                    into: &built, byResidue: &byResidue, skipped: &skippedTorsions)
            }

            // Backbone psi: N(i) - CA(i) - C(i) - N(i+1), about CA-C.
            let hasNext = residueIndex + 1 < structure.residueCount
                && structure.residues[residueIndex + 1].chainIndex == residue.chainIndex
            if hasNext,
                let n = atom("N", residueIndex), let ca = atom("CA", residueIndex),
                let c = atom("C", residueIndex), let nextN = atom("N", residueIndex + 1),
                BondFinder.isBonded(structure, c, nextN)
            {
                Self.append(
                    kind: .psi, residueIndex: residueIndex, axisStart: ca, axisEnd: c,
                    dihedral: SIMD4(Int32(n), Int32(ca), Int32(c), Int32(nextN)),
                    isSymmetric: false, isFlippableRing: false,
                    adjacency: adjacency, atomCount: structure.atomCount,
                    into: &built, byResidue: &byResidue, skipped: &skippedTorsions)
            }

            // Side-chain chi.
            let definitions = residue.kind.chiDefinitions
            for (chiIndex, names) in definitions.enumerated() {
                let indices = names.compactMap { atom($0, residueIndex) }
                guard indices.count == 4 else { continue }
                Self.append(
                    kind: .chi(chiIndex), residueIndex: residueIndex,
                    axisStart: indices[1], axisEnd: indices[2],
                    dihedral: SIMD4(
                        Int32(indices[0]), Int32(indices[1]), Int32(indices[2]),
                        Int32(indices[3])),
                    isSymmetric: residue.kind.symmetricChiIndices.contains(chiIndex),
                    isFlippableRing: residue.kind.hasFlippableRing && chiIndex == 1,
                    adjacency: adjacency, atomCount: structure.atomCount,
                    into: &built, byResidue: &byResidue, skipped: &skippedTorsions)
            }
        }

        self.torsions = built
        self.torsionsByResidue = byResidue
        self.atomCount = structure.atomCount
        self.skipped = skippedTorsions.map {
            (residueIndex: $0.0, kind: $0.1, reason: $0.2)
        }
    }

    /// Build one torsion, or record why it was skipped.
    private static func append(
        kind: Torsion.Kind, residueIndex: Int, axisStart: Int, axisEnd: Int,
        dihedral: SIMD4<Int32>, isSymmetric: Bool, isFlippableRing: Bool,
        adjacency: [[Int32]], atomCount: Int,
        into torsions: inout [Torsion], byResidue: inout [[Int]],
        skipped: inout [(Int, Torsion.Kind, String)]
    ) {
        guard let sides = components(
            splittingBond: (axisStart, axisEnd), adjacency: adjacency, atomCount: atomCount)
        else {
            // The two ends are still connected with the bond removed, so the
            // bond is in a ring. Proline's phi is the honest case: its backbone
            // really is locked by the pyrrolidine ring and must not be sampled.
            skipped.append((residueIndex, kind, "the bond lies in a ring"))
            return
        }

        // Rotate whichever SIDE IS SMALLER. Every energy term is a function of
        // internal distances and dihedrals, so the two choices give identical
        // energies and differ only by a rigid-body transform of the whole
        // structure. Taking the smaller side halves the average cost of a
        // backbone move, and the trajectory is superposed onto frame 0 before
        // anyone looks at it, which is where the rigid-body difference goes.
        let moving = sides.start.count < sides.end.count ? sides.start : sides.end
        // The direction of the axis has to follow the side being rotated, or
        // every torsion on the N-terminal side comes out with the wrong sign.
        let rotatingStartSide = sides.start.count < sides.end.count
        guard moving.count > 0, moving.count < atomCount else {
            skipped.append((residueIndex, kind, "the rotation moves nothing"))
            return
        }

        byResidue[residueIndex].append(torsions.count)
        torsions.append(
            Torsion(
                kind: kind, residueIndex: residueIndex,
                axisStart: rotatingStartSide ? axisEnd : axisStart,
                axisEnd: rotatingStartSide ? axisStart : axisEnd,
                dihedralAtoms: dihedral, movingAtoms: moving,
                isSymmetric: isSymmetric, isFlippableRing: isFlippableRing))
    }

    /// The two connected components either side of a bond, or `nil` when
    /// removing the bond leaves the graph connected (a ring).
    static func components(
        splittingBond bond: (Int, Int), adjacency: [[Int32]], atomCount: Int
    ) -> (start: [Int32], end: [Int32])? {
        var visited = [Bool](repeating: false, count: atomCount)
        var reachedTheOtherEnd = false

        func flood(from seed: Int, blocking blocked: Int) -> [Int32] {
            var component: [Int32] = []
            var stack = [Int32(seed)]
            visited[seed] = true
            while let current = stack.popLast() {
                component.append(current)
                for neighbour in adjacency[Int(current)] {
                    if Int(current) == bond.0 && Int(neighbour) == bond.1 { continue }
                    if Int(current) == bond.1 && Int(neighbour) == bond.0 { continue }
                    if Int(neighbour) == blocked { reachedTheOtherEnd = true }
                    if !visited[Int(neighbour)] {
                        visited[Int(neighbour)] = true
                        stack.append(neighbour)
                    }
                }
            }
            return component
        }

        let startSide = flood(from: bond.0, blocking: bond.1)
        if reachedTheOtherEnd { return nil }
        let endSide = flood(from: bond.1, blocking: bond.0)
        return (startSide, endSide)
    }

    /// Rotate `torsion`'s moving atoms by `degrees` about its axis, in place.
    public static func rotate(
        _ positions: inout [SIMD3<Float>], torsion: Torsion, degrees: Float
    ) {
        let origin = positions[torsion.axisStart]
        let direction = positions[torsion.axisEnd] - origin
        let length = simd_length(direction)
        guard length > 1e-6 else { return }
        let quaternion = simd_quatf(
            angle: Geometry.degreesToRadians(degrees), axis: direction / length)

        for atom in torsion.movingAtoms {
            let index = Int(atom)
            positions[index] = origin + quaternion.act(positions[index] - origin)
        }
    }

    /// The current value of a torsion, in degrees.
    public static func value(
        of torsion: Torsion, in positions: [SIMD3<Float>]
    ) -> Float {
        Geometry.dihedral(
            positions[Int(torsion.dihedralAtoms[0])],
            positions[Int(torsion.dihedralAtoms[1])],
            positions[Int(torsion.dihedralAtoms[2])],
            positions[Int(torsion.dihedralAtoms[3])])
    }
}
