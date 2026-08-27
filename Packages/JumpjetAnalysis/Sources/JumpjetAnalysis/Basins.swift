import Foundation
import simd

/// The conformational landscape: occupancy, basins, dwell times and the jump
/// matrix between them.
///
/// Every rate here is per SWEEP, per ground rule 3. Nothing in this file knows
/// what a picosecond is.
public struct BasinAnalysis: Sendable {
    /// Basin assignment per frame.
    public let assignments: [Int]
    public let centres: [SIMD2<Float>]
    /// How many frames each basin holds.
    public let occupancy: [Int]
    /// Every continuous residence in a basin, in SWEEPS.
    public let dwellTimes: [(basin: Int, sweeps: Int)]
    /// `matrix[from][to]`, counting frame-to-frame moves.
    ///
    /// The DIAGONAL counts staying put, which is most of it: a trajectory that
    /// visits three basins for twelve frames each spends 33 intervals resident
    /// and 2 in transit. That is a property of a transition matrix and not a
    /// defect, and ``totalTransitions`` excludes it because a jump count that
    /// included residence would be a frame count with extra steps.
    public let jumpMatrix: [[Int]]
    /// Silhouette score of the chosen clustering, which is how k was picked.
    public let silhouette: Float
    public let chosenK: Int

    public var basinCount: Int { centres.count }

    /// Mean dwell in a basin, in sweeps.
    public func meanDwell(basin: Int) -> Float {
        let times = dwellTimes.filter { $0.basin == basin }.map { Float($0.sweeps) }
        guard !times.isEmpty else { return 0 }
        return times.reduce(0, +) / Float(times.count)
    }

    public var totalTransitions: Int {
        jumpMatrix.enumerated().reduce(0) { running, row in
            running + row.element.enumerated().reduce(0) {
                $0 + (row.offset == $1.offset ? 0 : $1.element)
            }
        }
    }

    /// Stated because a reader will otherwise take a dwell time as a measured
    /// lifetime rather than as a bound.
    public var caveat: String {
        "Dwell times are measured between STORED frames, so anything shorter than "
            + "the snapshot stride is invisible and every dwell is a multiple of it."
    }
}

/// A 2D occupancy landscape as free energy in kT: -ln(density).
public struct OccupancyLandscape: Sendable {
    public let bins: Int
    public let xRange: ClosedRange<Float>
    public let yRange: ClosedRange<Float>
    /// Row-major `[y][x]`, flattened. Higher is less occupied.
    public let energy: [Float]
    /// The value used for a bin nothing ever visited.
    public let ceiling: Float

    public func value(x: Int, y: Int) -> Float {
        guard x >= 0, x < bins, y >= 0, y < bins else { return ceiling }
        return energy[y * bins + x]
    }
}

public enum BasinFinder {

    /// The build plan caps k at five. More basins than that on a crude sampler
    /// is reading structure into noise.
    public static let maximumK = 5

