import XCTest
import JumpjetCore
import JumpjetEngine
import JumpjetParse
import simd

@testable import JumpjetAnalysis

/// The whole flight recorder, end to end on a real sampled trajectory.
///
/// The synthetic tests pin the detectors against known answers. This one checks
/// they survive contact with real data, and times the analysis against the
/// budget the build plan's definition of done sets.
final class FlightRecorderTests: XCTestCase {

    private func run(
        fixture: String, sweeps: Int, stride: Int, seed: UInt64 = 17
    ) throws -> (Structure, TrajectoryFrames, [Float]) {
        let structure = try StructureReader.parse(
            Fixtures.text("structures/\(fixture)"),
            source: fixture.hasPrefix("AF") ? .alphaFold : .pdbe
        ).structure
        let models = Fixtures.root.deletingLastPathComponent()
            .appendingPathComponent("Models")
        let tables = try TorsionTables.load(
            from: models.appendingPathComponent("torsion_tables.json"))
        let prior = (0..<structure.residueCount).map { index -> Float in
            0.15 + 0.7 * (sin(Float(index) / 20) * 0.5 + 0.5)
        }
        let sampler = MonteCarloSampler(
            structure: structure, flexibility: prior, tables: tables,
            configuration: RunConfiguration(
                sweeps: sweeps, snapshotStride: stride, seed: seed))
        let trajectory = sampler.run()
        return (
            structure,
            TrajectoryFrames(
                positions: trajectory.positions, atomCount: trajectory.atomCount,
                sweeps: trajectory.sweeps),
            prior
        )
    }

    /// All six panels populate for a real run, and the numbers are sane.
    func testEverySixPanelPopulatesOnARealTrajectory() throws {
        let (structure, trajectory, prior) = try run(
            fixture: "AF-P69905-F1-model_v6.pdb", sweeps: 2_000, stride: 25)
        let record = FlightRecorder.analyse(
            structure: structure, trajectory: trajectory, flexibility: prior)

        // 1. Per-trajectory basics.
        XCTAssertEqual(record.rmsd.values.count, trajectory.frameCount)
        XCTAssertEqual(record.rmsd.values.first ?? -1, 0, accuracy: 1e-4, "frame 0 against itself")
        XCTAssertGreaterThan(record.rmsd.values.last ?? 0, 0.1, "the protein should have moved")
        XCTAssertEqual(record.radiusOfGyration.values.count, trajectory.frameCount)
        XCTAssertEqual(record.rmsf.count, structure.residueCount)
        XCTAssertTrue(record.rmsf.allSatisfy { $0.isFinite && $0 >= 0 })

        // 2. Validation panel.
        let rho = try XCTUnwrap(record.rmsfVersusPrior)
        XCTAssertTrue(rho.isFinite)
        XCTAssertTrue((-1...1).contains(rho))
        print("Spearman rho, RMSF against the flexibility prior: \(rho)")

        // 3. Rotamer jumps.
        XCTAssertGreaterThan(record.rotamerJumps.totalJumps, 0, "2,000 sweeps should jump")
        XCTAssertFalse(record.rotamerJumps.busiest().isEmpty)
        for row in record.rotamerJumps.raster {
            XCTAssertEqual(row.states.count, trajectory.frameCount)
        }

        // 4. Ring flips: the structure has flippable rings, whether or not any
        // flipped in this particular run.
        XCTAssertFalse(record.ringFlips.flippableResidues.isEmpty)

        // 5. Basins and the landscape.
        let projection = try XCTUnwrap(record.projection)
        XCTAssertEqual(projection.frameCount, trajectory.frameCount)
        XCTAssertGreaterThan(projection.explainedVariance.x, 0)
        let landscape = try XCTUnwrap(record.landscape)
        XCTAssertTrue(landscape.energy.allSatisfy(\.isFinite))
        let basins = try XCTUnwrap(record.basins)
        XCTAssertGreaterThanOrEqual(basins.basinCount, 2)
        XCTAssertLessThanOrEqual(basins.basinCount, BasinFinder.maximumK)
        XCTAssertEqual(basins.assignments.count, trajectory.frameCount)

        // 6. Everything a report card needs to point back at the structure.
        XCTAssertEqual(record.hotspots(structure: structure).count, 5)
        XCTAssertFalse(record.summary.isEmpty)
    }

