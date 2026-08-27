import Foundation
import JumpjetCore
import simd

/// Live numbers from a run, for the HUD gauges.
public struct RunProgress: Sendable, Hashable {
    public var sweep: Int
    public var totalSweeps: Int
    public var acceptanceRatio: Float
    public var energy: Energy
    public var rmsdFromStart: Float
    public var sweepsPerSecond: Float

    public var fraction: Double {
        totalSweeps > 0 ? Double(sweep) / Double(totalSweeps) : 0
    }
}

/// A stored trajectory. Frames are in PSEUDO-TIME, measured in Monte Carlo
/// sweeps, and every label in the app says so.
public struct Trajectory: Sendable {
    /// Sweep number for each frame.
    public let sweeps: [Int]
    /// Flat coordinates, `frames * atomCount`.
    public let positions: [SIMD3<Float>]
    public let atomCount: Int
    public let energies: [Energy]
    public let acceptanceRatio: Float
    public let configuration: RunConfiguration
    public let sweepsPerSecond: Float

    public var frameCount: Int { sweeps.count }

    public func frame(_ index: Int) -> ArraySlice<SIMD3<Float>> {
        let start = index * atomCount
        return positions[start..<(start + atomCount)]
    }
}

/// The sampler. Metropolis Monte Carlo in torsion space with a mixed move set.
///
/// Monte Carlo rather than Langevin for v1 because its correctness is easy to
/// test: detailed balance is a property of the proposal and the acceptance
/// rule, both of which are a dozen lines here, and a seeded run replays exactly.
public final class MonteCarloSampler {

    private let structure: Structure
    private let topology: TorsionTopology
    private let model: EnergyModel
    private let configuration: RunConfiguration
    private let mix: MoveMix
    private let amplitudes: MoveAmplitudes

    private var positions: [SIMD3<Float>]
    private let startPositions: [SIMD3<Float>]
    private var grid: NeighbourGrid
    private var random: SeededRandom

    /// Marks the atoms carried by the move under consideration.
    private var isMoving: [Bool]
    /// Scratch, reused so a move does not allocate.
    private var candidates: [Int32] = []
    private var savedPositions: [SIMD3<Float>] = []
    /// Version stamps, so a candidate reached from both the old and the new
    /// position of the same atom is counted once. A `Set` per atom would
    /// allocate on every move; a stamp is one comparison.
    /// Version stamps, so a candidate reached from both the old and the new
    /// position of the same atom is counted once. A `Set` per atom would
    /// allocate on every move; a stamp is one comparison.
    private var seenStamp: [Int32]
    private var stamp: Int32 = 0

    private var proposed = 0
    private var accepted = 0

    /// The three staggered chi1 wells, which a rotamer jump proposes between.
    static let rotamerWells: [Float] = [-60, 60, 180]

    public init(
        structure: Structure,
        flexibility: [Float],
        tables: TorsionTables,
        configuration: RunConfiguration = RunConfiguration(),
        mix: MoveMix = MoveMix(),
        amplitudes: MoveAmplitudes = MoveAmplitudes(),
        chainIndex: Int? = nil
    ) {
        self.amplitudes = amplitudes
        self.structure = structure
        self.topology = TorsionTopology(structure: structure, chainIndex: chainIndex)
        self.model = EnergyModel(
            structure: structure, topology: topology, flexibility: flexibility, tables: tables)
        self.configuration = configuration
        self.mix = mix
        self.positions = structure.positions
        self.startPositions = structure.positions
        self.grid = NeighbourGrid(positions: structure.positions, cutoff: model.stericCutoff)
        self.random = SeededRandom(seed: configuration.seed)
        self.isMoving = [Bool](repeating: false, count: structure.atomCount)
        self.seenStamp = [Int32](repeating: 0, count: structure.atomCount)
        self.candidates.reserveCapacity(512)
        self.savedPositions.reserveCapacity(structure.atomCount)
    }

    public var torsionCount: Int { topology.torsions.count }
    public var currentPositions: [SIMD3<Float>] { positions }

