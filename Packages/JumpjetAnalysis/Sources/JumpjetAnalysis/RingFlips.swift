import Foundation
import JumpjetCore

/// One aromatic ring flip.
public struct RingFlip: Sendable, Hashable {
    public let residueIndex: Int
    public let label: String
    public let residueKind: AminoAcid
    public let frame: Int
    public let sweep: Int
    /// How far chi2 actually turned, in degrees. Near 180 by construction.
    public let turnedBy: Float
}

/// Symmetry-aware ring flip detection for phenylalanine and tyrosine.
///
/// The apparent paradox is worth stating, because it decides the whole design.
/// A phenylalanine ring rotated by 180 degrees is the SAME STRUCTURE: CD1 lands
/// where CD2 was and the two are chemically identical. So a flip changes
/// nothing you could measure in a single snapshot.
///
/// In a trajectory it is visible anyway, because chi2 is measured through the
/// atom NAMED CD1, and that named atom really has moved to the other side. A
/// flip is therefore a change of about 180 degrees in the measured chi2 between
/// consecutive frames, and the same 180 degrees must NOT be counted as a
/// conformational jump by the rotamer analysis. Both facts come from the same
/// symmetry, which is why one module owns both.
///
/// Histidine and tryptophan rings look aromatic and are NOT symmetric, so their
/// 180 degree rotations are genuine conformational changes. `AminoAcid`
/// already knows the difference and this module asks it rather than deciding.
public enum RingFlipDetection {

    /// How close to a full 180 degrees a turn must be to count as a flip.
    ///
    /// Generous, because between two stored frames the ring has had a whole
    /// snapshot stride of sweeps to arrive, and it need not land exactly.
    public static let toleranceDegrees: Float = 50

    public struct Report: Sendable {
        public let flips: [RingFlip]
        public let countsByResidue: [Int: Int]
        /// Every flippable ring in the structure, whether it flipped or not.
        /// The denominator matters: three flips out of four rings is a
        /// different statement from three out of ninety.
        public let flippableResidues: [Int]
        public let sweeps: [Int]

        public var totalFlips: Int { flips.count }

        public func busiest(limit: Int = 10) -> [(residueIndex: Int, label: String, flips: Int)] {
            let labels = Dictionary(
                flips.map { ($0.residueIndex, $0.label) }, uniquingKeysWith: { first, _ in first })
            return countsByResidue
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(limit)
                .map {
                    (residueIndex: $0.key, label: labels[$0.key] ?? "\($0.key)", flips: $0.value)
                }
        }

        /// Flips per thousand sweeps.
        public var flipsPerThousandSweeps: Float {
            guard let last = sweeps.last, last > 0 else { return 0 }
            return Float(flips.count) * 1000 / Float(last)
        }

        /// What the analysis can and cannot see, said out loud.
        public var caveat: String {
            "Flips are counted between stored frames, so a ring that flips and flips "
                + "back inside one snapshot stride is invisible. The count is a floor."
        }
    }

    public static func report(chi2Tracks: [TorsionTrack], sweeps: [Int]) -> Report {
        var flips: [RingFlip] = []
        var counts: [Int: Int] = [:]
        var flippable: [Int] = []

        for track in chi2Tracks where track.isFlippableRing {
            flippable.append(track.residueIndex)
            for index in 1..<max(1, track.values.count) {
                let turn = Geometry.angularDifference(
                    from: track.values[index - 1], to: track.values[index])
                guard abs(abs(turn) - 180) <= toleranceDegrees else { continue }
                flips.append(
                    RingFlip(
                        residueIndex: track.residueIndex, label: track.label,
                        residueKind: track.residueKind, frame: index,
                        sweep: index < sweeps.count ? sweeps[index] : index,
                        turnedBy: turn))
                counts[track.residueIndex, default: 0] += 1
            }
        }
        flips.sort { ($0.sweep, $0.residueIndex) < ($1.sweep, $1.residueIndex) }
        return Report(
            flips: flips, countsByResidue: counts, flippableResidues: flippable.sorted(),
            sweeps: sweeps)
    }
}