    /// The definition of done: all six panels for a 5,000 sweep run of a
    /// 300-residue protein in under five seconds of POST-PROCESSING. The
    /// sampling itself is not in the budget and is not counted here.
    ///
    /// Opt-in, and the reason is worth recording: the test takes four minutes,
    /// of which the analysis is 0.02 SECONDS. All of it is generating the
    /// trajectory to analyse, at the 22 sweeps per second the sampler manages
    /// on 335 residues. A four-minute test that spends 99.99% of itself outside
    /// the thing being measured does not belong in a suite anyone runs before a
    /// commit, and `testTheTimingBudgetOnAShorterRun` keeps a cheap version of
    /// the same check.
    ///
    ///     JUMPJET_LONGRUN=1 swift test -c release --filter FlightRecorderTests
    func testTheDefinitionOfDoneTimingBudget() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JUMPJET_LONGRUN"] != nil,
            "set JUMPJET_LONGRUN=1 for the full 5,000 sweep budget check")

        let (structure, trajectory, prior) = try run(
            fixture: "AF-P04406-F1-model_v6.pdb", sweeps: 5_000, stride: 25)
        XCTAssertEqual(structure.residueCount, 335)
        XCTAssertEqual(trajectory.frameCount, 201)

        let record = FlightRecorder.analyse(
            structure: structure, trajectory: trajectory, flexibility: prior)

        print(String(
            format: "flight recorder: %d residues, %d frames, %.2f s",
            structure.residueCount, trajectory.frameCount, record.secondsToCompute))
        print("  \(record.summary)")

        XCTAssertLessThan(
            record.secondsToCompute, 5.0,
            "the build plan budgets five seconds of post-processing")
        XCTAssertNotNil(record.basins)
        XCTAssertNotNil(record.landscape)
    }

    /// The same budget on a shorter run, so the everyday suite still notices if
    /// the analysis becomes quadratic in something.
    func testTheTimingBudgetOnAShorterRun() throws {
        let (structure, trajectory, prior) = try run(
            fixture: "AF-P04406-F1-model_v6.pdb", sweeps: 600, stride: 10)
        XCTAssertEqual(structure.residueCount, 335)
        XCTAssertEqual(trajectory.frameCount, 61)

        let record = FlightRecorder.analyse(
            structure: structure, trajectory: trajectory, flexibility: prior)
        print(String(
            format: "flight recorder: %d residues, %d frames, %.3f s",
            structure.residueCount, trajectory.frameCount, record.secondsToCompute))
        XCTAssertLessThan(record.secondsToCompute, 5.0)
        XCTAssertNotNil(record.basins)
    }

    /// A multi-chain crystal structure must not confuse the analysis: phi and
    /// psi are undefined across a chain break, and a residue borrowed from the
    /// next chain would give a torsion measured through empty space.
    func testMultipleChainsAreHandled() throws {
        let (structure, trajectory, prior) = try run(
            fixture: "1bab.pdb", sweeps: 400, stride: 50)
        XCTAssertEqual(structure.chains.count, 4)

        let record = FlightRecorder.analyse(
            structure: structure, trajectory: trajectory, flexibility: prior)
        XCTAssertEqual(record.rmsf.count, structure.residueCount)

        // No residue at a chain boundary contributes backbone torsions.
        let boundaries = Set(structure.chains.flatMap {
            [$0.residueRange.lowerBound, $0.residueRange.upperBound - 1]
        })
        let projected = Set(record.projection?.residueIndices ?? [])
        XCTAssertTrue(
            projected.isDisjoint(with: boundaries),
            "a chain terminus has no phi or no psi and must not be projected")
    }

    /// Without a prior there is no validation panel, and the record says so
    /// rather than reporting a correlation against nothing.
    func testNoPriorMeansNoValidationPanel() throws {
        let (structure, trajectory, _) = try run(
            fixture: "AF-P69905-F1-model_v6.pdb", sweeps: 300, stride: 50)
        let record = FlightRecorder.analyse(structure: structure, trajectory: trajectory)
        XCTAssertNil(record.rmsfVersusPrior)
        XCTAssertNil(record.flexibilityPrior)
        XCTAssertGreaterThan(record.rmsf.count, 0)
    }
}

/// Spearman against hand-computed cases.
final class SpearmanTests: XCTestCase {

    func testPerfectMonotonicRelationshipsScoreOne() {
        XCTAssertEqual(Spearman.correlation([1, 2, 3, 4, 5], [10, 20, 30, 40, 50]), 1,
                       accuracy: 1e-5)
        XCTAssertEqual(Spearman.correlation([1, 2, 3, 4, 5], [5, 4, 3, 2, 1]), -1,
                       accuracy: 1e-5)
    }

    /// The reason it is Spearman and not Pearson: RMSF is in angstroms and the
    /// prior is on 0 to 1, and there is no reason they should be LINEARLY
    /// related. A perfectly monotonic but curved relationship is a perfect
    /// answer here, and Pearson would call it 0.94.
    func testAMonotonicCurveStillScoresOne() {
        let x: [Float] = [1, 2, 3, 4, 5, 6]
        let y = x.map { $0 * $0 * $0 }
        XCTAssertEqual(Spearman.correlation(x, y), 1, accuracy: 1e-5)
    }

    func testTiesAreRankedByAverage() {
        XCTAssertEqual(Spearman.ranks([5, 5, 5]), [2, 2, 2])
        XCTAssertEqual(Spearman.ranks([1, 2, 2, 4]), [1, 2.5, 2.5, 4])
    }

    func testDegenerateInputsScoreZeroRatherThanNaN() {
        XCTAssertEqual(Spearman.correlation([1, 1, 1, 1], [1, 2, 3, 4]), 0)
        XCTAssertEqual(Spearman.correlation([], []), 0)
        XCTAssertEqual(Spearman.correlation([1, 2], [1, 2]), 0, "too few points to rank")
    }
}