    /// Run to completion.
    ///
    /// - Parameter progress: called every sweep. Returning `false` stops the
    ///   run, which is how the HUD's cancel works: cooperative rather than a
    ///   cancelled task abandoning a half-written trajectory.
    public func run(
        progress: ((RunProgress) -> Bool)? = nil
    ) -> Trajectory {
        var frames: [SIMD3<Float>] = []
        var frameSweeps: [Int] = []
        var frameEnergies: [Energy] = []
        frames.reserveCapacity(configuration.snapshotCount * structure.atomCount)

        var energy = model.totalEnergy(
            positions: positions, topology: topology, grid: grid)
        let movesPerSweep = max(1, structure.residueCount)
        let started = Date()

        storeFrame(&frames, &frameSweeps, &frameEnergies, sweep: 0, energy: energy)

        var sweep = 0
        while sweep < configuration.sweeps {
            sweep += 1
            for _ in 0..<movesPerSweep {
                energy = energy + attemptMove()
            }

            // Rebuilt EVERY sweep, not on the configured interval. It costs
            // under a millisecond and it is what lets the cell size sit just
            // above the interaction cutoff: the alternative is a wide margin to
            // tolerate drift, and a wide cell returns three times as many
            // candidates per query, which is the sampler's dominant cost.
            grid.rebuild(positions: positions)

            if sweep % configuration.gridRebuildInterval == 0 {
                // Re-derive the energy from scratch periodically. Deltas
                // accumulate floating-point drift over hundreds of thousands of
                // moves, and an energy trace that slowly wanders is
                // indistinguishable from physics doing something.
                energy = model.totalEnergy(
                    positions: positions, topology: topology, grid: grid)
            }

            if sweep % configuration.snapshotStride == 0 {
                storeFrame(&frames, &frameSweeps, &frameEnergies, sweep: sweep, energy: energy)
            }

            if let progress {
                let elapsed = Float(Date().timeIntervalSince(started))
                let report = RunProgress(
                    sweep: sweep, totalSweeps: configuration.sweeps,
                    acceptanceRatio: acceptanceRatio, energy: energy,
                    rmsdFromStart: Geometry.superposedRMSD(
                        moving: positions, onto: startPositions),
                    sweepsPerSecond: elapsed > 0 ? Float(sweep) / elapsed : 0)
                if !progress(report) { break }
            }
        }

        let elapsed = Float(Date().timeIntervalSince(started))
        return Trajectory(
            sweeps: frameSweeps, positions: frames, atomCount: structure.atomCount,
            energies: frameEnergies, acceptanceRatio: acceptanceRatio,
            configuration: configuration,
            sweepsPerSecond: elapsed > 0 ? Float(sweep) / elapsed : 0)
    }

    public var acceptanceRatio: Float {
        proposed > 0 ? Float(accepted) / Float(proposed) : 0
    }

    // MARK: - Frames

    private func storeFrame(
        _ frames: inout [SIMD3<Float>], _ sweeps: inout [Int],
        _ energies: inout [Energy], sweep: Int, energy: Energy
    ) {
        // Superposed onto the starting structure before storage. Rotating the
        // SMALLER side of each torsion is what makes the sampler affordable and
        // it lets the whole molecule drift and tumble in the lab frame; a
        // playback of the raw coordinates would show a protein wandering off
        // screen. Every internal coordinate is untouched by this.
        let fit = Geometry.kabschSuperposition(moving: positions, onto: startPositions)
        frames.append(contentsOf: Geometry.apply(fit, to: positions))
        sweeps.append(sweep)
        energies.append(energy)
    }

    // MARK: - Moves

    /// Which of the four proposals a move is.
    private enum MoveKind: CaseIterable {
        case sideChainPerturbation
        case rotamerJump
        case ringFlip
        case backbonePerturbation
    }

    /// Pick a move kind from the mix.
    ///
    /// Written as an explicit cumulative walk rather than a chain of `else if`
    /// conditions with side effects in them. The clever version worked and was
    /// unreadable, and the next person to add a fifth move type would have had
    /// to reason about which closures had run.
    private func pickMoveKind() -> MoveKind {
        let weights: [(MoveKind, Float)] = [
            (.sideChainPerturbation, mix.sideChainPerturbation),
            (.rotamerJump, mix.rotamerJump),
            (.ringFlip, mix.ringFlip),
            (.backbonePerturbation, mix.backbonePerturbation),
        ]
        var remaining = random.uniform() * mix.total
        for (kind, weight) in weights {
            remaining -= weight
            if remaining <= 0 { return kind }
        }
        return .sideChainPerturbation
    }

