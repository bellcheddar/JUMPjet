import Foundation
import simd

/// A uniform spatial hash grid over the atoms, for steric neighbour lookup.
///
/// Rebuilt periodically rather than maintained incrementally, which the build
/// plan specifies ("rebuilt every N sweeps"). Between rebuilds atoms drift, so
/// the cells are made LARGER than the interaction cutoff by a margin: an atom
/// has to move further than that margin before a genuine contact is missed, and
/// the next rebuild corrects it.
///
/// The consequence is stated rather than hidden. A stale grid can only ever
/// MISS a repulsion, never invent one, so the failure mode is a slightly
/// under-repulsive sampler for a few sweeps and not a structure that explodes.
/// `gridAgreesWithAllPairs` in the tests pins the fresh case exactly.
public struct NeighbourGrid: Sendable {
    public let cellSize: Float
    public let margin: Float
    private var origin: SIMD3<Float>
    private var dimensions: SIMD3<Int32>
    /// CSR layout: `cellStart[c]..<cellStart[c+1]` indexes into `atoms`.
    private var cellStart: [Int32]
    private var atoms: [Int32]

    /// The margin is a straight trade against speed, and it was measured
    /// rather than chosen. At the original 3.0 the cells were 6.06 A wide for a
    /// 3.06 A cutoff and a 27-cell query returned 167 candidates, of which the
    /// overwhelming majority were far outside the cutoff and cost a distance
    /// test each. One backbone move came to 91,000 pair tests and the sampler
    /// ran at 1.35 sweeps per second.
    ///
    /// At 1.0 the cells are 4.06 A and a query returns roughly fifty. The
    /// margin still has a job: it is how far an atom may drift between rebuilds
    /// before a contact is missed, and the sampler now rebuilds every sweep.
    public init(positions: [SIMD3<Float>], cutoff: Float, margin: Float = 1.0) {
        self.cellSize = cutoff + margin
        self.margin = margin
        self.origin = .zero
        self.dimensions = SIMD3(1, 1, 1)
        self.cellStart = [0, 0]
        self.atoms = []
        rebuild(positions: positions)
    }

    public mutating func rebuild(positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        var lower = positions[0]
        var upper = positions[0]
        for position in positions {
            lower = simd_min(lower, position)
            upper = simd_max(upper, position)
        }
        origin = lower - SIMD3(repeating: cellSize)

        let span = (upper - lower) + SIMD3(repeating: 2 * cellSize)
        // Cap the grid so a structure with one stray atom a long way out does
        // not allocate a hundred million empty cells.
        dimensions = SIMD3(
            Int32(max(1, min(256, Int(span.x / cellSize) + 1))),
            Int32(max(1, min(256, Int(span.y / cellSize) + 1))),
            Int32(max(1, min(256, Int(span.z / cellSize) + 1))))

        let cellCount = Int(dimensions.x) * Int(dimensions.y) * Int(dimensions.z)
        var counts = [Int32](repeating: 0, count: cellCount + 1)
        var cellOf = [Int32](repeating: 0, count: positions.count)

        for (index, position) in positions.enumerated() {
            let cell = cellIndex(for: position)
            cellOf[index] = Int32(cell)
            counts[cell + 1] += 1
        }
        for cell in 1...cellCount { counts[cell] += counts[cell - 1] }

        var cursor = counts
        var packed = [Int32](repeating: 0, count: positions.count)
        for index in positions.indices {
            let cell = Int(cellOf[index])
            packed[Int(cursor[cell])] = Int32(index)
            cursor[cell] += 1
        }
        cellStart = counts
        atoms = packed
    }

    private func cellIndex(for position: SIMD3<Float>) -> Int {
        let relative = (position - origin) / cellSize
        let x = min(Int(dimensions.x) - 1, max(0, Int(relative.x)))
        let y = min(Int(dimensions.y) - 1, max(0, Int(relative.y)))
        let z = min(Int(dimensions.z) - 1, max(0, Int(relative.z)))
        return (z * Int(dimensions.y) + y) * Int(dimensions.x) + x
    }

    /// Append every atom in the 27 cells around `position` to `output`.
    ///
    /// All 27, with no per-cell culling. Culling on the distance from the query
    /// point to each cell's nearest face was tried and REVERTED, for two
    /// reasons that arrived together.
    ///
    /// It was slower: candidates per query fell from 63 to 52 and throughput
    /// fell with them, because the culling arithmetic costs more per cell than
    /// the handful of distance tests it saves.
    ///
    /// And it was wrong. The acceptance ratio moved, which for an identical
    /// seed means the energies moved. Culling at cutoff plus one drift margin
    /// looks right and is not: BOTH atoms drift between rebuilds, the moving
    /// one away from the position being queried and the neighbour away from the
    /// cell it was binned into. The safe reach is cutoff plus two margins,
    /// which is wider than a cell and leaves nothing to cull.
    public func appendNeighbours(of position: SIMD3<Float>, into output: inout [Int32]) {
        let relative = (position - origin) / cellSize
        let cx = min(Int(dimensions.x) - 1, max(0, Int(relative.x)))
        let cy = min(Int(dimensions.y) - 1, max(0, Int(relative.y)))
        let cz = min(Int(dimensions.z) - 1, max(0, Int(relative.z)))

        for dz in -1...1 {
            let z = cz + dz
            guard z >= 0, z < Int(dimensions.z) else { continue }
            for dy in -1...1 {
                let y = cy + dy
                guard y >= 0, y < Int(dimensions.y) else { continue }
                for dx in -1...1 {
                    let x = cx + dx
                    guard x >= 0, x < Int(dimensions.x) else { continue }
                    let cell = (z * Int(dimensions.y) + y) * Int(dimensions.x) + x
                    let range = Int(cellStart[cell])..<Int(cellStart[cell + 1])
                    output.append(contentsOf: atoms[range])
                }
            }
        }
    }

    public var cellCount: Int { cellStart.count - 1 }
}