    /// Cluster the projected trajectory, choosing k by silhouette.
    public static func analyse(_ projection: DihedralProjection) -> BasinAnalysis? {
        let points = projection.points
        guard points.count >= 8 else { return nil }

        var best: (k: Int, score: Float, assignments: [Int], centres: [SIMD2<Float>])?
        for k in 2...min(maximumK, points.count / 3) {
            guard let clustering = kMeans(points, k: k) else { continue }
            let score = silhouette(points, assignments: clustering.assignments, k: k)
            if best == nil || score > best!.score {
                best = (k, score, clustering.assignments, clustering.centres)
            }
        }
        guard let best else { return nil }

        var occupancy = [Int](repeating: 0, count: best.k)
        for assignment in best.assignments { occupancy[assignment] += 1 }

        // Dwell times in SWEEPS, from the sweep each frame was taken at rather
        // than from frame indices. The snapshot stride is a configuration
        // choice and a dwell time expressed in frames would change meaning when
        // somebody adjusted it.
        var dwells: [(Int, Int)] = []
        var runStart = 0
        for index in 1...best.assignments.count {
            let ended = index == best.assignments.count
                || best.assignments[index] != best.assignments[runStart]
            guard ended else { continue }
            let last = index - 1
            let sweepsHeld = projection.sweeps[last] - projection.sweeps[runStart]
            dwells.append((best.assignments[runStart], sweepsHeld))
            runStart = index
        }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: best.k), count: best.k)
        for index in 1..<best.assignments.count {
            matrix[best.assignments[index - 1]][best.assignments[index]] += 1
        }

        return BasinAnalysis(
            assignments: best.assignments, centres: best.centres, occupancy: occupancy,
            dwellTimes: dwells.map { (basin: $0.0, sweeps: $0.1) }, jumpMatrix: matrix,
            silhouette: best.score, chosenK: best.k)
    }

    /// The terrain map: a 2D histogram turned into -ln(density).
    public static func landscape(_ projection: DihedralProjection, bins: Int = 40)
        -> OccupancyLandscape
    {
        let points = projection.points
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let xRange = pad(xs.min() ?? 0, xs.max() ?? 1)
        let yRange = pad(ys.min() ?? 0, ys.max() ?? 1)

        var counts = [Float](repeating: 0, count: bins * bins)
        for point in points {
            let x = bin(point.x, in: xRange, bins: bins)
            let y = bin(point.y, in: yRange, bins: bins)
            counts[y * bins + x] += 1
        }
        // Smooth, so a few hundred frames do not read as a landscape of spikes.
        // A consequence worth knowing: a bin next to a populated one picks up
        // density and is no longer at the ceiling. That is what a density
        // ESTIMATE means, and it is why the ceiling marks "nothing near here"
        // rather than "nothing exactly here".
        counts = smooth(counts, bins: bins)

        let total = counts.reduce(0, +)
        // An unvisited bin is UNSAMPLED, not infinitely unfavourable. Capping it
        // is the difference between a contour map and a plot with a wall round
        // the edge, and the ceiling is reported so nobody reads it as measured.
        let ceiling: Float = 8
        var energy = [Float](repeating: ceiling, count: bins * bins)
        guard total > 0 else {
            return OccupancyLandscape(
                bins: bins, xRange: xRange, yRange: yRange, energy: energy, ceiling: ceiling)
        }
        // Unsampled bins are marked, not valued, until after the shift. The
        // first version stored the ceiling straight away and then subtracted
        // the minimum from EVERY bin, which quietly pulled the unsampled ones
        // down with the rest: an empty region reported 5.24 instead of the
        // ceiling, and how empty it looked depended on how deep the deepest
        // well happened to be.
        var lowest = Float.greatestFiniteMagnitude
        var measured = [Float](repeating: .infinity, count: bins * bins)
        for index in counts.indices where counts[index] > 0 {
            let value = -log(counts[index] / total)
            measured[index] = value
            lowest = min(lowest, value)
        }
        for index in energy.indices {
            energy[index] = measured[index].isFinite
                ? min(ceiling, measured[index] - lowest)
                : ceiling
        }
        return OccupancyLandscape(
            bins: bins, xRange: xRange, yRange: yRange, energy: energy, ceiling: ceiling)
    }

    // MARK: - Clustering

    /// k-means with a deterministic k-means++ start.
    ///
    /// Deterministic because two runs of the same analysis on the same
    /// trajectory must give the same basins. A random start gives different
    /// labels, a different k chosen by silhouette, and a jump matrix whose rows
    /// mean something else, all from a trajectory that has not changed.
    static func kMeans(_ points: [SIMD2<Float>], k: Int)
        -> (assignments: [Int], centres: [SIMD2<Float>])?
    {
        guard points.count > k, k > 0 else { return nil }
        var centres: [SIMD2<Float>] = [points[0]]
        while centres.count < k {
            // The farthest point from any existing centre, which is k-means++
            // with the randomness taken out.
            var farthest = 0
            var farthestDistance: Float = -1
            for (index, point) in points.enumerated() {
                let nearest = centres.map { simd_distance_squared(point, $0) }.min() ?? 0
                if nearest > farthestDistance {
                    farthestDistance = nearest
                    farthest = index
                }
            }
            centres.append(points[farthest])
        }

        var assignments = [Int](repeating: 0, count: points.count)
        for _ in 0..<100 {
            var changed = false
            for (index, point) in points.enumerated() {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (centre, position) in centres.enumerated() {
                    let distance = simd_distance_squared(point, position)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = centre
                    }
                }
                if assignments[index] != best {
                    assignments[index] = best
                    changed = true
                }
            }

            var sums = [SIMD2<Float>](repeating: .zero, count: k)
            var counts = [Float](repeating: 0, count: k)
            for (index, point) in points.enumerated() {
                sums[assignments[index]] += point
                counts[assignments[index]] += 1
            }
            for centre in 0..<k where counts[centre] > 0 {
                centres[centre] = sums[centre] / counts[centre]
            }
            if !changed { break }
        }
        // An empty cluster means k was too large for this data. Refusing is
        // better than returning a basin nothing is in.
        var occupancy = [Int](repeating: 0, count: k)
        for assignment in assignments { occupancy[assignment] += 1 }
        guard occupancy.allSatisfy({ $0 > 0 }) else { return nil }

        return (assignments, centres)
    }

    /// Mean silhouette over all points, which is how k is chosen.
    static func silhouette(_ points: [SIMD2<Float>], assignments: [Int], k: Int) -> Float {
        guard k > 1, points.count > k else { return -1 }
        var total: Float = 0
        for (index, point) in points.enumerated() {
            var sums = [Float](repeating: 0, count: k)
            var counts = [Float](repeating: 0, count: k)
            for (other, position) in points.enumerated() where other != index {
                sums[assignments[other]] += simd_distance(point, position)
                counts[assignments[other]] += 1
            }
            let own = assignments[index]
            guard counts[own] > 0 else { continue }
            let a = sums[own] / counts[own]
            var b = Float.greatestFiniteMagnitude
            for cluster in 0..<k where cluster != own && counts[cluster] > 0 {
                b = min(b, sums[cluster] / counts[cluster])
            }
            guard b < .greatestFiniteMagnitude, max(a, b) > 1e-9 else { continue }
            total += (b - a) / max(a, b)
        }
        return total / Float(points.count)
    }

    // MARK: - Helpers

    private static func pad(_ low: Float, _ high: Float) -> ClosedRange<Float> {
        if high - low < 1e-6 { return (low - 0.5)...(low + 0.5) }
        let margin = (high - low) * 0.05
        return (low - margin)...(high + margin)
    }

    private static func bin(_ value: Float, in range: ClosedRange<Float>, bins: Int) -> Int {
        let span = range.upperBound - range.lowerBound
        guard span > 1e-9 else { return 0 }
        let scaled = (value - range.lowerBound) / span * Float(bins)
        return min(bins - 1, max(0, Int(scaled)))
    }

    private static func smooth(_ counts: [Float], bins: Int) -> [Float] {
        var output = counts
        for y in 0..<bins {
            for x in 0..<bins {
                var total: Float = 0
                var weight: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < bins, ny >= 0, ny < bins else { continue }
                        let w: Float = (dx == 0 && dy == 0) ? 4 : 1
                        total += counts[ny * bins + nx] * w
                        weight += w
                    }
                }
                output[y * bins + x] = weight > 0 ? total / weight : 0
            }
        }
        return output
    }
}
