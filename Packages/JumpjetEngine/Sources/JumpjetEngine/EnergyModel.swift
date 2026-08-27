import Foundation
import JumpjetCore
import simd

/// The force field: an elastic network, soft-sphere sterics, and a torsional
/// bias read from binned statistics.
///
/// OpenMM-inspired in shape and nothing more. There is no water, no
/// electrostatics, no bonded terms beyond the fixed geometry the torsional
/// representation already enforces, and the units are arbitrary. It exists to
/// make a crude sampler explore plausible conformations, not to compute a free
/// energy.
public struct EnergyModel: Sendable {

    // MARK: - Elastic network

    /// Cα pairs within the cutoff in the STARTING structure, which is what
    /// makes this an elastic network rather than a contact potential: the
    /// reference is the fold as it arrived, and the network pulls back towards
    /// it.
    public let networkA: [Int32]
    public let networkB: [Int32]
    public let networkRestLength: [Float]
    public let networkConstant: [Float]

    /// For each torsion, the network pairs it splits. Empty for every
    /// side-chain torsion, because no Cα moves, which is what makes side-chain
    /// moves cheap enough to dominate the move mix.
    public let networkPairsCrossing: [[Int32]]

    // MARK: - Sterics

    @usableFromInline let stericRadiusStorage: [Float]
    public var stericRadius: [Float] { stericRadiusStorage }
    public let stericCutoff: Float
    /// Bonded and 1-3 pairs, which are held at fixed geometry and would repel
    /// permanently and pointlessly. Keyed as `min * atomCount + max`.
    @usableFromInline let excludedPairsStorage: Set<Int64>
    public var excludedPairs: Set<Int64> { excludedPairsStorage }
    @usableFromInline let stericStrengthStorage: Float
    public var stericStrength: Float { stericStrengthStorage }

    // MARK: - Torsional bias

    public let tables: TorsionTables
    public let residueKind: [AminoAcid]
    /// Torsion indices of each residue's phi and psi, so the Ramachandran term
    /// can be evaluated as the 2D quantity it is rather than as two 1D ones.
    public let phiTorsion: [Int32]
    public let psiTorsion: [Int32]

    @usableFromInline let atomCountStorage: Int
    public var atomCount: Int { atomCountStorage }
    public let flexibility: [Float]

    public init(
        structure: Structure,
        topology: TorsionTopology,
        flexibility: [Float],
        tables: TorsionTables,
        cutoff: Float = Limits.elasticNetworkCutoff,
        springConstant: Float = 1.2,
        stericStrength: Float = 6.0
    ) {
        precondition(
            flexibility.count == structure.residueCount,
            "flexibility has \(flexibility.count) values for "
                + "\(structure.residueCount) residues")

        self.atomCountStorage = structure.atomCount
        self.tables = tables
        self.flexibility = flexibility
        self.stericStrengthStorage = stericStrength
        self.residueKind = structure.residues.map(\.kind)

        // --- Elastic network -------------------------------------------------
        var a: [Int32] = []
        var b: [Int32] = []
        var rest: [Float] = []
        var constants: [Float] = []

        var carbonIndex: [Int] = []
        var carbonResidue: [Int] = []
        for residue in structure.residues.indices {
            if let atom = structure.alphaCarbonIndex(ofResidue: residue) {
                carbonIndex.append(atom)
                carbonResidue.append(residue)
            }
        }
        let cutoffSquared = cutoff * cutoff
        for i in carbonIndex.indices {
            for j in (i + 1)..<carbonIndex.count {
                let separation = simd_distance_squared(
                    structure.atoms[carbonIndex[i]].position,
                    structure.atoms[carbonIndex[j]].position)
                guard separation < cutoffSquared else { continue }
                a.append(Int32(carbonIndex[i]))
                b.append(Int32(carbonIndex[j]))
                rest.append(separation.squareRoot())
                // The build plan's rule: spring constants scaled DOWN by the
                // per-residue flexibility prior, so floppy loops move and cores
                // hold. Both ends have a say, and the softer one wins, because
                // a spring is only as stiff as its loosest anchor.
                let softness = max(
                    flexibility[carbonResidue[i]], flexibility[carbonResidue[j]])
                constants.append(springConstant * (1 - 0.9 * softness))
            }
        }
        self.networkA = a
        self.networkB = b
        self.networkRestLength = rest
        self.networkConstant = constants

        // --- Which torsions split which network pairs ------------------------
        var moving = [Bool](repeating: false, count: structure.atomCount)
        var crossing = [[Int32]](repeating: [], count: topology.torsions.count)
        for (index, torsion) in topology.torsions.enumerated() {
            guard torsion.isBackboneTorsion else { continue }
            for atom in torsion.movingAtoms { moving[Int(atom)] = true }
            var pairs: [Int32] = []
            for pair in a.indices where moving[Int(a[pair])] != moving[Int(b[pair])] {
                pairs.append(Int32(pair))
            }
            crossing[index] = pairs
            for atom in torsion.movingAtoms { moving[Int(atom)] = false }
        }
        self.networkPairsCrossing = crossing

        // --- Sterics ---------------------------------------------------------
        self.stericRadiusStorage = structure.atoms.map {
            $0.element.vanDerWaalsRadius * Limits.vanDerWaalsScale
        }
        self.stericCutoff = (stericRadiusStorage.max() ?? 1.7) * 2

        var excluded = Set<Int64>()
        let bonds = BondFinder.bonds(in: structure)
        var adjacency = [[Int32]](repeating: [], count: structure.atomCount)
        for bond in bonds {
            adjacency[bond.a].append(Int32(bond.b))
            adjacency[bond.b].append(Int32(bond.a))
            excluded.insert(Self.key(bond.a, bond.b, atomCount: structure.atomCount))
        }
        // 1-3 pairs: two atoms bonded to a common neighbour. Their separation is
        // fixed by the bond ANGLE, which this representation also holds fixed,
        // so a repulsion between them is a constant that can never be relieved.
        for centre in adjacency.indices {
            let neighbours = adjacency[centre]
            for i in neighbours.indices {
                for j in (i + 1)..<neighbours.count {
                    excluded.insert(
                        Self.key(
                            Int(neighbours[i]), Int(neighbours[j]),
                            atomCount: structure.atomCount))
                }
            }
        }
        self.excludedPairsStorage = excluded

        // --- Backbone torsion lookup -----------------------------------------
        var phi = [Int32](repeating: -1, count: structure.residueCount)
        var psi = [Int32](repeating: -1, count: structure.residueCount)
        for (index, torsion) in topology.torsions.enumerated() {
            switch torsion.kind {
            case .phi: phi[torsion.residueIndex] = Int32(index)
            case .psi: psi[torsion.residueIndex] = Int32(index)
            case .chi: break
            }
        }
        self.phiTorsion = phi
        self.psiTorsion = psi
    }