    /// Propose one move, accept or reject it, and return the energy change.
    private func attemptMove() -> Energy {
        guard !topology.torsions.isEmpty else { return Energy() }
        proposed += 1

        // A structure can lack the torsions a kind needs (no aromatic ring, no
        // backbone freedom in a single residue), so a kind that finds nothing
        // falls back to a side-chain perturbation rather than wasting the move.
        var kind = pickMoveKind()
        var torsionIndex: Int?
        switch kind {
        case .sideChainPerturbation: torsionIndex = pickTorsion(backbone: false)
        case .rotamerJump: torsionIndex = pickTorsion(backbone: false, chiOnly: 0)
        case .ringFlip: torsionIndex = pickFlippableRing()
        case .backbonePerturbation: torsionIndex = pickTorsion(backbone: true)
        }
        if torsionIndex == nil, kind != .sideChainPerturbation {
            kind = .sideChainPerturbation
            torsionIndex = pickTorsion(backbone: false)
        }
        guard let index = torsionIndex else { return Energy() }

        let residue = topology.torsions[index].residueIndex
        let softness = model.flexibility[residue]
        let delta: Float

        switch kind {
        case .sideChainPerturbation:
            // Amplitude scales with the flexibility prior, as the build plan
            // specifies: a residue the neural layer calls rigid gets small
            // nudges, a floppy loop gets large ones.
            delta = random.normal() * amplitudes.sideChain(flexibility: softness)
        case .rotamerJump:
            // A discrete well-to-well proposal. A Gaussian small enough to be
            // accepted essentially never crosses a 120 degree barrier, so
            // without this move the app's own subject matter is unreachable.
            let current = TorsionTopology.value(of: topology.torsions[index], in: positions)
            let target = Self.rotamerWells[random.index(below: Self.rotamerWells.count)]
            delta = Geometry.angularDifference(from: current, to: target)
                + random.normal() * amplitudes.rotamerJitter
        case .ringFlip:
            delta = 180
        case .backbonePerturbation:
            // Backbone amplitudes are much smaller. A phi rotation swings
            // everything on one side of the bond, so the lever arm does damage
            // the elastic network then has to absorb.
            delta = random.normal() * amplitudes.backbone(flexibility: softness)
        }

        guard abs(delta) > 1e-4 else { return Energy() }
        return apply(torsionIndex: index, delta: delta)
    }

    private func pickTorsion(backbone: Bool, chiOnly: Int? = nil) -> Int? {
        // Rejection sampling over a handful of tries rather than maintaining
        // per-category index lists. At these category sizes it finds one almost
        // immediately, and it keeps the topology the single source of truth.
        for _ in 0..<24 {
            let index = random.index(below: topology.torsions.count)
            let torsion = topology.torsions[index]
            guard torsion.isBackboneTorsion == backbone else { continue }
            if let chiOnly {
                guard case .chi(let which) = torsion.kind, which == chiOnly else { continue }
            }
            return index
        }
        return nil
    }

    private func pickFlippableRing() -> Int? {
        for _ in 0..<48 {
            let index = random.index(below: topology.torsions.count)
            if topology.torsions[index].isFlippableRing { return index }
        }
        return nil
    }

    /// Apply a rotation, evaluate the delta, and keep it or put it back.
    private func apply(torsionIndex: Int, delta: Float) -> Energy {
        let torsion = topology.torsions[torsionIndex]

        savedPositions.removeAll(keepingCapacity: true)
        for atom in torsion.movingAtoms {
            savedPositions.append(positions[Int(atom)])
            isMoving[Int(atom)] = true
        }

        let networkBefore = networkEnergy(torsionIndex: torsionIndex)
        let torsionalBefore = torsionalEnergy(torsion)

        TorsionTopology.rotate(&positions, torsion: torsion, degrees: delta)

        let networkAfter = networkEnergy(torsionIndex: torsionIndex)
        let torsionalAfter = torsionalEnergy(torsion)
        // Sterics are computed as a DIFFERENCE in one pass rather than as two
        // absolute sums. Each moving atom's candidate list is gathered once and
        // both its old and its new interaction with each candidate are taken
        // from it, which halves the grid queries: the queries, not the
        // arithmetic, were the measured cost.
        let stericChange = stericDelta(torsion: torsion)

        let change = Energy(
            network: networkAfter - networkBefore,
            steric: stericChange,
            torsional: torsionalAfter - torsionalBefore)

        let keep: Bool
        if change.total <= 0 {
            keep = true
        } else {
            let temperature = max(configuration.temperature, 1e-4)
            keep = random.uniform() < exp(-change.total / temperature)
        }

        if keep {
            accepted += 1
        } else {
            for (offset, atom) in torsion.movingAtoms.enumerated() {
                positions[Int(atom)] = savedPositions[offset]
            }
        }
        for atom in torsion.movingAtoms { isMoving[Int(atom)] = false }
        return keep ? change : Energy()
    }

