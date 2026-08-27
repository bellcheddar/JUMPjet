import Foundation
import JumpjetCore

/// The three staggered chi1 rotamer wells.
public enum RotamerState: Int, Sendable, Hashable, CaseIterable, Codable {
    /// gauche minus, around -60 degrees.
    case gaucheMinus = 0
    /// gauche plus, around +60 degrees.
    case gauchePlus = 1
    /// trans, around 180 degrees.
    case trans = 2

    public var centre: Float {
        switch self {
        case .gaucheMinus: -60
        case .gauchePlus: 60
        case .trans: 180
        }
    }

    public var shortName: String {
        switch self {
        case .gaucheMinus: "g-"
        case .gauchePlus: "g+"
        case .trans: "t"
        }
    }
}

/// One rotamer transition.
public struct RotamerJump: Sendable, Hashable {
    public let residueIndex: Int
    public let label: String
    /// The frame the jump was first seen in.
    public let frame: Int
    /// The sweep that frame was taken at. Rates are quoted in sweeps.
    public let sweep: Int
    public let from: RotamerState
    public let to: RotamerState
}

/// Rotamer jump detection, and the raster the HUD draws from it.
public enum JumpDetection {

    /// How far from a well's centre still counts as being in it. The build plan
    /// specifies 30 degrees, which leaves 30 degree bands of no-man's-land
    /// between the wells.
    public static let toleranceDegrees: Float = 30

    /// Assign each frame to a well.
    ///
    /// A frame in no-man's-land INHERITS THE PREVIOUS STATE, as the build plan
    /// specifies. That is what makes the count a count of transitions rather
    /// than a count of barrier crossings: a side chain rattling in the gap
    /// between two wells would otherwise register dozens of jumps without ever
    /// having changed rotamer.
    ///
    /// The first frame has no previous state, so it falls back to the nearest
    /// well whatever the distance.
    public static func states(_ values: [Float]) -> [RotamerState] {
        var output: [RotamerState] = []
        output.reserveCapacity(values.count)
        var previous: RotamerState?

        for value in values {
            // `min(by:)` keeps the FIRST of equal elements, so a value exactly
            // between two wells (0 degrees is 60 from each gauche well) resolves
            // to the earlier case in `allCases`. Arbitrary but deterministic,
            // which is what matters: the alternative is a state assignment that
            // depends on collection order and a jump count that changes between
            // runs of the same trajectory.
            let nearest = RotamerState.allCases.min {
                abs(Geometry.angularDifference(from: value, to: $0.centre))
                    < abs(Geometry.angularDifference(from: value, to: $1.centre))
            } ?? .trans
            let distance = abs(Geometry.angularDifference(from: value, to: nearest.centre))
            if distance <= toleranceDegrees || previous == nil {
                previous = nearest
            }
            output.append(previous ?? nearest)
        }
        return output
    }

    /// Every transition in a track.
    public static func jumps(in track: TorsionTrack, sweeps: [Int]) -> [RotamerJump] {
        // A symmetric terminal group has no distinguishable rotamers to jump
        // between: aspartate's chi2 at -60 and at +120 are the same structure.
        // Counting those would fill the top-ten list with residues that never
        // changed at all.
        guard !track.isSymmetric else { return [] }

        let assigned = states(track.values)
        var output: [RotamerJump] = []
        for index in 1..<max(1, assigned.count) where assigned[index] != assigned[index - 1] {
            output.append(
                RotamerJump(
                    residueIndex: track.residueIndex, label: track.label, frame: index,
                    sweep: index < sweeps.count ? sweeps[index] : index,
                    from: assigned[index - 1], to: assigned[index]))
        }
        return output
    }

    /// Transition counts per residue, and the raster.
    public struct Report: Sendable {
        public let jumps: [RotamerJump]
        /// Jump count keyed by residue index.
        public let countsByResidue: [Int: Int]
        /// One row per residue that jumped at least once, each row the assigned
        /// state per frame. This is the raster the HUD draws.
        public let raster: [(residueIndex: Int, label: String, states: [RotamerState])]
        public let sweeps: [Int]

        /// Residues ordered by jump count, most first.
        public func busiest(limit: Int = 10) -> [(residueIndex: Int, label: String, jumps: Int)] {
            let labels = Dictionary(
                raster.map { ($0.residueIndex, $0.label) }, uniquingKeysWith: { first, _ in first })
            return countsByResidue
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(limit)
                .map { (residueIndex: $0.key, label: labels[$0.key] ?? "\($0.key)", jumps: $0.value) }
        }

        public var totalJumps: Int { jumps.count }

        /// What the number does and does not mean, said where it is produced.
        ///
        /// Measured on a 5,000 sweep run of a 335-residue protein: 15,889
        /// jumps. That is not a protein hopping barriers thermally, it is the
        /// SAMPLER proposing well-to-well moves 22% of the time and having
        /// about 38% of them accepted. With a discrete rotamer move in the mix
        /// the jump rate measures the move set at least as much as the
        /// molecule, and the number is only comparable BETWEEN runs that share
        /// a move mix, a throttle and a snapshot stride.
        ///
        /// Which is the honest version of what a crude sampler can offer: the
        /// ranking of residues is informative, the absolute rate is not a
        /// kinetic observable, and no part of this app claims otherwise.
        public var interpretation: String {
            "Jumps are counted between stored frames on a sampler that proposes "
                + "rotamer changes directly, so the rate reflects the move set as well "
                + "as the protein. Compare residues within a run, not rates between runs."
        }

        /// Jumps per thousand sweeps, which is the only rate this app quotes.
        public var jumpsPerThousandSweeps: Float {
            guard let last = sweeps.last, last > 0 else { return 0 }
            return Float(jumps.count) * 1000 / Float(last)
        }
    }

    public static func report(tracks: [TorsionTrack], sweeps: [Int]) -> Report {
        var allJumps: [RotamerJump] = []
        var counts: [Int: Int] = [:]
        var raster: [(Int, String, [RotamerState])] = []

        for track in tracks {
            let found = jumps(in: track, sweeps: sweeps)
            guard !found.isEmpty else { continue }
            allJumps.append(contentsOf: found)
            counts[track.residueIndex, default: 0] += found.count
            raster.append((track.residueIndex, track.label, states(track.values)))
        }
        allJumps.sort { ($0.sweep, $0.residueIndex) < ($1.sweep, $1.residueIndex) }
        raster.sort { $0.0 < $1.0 }

        return Report(
            jumps: allJumps, countsByResidue: counts,
            raster: raster.map { (residueIndex: $0.0, label: $0.1, states: $0.2) },
            sweeps: sweeps)
    }
}