    @inlinable
    static func key(_ a: Int, _ b: Int, atomCount: Int) -> Int64 {
        let low = Int64(min(a, b))
        let high = Int64(max(a, b))
        return low * Int64(atomCount) + high
    }

    // MARK: - Total energy

    /// The whole energy, by brute force. Used by the tests and once at the
    /// start of a run; the sampler works in deltas.
    public func totalEnergy(
        positions: [SIMD3<Float>], topology: TorsionTopology, grid: NeighbourGrid? = nil
    ) -> Energy {
        var network: Float = 0
        for pair in networkA.indices {
            let separation = simd_distance(
                positions[Int(networkA[pair])], positions[Int(networkB[pair])])
            let stretch = separation - networkRestLength[pair]
            network += networkConstant[pair] * stretch * stretch
        }

        // All pairs is 118 ms on a 1,077-atom structure and the sampler
        // re-derives the total periodically, so take the grid when there is
        // one. `gridFindsTheSameStericPairsAsAllPairs` pins the two together.
        var steric: Float = 0
        if let grid {
            var candidates: [Int32] = []
            candidates.reserveCapacity(128)
            for i in 0..<atomCount {
                candidates.removeAll(keepingCapacity: true)
                grid.appendNeighbours(of: positions[i], into: &candidates)
                for candidate in candidates where Int(candidate) > i {
                    let j = Int(candidate)
                    steric += stericPairEnergy(i, j, positions[i], positions[j])
                }
            }
        } else {
            for i in 0..<atomCount {
                for j in (i + 1)..<atomCount {
                    steric += stericPairEnergy(i, j, positions[i], positions[j])
                }
            }
        }

        var torsional: Float = 0
        for residue in residueKind.indices {
            torsional += backboneEnergy(residue: residue, positions: positions, topology: topology)
        }
        for torsion in topology.torsions {
            guard case .chi(let chiIndex) = torsion.kind else { continue }
            torsional += tables.chiEnergy(
                TorsionTopology.value(of: torsion, in: positions),
                chiIndex: chiIndex, residue: residueKind[torsion.residueIndex])
        }

        return Energy(network: network, steric: steric, torsional: torsional)
    }

    @inlinable
    public func stericPairEnergy(
        _ i: Int, _ j: Int, _ a: SIMD3<Float>, _ b: SIMD3<Float>
    ) -> Float {
        // Distance first, exclusion second. The exclusion test hashes an
        // Int64 and the distance test is five arithmetic operations, and the
        // overwhelming majority of candidate pairs fail the distance test, so
        // this order is what keeps the hash off the hot path.
        let contact = stericRadiusStorage[i] + stericRadiusStorage[j]
        let separationSquared = simd_distance_squared(a, b)
        guard separationSquared < contact * contact else { return 0 }
        guard !excludedPairsStorage.contains(
            Self.key(i, j, atomCount: atomCountStorage)) else { return 0 }
        let overlap = contact - separationSquared.squareRoot()
        return stericStrengthStorage * overlap * overlap
    }

    /// The Ramachandran term for one residue, which needs BOTH its torsions.
    public func backboneEnergy(
        residue: Int, positions: [SIMD3<Float>], topology: TorsionTopology
    ) -> Float {
        let phiIndex = phiTorsion[residue]
        let psiIndex = psiTorsion[residue]
        guard phiIndex >= 0, psiIndex >= 0 else { return 0 }
        let phi = TorsionTopology.value(of: topology.torsions[Int(phiIndex)], in: positions)
        let psi = TorsionTopology.value(of: topology.torsions[Int(psiIndex)], in: positions)
        return tables.backboneEnergy(phi: phi, psi: psi, residue: residueKind[residue])
    }
}

/// Energy broken out by term, so the HUD can show what is actually resisting.
public struct Energy: Sendable, Hashable {
    public var network: Float
    public var steric: Float
    public var torsional: Float

    public init(network: Float = 0, steric: Float = 0, torsional: Float = 0) {
        self.network = network
        self.steric = steric
        self.torsional = torsional
    }

    public var total: Float { network + steric + torsional }

    public static func + (a: Energy, b: Energy) -> Energy {
        Energy(
            network: a.network + b.network, steric: a.steric + b.steric,
            torsional: a.torsional + b.torsional)
    }

    public static func - (a: Energy, b: Energy) -> Energy {
        Energy(
            network: a.network - b.network, steric: a.steric - b.steric,
            torsional: a.torsional - b.torsional)
    }
}