    /// The change in steric energy, in one pass over the moving atoms.
    ///
    /// Only pairs with exactly one atom in the moving set can change, because
    /// the set rotates rigidly. That is the whole reason a torsional
    /// representation is affordable, and this pass is 97% of the sampler's
    /// measured cost.
    ///
    /// SERIAL, and that was measured rather than assumed. A deterministic
    /// `DispatchQueue.concurrentPerform` split across eight chunks, with
    /// disjoint stamp buffers and a fixed-order reduction, produced a
    /// bit-identical acceptance ratio and ran SEVEN TIMES SLOWER: 19.6 sweeps
    /// per second down to 3.1 on a 335-residue protein. The dispatch waits on
    /// worker threads, and on a machine with anything else running they are not
    /// there to be had.
    ///
    /// The conclusion holds beyond this machine, which is why the code went
    /// rather than being kept behind a flag. The target is a phone: two
    /// performance cores, a thermal budget, and a user who would rather the app
    /// did not empty the battery. Saturating the cores to sample a protein is
    /// the wrong shape of answer even where it is faster.
    private func stericDelta(torsion: Torsion) -> Float {
        var total: Float = 0
        let marginSquared = grid.margin * grid.margin
        let atoms = torsion.movingAtoms

        for offset in atoms.indices {
            let index = Int(atoms[offset])
            let old = savedPositions[offset]
            let new = positions[index]

            stamp &+= 1
            let current = stamp
            candidates.removeAll(keepingCapacity: true)
            grid.appendNeighbours(of: old, into: &candidates)
            // The grid's margin is how far an atom may move and still be found
            // from its old cell. A rotamer jump or a ring flip throws an atom
            // much further than that, so those need the new position looked up
            // as well; a small backbone nudge does not.
            if simd_distance_squared(old, new) > marginSquared {
                grid.appendNeighbours(of: new, into: &candidates)
            }

            for candidate in candidates {
                let other = Int(candidate)
                if isMoving[other] { continue }
                if seenStamp[other] == current { continue }
                seenStamp[other] = current
                let neighbour = positions[other]
                total += model.stericPairEnergy(index, other, new, neighbour)
                    - model.stericPairEnergy(index, other, old, neighbour)
            }
        }
        return total
    }

    private func networkEnergy(torsionIndex: Int) -> Float {
        var total: Float = 0
        for pair in model.networkPairsCrossing[torsionIndex] {
            let index = Int(pair)
            let separation = simd_distance(
                positions[Int(model.networkA[index])], positions[Int(model.networkB[index])])
            let stretch = separation - model.networkRestLength[index]
            total += model.networkConstant[index] * stretch * stretch
        }
        return total
    }

    private func torsionalEnergy(_ torsion: Torsion) -> Float {
        switch torsion.kind {
        case .phi, .psi:
            return model.backboneEnergy(
                residue: torsion.residueIndex, positions: positions, topology: topology)
        case .chi(let chiIndex):
            var total = model.tables.chiEnergy(
                TorsionTopology.value(of: torsion, in: positions),
                chiIndex: chiIndex, residue: model.residueKind[torsion.residueIndex])
            // chi2 is measured across chi1's atoms, so moving chi1 changes it too.
            if chiIndex == 0 {
                for other in topology.torsionsByResidue[torsion.residueIndex] {
                    guard case .chi(1) = topology.torsions[other].kind else { continue }
                    total += model.tables.chiEnergy(
                        TorsionTopology.value(of: topology.torsions[other], in: positions),
                        chiIndex: 1, residue: model.residueKind[torsion.residueIndex])
                }
            }
            return total
        }
    }

}
