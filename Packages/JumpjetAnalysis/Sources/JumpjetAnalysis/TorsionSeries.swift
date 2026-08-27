import Foundation
import JumpjetCore
import simd

/// One residue's torsion measured across every frame.
public struct TorsionTrack: Sendable {
    public let residueIndex: Int
    public let residueKind: AminoAcid
    public let chainID: String
    public let label: String
    /// Zero-based: 0 is chi1.
    public let chiIndex: Int
    /// Degrees, -180 to 180, one per frame.
    public let values: [Float]
    /// True when a 180 degree change is the SAME structure, so the analysis
    /// must not count it as a jump.
    public let isSymmetric: Bool
    public let isFlippableRing: Bool
}

/// Extracts torsion angles from a trajectory.
///
/// Reads the chi definitions from `JumpjetCore.AminoAcid`, which is the same
/// table the sampler proposes moves against. If the two ever disagreed, the
/// engine would be moving one torsion and the analysis reporting another.
public enum TorsionSeries {

    /// Every chi torsion of every residue, across the trajectory.
    public static func chiTracks(
        structure: Structure, trajectory: TrajectoryFrames, chiIndex: Int
    ) -> [TorsionTrack] {
        var tracks: [TorsionTrack] = []
        for residueIndex in structure.residues.indices {
            let residue = structure.residues[residueIndex]
            let definitions = residue.kind.chiDefinitions
            guard chiIndex < definitions.count else { continue }
            let names = definitions[chiIndex]
            let atoms = names.compactMap {
                structure.atomIndex(named: $0, inResidue: residueIndex)
            }
            guard atoms.count == 4 else { continue }

            var values = [Float](repeating: 0, count: trajectory.frameCount)
            for frameIndex in 0..<trajectory.frameCount {
                let frame = trajectory.frame(frameIndex)
                let base = frame.startIndex
                values[frameIndex] = Geometry.dihedral(
                    frame[base + atoms[0]], frame[base + atoms[1]],
                    frame[base + atoms[2]], frame[base + atoms[3]])
            }

            let chainID = structure.chains.indices.contains(residue.chainIndex)
                ? structure.chains[residue.chainIndex].id : "?"
            tracks.append(
                TorsionTrack(
                    residueIndex: residueIndex, residueKind: residue.kind, chainID: chainID,
                    label: residue.label(chainID: chainID), chiIndex: chiIndex,
                    values: values,
                    isSymmetric: residue.kind.symmetricChiIndices.contains(chiIndex),
                    isFlippableRing: residue.kind.hasFlippableRing && chiIndex == 1))
        }
        return tracks
    }

    /// Backbone phi and psi per residue, for the dihedral PCA.
    ///
    /// Returns `nil` for a residue missing a neighbour, so the caller can drop
    /// it rather than treating a zero as a measured angle.
    public static func backboneTracks(
        structure: Structure, trajectory: TrajectoryFrames
    ) -> [(residueIndex: Int, phi: [Float], psi: [Float])] {
        var output: [(Int, [Float], [Float])] = []
        for residueIndex in structure.residues.indices {
            let residue = structure.residues[residueIndex]
            guard residueIndex > 0, residueIndex + 1 < structure.residueCount,
                structure.residues[residueIndex - 1].chainIndex == residue.chainIndex,
                structure.residues[residueIndex + 1].chainIndex == residue.chainIndex,
                let previousC = structure.atomIndex(named: "C", inResidue: residueIndex - 1),
                let n = structure.atomIndex(named: "N", inResidue: residueIndex),
                let ca = structure.alphaCarbonIndex(ofResidue: residueIndex),
                let c = structure.atomIndex(named: "C", inResidue: residueIndex),
                let nextN = structure.atomIndex(named: "N", inResidue: residueIndex + 1)
            else { continue }

            var phi = [Float](repeating: 0, count: trajectory.frameCount)
            var psi = [Float](repeating: 0, count: trajectory.frameCount)
            for frameIndex in 0..<trajectory.frameCount {
                let frame = trajectory.frame(frameIndex)
                let base = frame.startIndex
                phi[frameIndex] = Geometry.dihedral(
                    frame[base + previousC], frame[base + n], frame[base + ca], frame[base + c])
                psi[frameIndex] = Geometry.dihedral(
                    frame[base + n], frame[base + ca], frame[base + c], frame[base + nextN])
            }
            output.append((residueIndex, phi, psi))
        }
        return output
    }
}
