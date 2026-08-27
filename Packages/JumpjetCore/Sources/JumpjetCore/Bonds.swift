import Foundation
import simd

/// A covalent bond between two atoms, by index into ``Structure/atoms``.
public struct Bond: Sendable, Hashable, Codable {
    public let a: Int
    public let b: Int

    public init(_ a: Int, _ b: Int) {
        // Canonical order, so the same bond found from either end is the same
        // value and a `Set<Bond>` really does deduplicate.
        self.a = min(a, b)
        self.b = max(a, b)
    }
}

/// Infers covalent bonds from geometry.
///
/// Distance-based rather than template-based, because a template table has to
/// know every residue and every modified residue, and gets one silently wrong
/// the first time a file contains something it has not met. Distance gets a
/// non-standard residue approximately right instead of exactly wrong.
public enum BondFinder {

    /// A bond is called when the separation is within this factor of the sum of
    /// the two covalent radii. 1.25 admits the long C-S bonds of methionine
    /// without joining atoms across a 3 angstrom van der Waals contact.
    public static let tolerance: Float = 1.25

    /// Bonds within each residue, plus the peptide bonds joining consecutive
    /// residues of a chain.
    ///
    /// Restricting the intra-residue search to one residue at a time is what
    /// keeps this linear: an all-pairs search over 10,000 atoms is 50 million
    /// distance tests, and a residue never has more than about twenty atoms.
    public static func bonds(in structure: Structure) -> [Bond] {
        var found: [Bond] = []
        found.reserveCapacity(structure.atomCount)

        for residue in structure.residues {
            let atoms = Array(residue.atomRange)
            for i in atoms.indices {
                for j in (i + 1)..<atoms.count {
                    if isBonded(structure, atoms[i], atoms[j]) {
                        found.append(Bond(atoms[i], atoms[j]))
                    }
                }
            }
        }

        for chain in structure.chains {
            for residueIndex in chain.residueRange.dropLast() {
                guard
                    let carbon = structure.atomIndex(named: "C", inResidue: residueIndex),
                    let nitrogen = structure.atomIndex(named: "N", inResidue: residueIndex + 1)
                else { continue }
                // A chain break leaves a gap of many angstroms, and joining
                // across it draws a stick through empty space that reads as a
                // real bond. The same distance test that finds the peptide bond
                // rejects the gap.
                if isBonded(structure, carbon, nitrogen) {
                    found.append(Bond(carbon, nitrogen))
                }
            }
        }
        return found
    }

    public static func isBonded(_ structure: Structure, _ a: Int, _ b: Int) -> Bool {
        let first = structure.atoms[a]
        let second = structure.atoms[b]
        // Two metal ions are never covalently bonded to each other, and two
        // ions that happen to sit close in a site would otherwise be joined.
        if first.element.isMetalIon || second.element.isMetalIon { return false }
        let limit = (first.element.covalentRadius + second.element.covalentRadius) * tolerance
        let separation = simd_distance_squared(first.position, second.position)
        // The lower bound rejects atoms sitting on top of each other, which is
        // what an unfiltered alternate location or a duplicated record looks
        // like geometrically.
        return separation > 0.16 && separation < limit * limit
    }

    /// Bonds involving at least one side-chain atom, for the sticks display.
    public static func sideChainBonds(in structure: Structure) -> [Bond] {
        bonds(in: structure).filter { bond in
            !structure.atoms[bond.a].isBackbone || !structure.atoms[bond.b].isBackbone
        }
    }
}
