import Foundation
import JumpjetCore
import simd

/// Frames of coordinates and the sweeps they were taken at.
///
/// Plain arrays rather than the sampler's own type, so the analysis can be fed
/// a hand-built trajectory with known planted transitions. Every rate in here
/// is per SWEEP, per ground rule 3: sweeps are pseudo-time and no part of this
/// module converts them to anything else.
public struct TrajectoryFrames: Sendable {
    /// Flat, `frameCount * atomCount`.
    public let positions: [SIMD3<Float>]
    public let atomCount: Int
    /// The sweep each frame was taken at. Same length as the frame count.
    public let sweeps: [Int]

    public init(positions: [SIMD3<Float>], atomCount: Int, sweeps: [Int]) {
        precondition(atomCount > 0, "a trajectory needs atoms")
        precondition(
            positions.count == sweeps.count * atomCount,
            "\(positions.count) coordinates for \(sweeps.count) frames of \(atomCount) atoms")
        self.positions = positions
        self.atomCount = atomCount
        self.sweeps = sweeps
    }

    public var frameCount: Int { sweeps.count }

    public func frame(_ index: Int) -> ArraySlice<SIMD3<Float>> {
        let start = index * atomCount
        return positions[start..<(start + atomCount)]
    }

    /// One atom's position through the whole trajectory.
    public func track(atom: Int) -> [SIMD3<Float>] {
        (0..<frameCount).map { positions[$0 * atomCount + atom] }
    }
}

/// A named series against sweep number, which is what every chart in the flight
/// recorder plots.
public struct SweepSeries: Sendable, Hashable {
    public let label: String
    public let unit: String
    public let sweeps: [Int]
    public let values: [Float]

    public init(label: String, unit: String, sweeps: [Int], values: [Float]) {
        self.label = label
        self.unit = unit
        self.sweeps = sweeps
        self.values = values
    }

    public var range: ClosedRange<Float> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        return low == high ? low...(low + 1) : low...high
    }

    public var mean: Float {
        values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }
}

/// The per-trajectory basics: RMSD, radius of gyration, per-residue RMSF.
public enum TrajectoryStatistics {

    /// RMSD of every frame against frame 0, after Kabsch superposition.
    ///
    /// Superposed, because the sampler rotates whichever side of a torsion is
    /// smaller and the whole molecule therefore drifts and tumbles in the lab
    /// frame. Without the fit this would measure that tumbling and almost
    /// nothing else.
    public static func rmsd(_ trajectory: TrajectoryFrames) -> SweepSeries {
        guard trajectory.frameCount > 0 else {
            return SweepSeries(label: "RMSD", unit: "A", sweeps: [], values: [])
        }
        let reference = Array(trajectory.frame(0))
        let values = (0..<trajectory.frameCount).map { index in
            Geometry.superposedRMSD(moving: Array(trajectory.frame(index)), onto: reference)
        }
        return SweepSeries(
            label: "RMSD from start", unit: "A", sweeps: trajectory.sweeps, values: values)
    }

    public static func radiusOfGyration(_ trajectory: TrajectoryFrames) -> SweepSeries {
        let values = (0..<trajectory.frameCount).map {
            Geometry.radiusOfGyration(Array(trajectory.frame($0)))
        }
        return SweepSeries(
            label: "Radius of gyration", unit: "A", sweeps: trajectory.sweeps, values: values)
    }

    /// Per-residue root mean square fluctuation of the alpha carbons.
    ///
    /// Fluctuation about each atom's OWN mean position, not deviation from
    /// frame 0: RMSF asks how much a residue moves, and a residue that shifts
    /// once and then sits still has a large deviation and a small fluctuation.
    /// Every frame is superposed onto frame 0 first, for the same reason RMSD
    /// is.
    public static func rmsf(
        _ trajectory: TrajectoryFrames, structure: Structure
    ) -> [Float] {
        guard trajectory.frameCount > 1 else {
            return [Float](repeating: 0, count: structure.residueCount)
        }
        let reference = Array(trajectory.frame(0))
        var fitted: [[SIMD3<Float>]] = []
        fitted.reserveCapacity(trajectory.frameCount)
        for index in 0..<trajectory.frameCount {
            let frame = Array(trajectory.frame(index))
            let fit = Geometry.kabschSuperposition(moving: frame, onto: reference)
            fitted.append(Geometry.apply(fit, to: frame))
        }

        return structure.residues.indices.map { residueIndex in
            guard let atom = structure.alphaCarbonIndex(ofResidue: residueIndex) else { return 0 }
            var mean = SIMD3<Float>.zero
            for frame in fitted { mean += frame[atom] }
            mean /= Float(fitted.count)
            var total: Float = 0
            for frame in fitted { total += simd_length_squared(frame[atom] - mean) }
            return (total / Float(fitted.count)).squareRoot()
        }
    }
}

/// Spearman rank correlation.
///
/// Rank rather than Pearson because the validation panel compares RMSF in
/// angstroms against a flexibility prior on 0 to 1. There is no reason those
/// should be LINEARLY related, and a Pearson coefficient would report a
/// perfectly monotonic relationship as a weak one.
public enum Spearman {

    public static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 2 else { return 0 }
        let rankA = ranks(a)
        let rankB = ranks(b)
        let n = Float(a.count)
        let meanRank = (n + 1) / 2

        var numerator: Float = 0
        var sumA: Float = 0
        var sumB: Float = 0
        for index in 0..<a.count {
            let da = rankA[index] - meanRank
            let db = rankB[index] - meanRank
            numerator += da * db
            sumA += da * da
            sumB += db * db
        }
        let denominator = (sumA * sumB).squareRoot()
        return denominator > 1e-9 ? numerator / denominator : 0
    }

    /// Average ranks, so ties do not bias the coefficient.
    static func ranks(_ values: [Float]) -> [Float] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var output = [Float](repeating: 0, count: values.count)
        var index = 0
        while index < order.count {
            var last = index
            while last + 1 < order.count, values[order[last + 1]] == values[order[index]] {
                last += 1
            }
            let averageRank = Float(index + last) / 2 + 1
            for position in index...last { output[order[position]] = averageRank }
            index = last + 1
        }
        return output
    }
}
