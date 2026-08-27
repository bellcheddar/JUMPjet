import XCTest
import JumpjetCore
import JumpjetParse
import simd

@testable import JumpjetEngine

/// Where the sampler's time actually goes.
///
/// Not assertions about speed, which would fail on a loaded machine: this
/// prints a breakdown so an optimisation can be aimed rather than guessed at.
final class BenchmarkTests: XCTestCase {

    func testWhereTheTimeGoes() throws {
        for fixture in ["AF-P69905-F1-model_v6.pdb", "AF-P04406-F1-model_v6.pdb"] {
            try report(fixture)
        }
    }

    /// The build plan's throughput target is 100 sweeps per second for a
    /// 300-residue protein. It is NOT asserted here: `swift test` builds debug
    /// by default, and the same 20 sweeps take 4.9 s debug against 0.14 s
    /// release, a factor of 36. An assertion would either fail every ordinary
    /// test run or be set so loose it measured nothing. Run
    /// `swift test -c release --filter BenchmarkTests` to see the real figures.
    private func report(_ fixture: String) throws {
        let structure = try PDBParser.parse(
            Fixtures.text("structures/\(fixture)"), source: .alphaFold
        ).structure
        // The REAL tables and a varying prior. Measured against
        // `TorsionTables.flat()` this ran 40% faster and accepted 65% of moves
        // instead of 37%, so it was measuring a configuration that does not
        // ship and flattering itself on both counts.
        let prior = (0..<structure.residueCount).map { index -> Float in
            0.15 + 0.7 * (sin(Float(index) / 20) * 0.5 + 0.5)
        }
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        let tables = try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))
        let topology = TorsionTopology(structure: structure)
        let model = EnergyModel(
            structure: structure, topology: topology, flexibility: prior, tables: tables)
        let positions = structure.positions

        print("\n--- structure ---")
        print("  \(structure.residueCount) residues, \(structure.atomCount) atoms")
        print("  \(topology.torsions.count) torsions, "
            + "\(model.networkA.count) network pairs")

        let backbone = topology.torsions.filter(\.isBackboneTorsion)
        let sideChain = topology.torsions.filter { !$0.isBackboneTorsion }
        let backboneMoving = backbone.map(\.movingAtoms.count)
        print("  backbone torsions move \(backboneMoving.reduce(0, +) / max(1, backbone.count))"
            + " atoms on average, up to \(backboneMoving.max() ?? 0)")
        print("  side-chain torsions move "
            + "\(sideChain.map(\.movingAtoms.count).reduce(0, +) / max(1, sideChain.count))"
            + " atoms on average")

        // How many candidates does one grid query return?
        let grid = NeighbourGrid(positions: positions, cutoff: model.stericCutoff)
        var candidates: [Int32] = []
        var totalCandidates = 0
        for index in 0..<structure.atomCount {
            candidates.removeAll(keepingCapacity: true)
            grid.appendNeighbours(of: positions[index], into: &candidates)
            totalCandidates += candidates.count
        }
        print("\n--- grid ---")
        let perQuery = totalCandidates / structure.atomCount
        let meanBackboneAtoms = backboneMoving.reduce(0, +) / max(1, backbone.count)
        print("  cell size \(grid.cellSize) A for a cutoff of \(model.stericCutoff) A")
        print("  \(perQuery) candidates per query")
        print("  one backbone move costs about \(meanBackboneAtoms * perQuery * 2) pair tests")

        func time(_ label: String, _ body: () -> Void) {
            let started = Date()
            body()
            print(String(format: "  %-34s %8.1f ms", (label as NSString).utf8String!,
                         Date().timeIntervalSince(started) * 1000))
        }

        print("\n--- costs ---")
        time("totalEnergy (all pairs), once") {
            _ = model.totalEnergy(positions: positions, topology: topology)
        }
        time("grid rebuild, once") {
            var g = grid
            g.rebuild(positions: positions)
        }
        time("Kabsch superposition, once") {
            _ = Geometry.superposedRMSD(moving: positions, onto: positions)
        }

        let sweeps = 40
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: prior, tables: tables,
            configuration: RunConfiguration(sweeps: sweeps, snapshotStride: 1000, seed: 1))
        var elapsed = Date()
        let trajectory = sampler.run()
        let seconds = Date().timeIntervalSince(elapsed)
        elapsed = Date()
        print(String(format: "  %-34s %8.1f ms  (%.1f sweeps/s)",
                     ("\(sweeps) sweeps" as NSString).utf8String!, seconds * 1000,
                     Double(sweeps) / seconds))
        print("  acceptance \(trajectory.acceptanceRatio)")
        print("")
    }
}
