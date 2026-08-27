import XCTest
import JumpjetCore

@testable import JumpjetAnalysis

/// Jump detection against synthetic tracks with PLANTED transitions, which the
/// build plan's definition of done asks for by name.
///
/// Synthetic at the level of the angle series, not the coordinates. That is the
/// level the detector actually works at, and it means the expected answer is
/// known exactly rather than being whatever the sampler happened to produce. A
/// detector validated on its own engine's output is a detector that agrees with
/// itself.
final class JumpDetectionTests: XCTestCase {

    private func track(
        _ values: [Float], residue: Int = 7, kind: AminoAcid = .leucine,
        chiIndex: Int = 0, symmetric: Bool = false, ring: Bool = false
    ) -> TorsionTrack {
        TorsionTrack(
            residueIndex: residue, residueKind: kind, chainID: "A",
            label: "A:\(kind.rawValue) \(residue)", chiIndex: chiIndex, values: values,
            isSymmetric: symmetric, isFlippableRing: ring)
    }

    private func sweeps(_ count: Int, stride: Int = 25) -> [Int] {
        (0..<count).map { $0 * stride }
    }

    // MARK: - State assignment

    func testAnglesAreAssignedToTheNearestWell() {
        let values: [Float] = [-60, -45, 60, 75, 180, -175, 170]
        XCTAssertEqual(
            JumpDetection.states(values),
            [.gaucheMinus, .gaucheMinus, .gauchePlus, .gauchePlus, .trans, .trans, .trans])
    }

    /// The wrap is real: -175 and 175 are both trans, 10 degrees apart, not 350.
    func testTransSpansTheWrapPoint() {
        XCTAssertEqual(JumpDetection.states([179, -179]), [.trans, .trans])
        XCTAssertEqual(JumpDetection.states([150, -150]), [.trans, .trans])
    }

    /// A frame in no-man's-land inherits the previous state, exactly as the
    /// build plan specifies. Without that rule, a side chain rattling in the
    /// gap between two wells registers dozens of jumps having never changed
    /// rotamer at all.
    func testNoMansLandInheritsThePreviousState() {
        //            g-    gap    gap    g-     gap   g+
        let values: [Float] = [-60, -10, 5, -60, 10, 60]
        let states = JumpDetection.states(values)
        XCTAssertEqual(
            states, [.gaucheMinus, .gaucheMinus, .gaucheMinus, .gaucheMinus, .gaucheMinus,
                     .gauchePlus])
        XCTAssertEqual(JumpDetection.jumps(in: track(values), sweeps: sweeps(6)).count, 1)
    }

    /// A track that rattles in the gap forever must report ZERO jumps. This is
    /// the failure the inheritance rule exists to prevent, and it is the one
    /// that would fill the top-ten list with residues that never moved.
    func testRattlingInTheGapIsNotAJump() {
        let values: [Float] = (0..<200).map { $0 % 2 == 0 ? -25 : -5 }
        XCTAssertEqual(JumpDetection.jumps(in: track(values), sweeps: sweeps(200)).count, 0)
    }

    /// The first frame has no previous state, so it takes the nearest well
    /// however far away it is. Otherwise a trajectory starting mid-barrier
    /// would have no state at all.
    func testTheFirstFrameAlwaysGetsAState() {
        // The wells sit 120 degrees apart, so the midpoints between them are
        // at 0, 120 and -120. Picking a test value ON one of those tests the
        // tie-break rather than the assignment, which is a different thing and
        // is tested below.
        XCTAssertEqual(JumpDetection.states([-90]), [.gaucheMinus])
        XCTAssertEqual(JumpDetection.states([140]), [.trans])
        XCTAssertEqual(JumpDetection.states([30]), [.gauchePlus])

        // Exactly zero is 60 degrees from BOTH gauche wells. Which one wins is
        // arbitrary; that it wins every time is not, because a state assignment
        // depending on collection order gives the same trajectory different
        // jump counts on different runs.
        let tie = JumpDetection.states([0])
        XCTAssertTrue([.gaucheMinus, .gauchePlus].contains(tie[0]))
        for _ in 0..<20 { XCTAssertEqual(JumpDetection.states([0]), tie) }
    }

    // MARK: - Planted transitions

    /// Twelve planted transitions in a known order, and nothing else.
    func testPlantedTransitionsAreFoundExactly() {
        let plan: [(RotamerState, Int)] = [
            (.gaucheMinus, 10), (.trans, 8), (.gauchePlus, 6), (.trans, 9),
            (.gaucheMinus, 7), (.gauchePlus, 5), (.gaucheMinus, 12), (.trans, 4),
            (.gauchePlus, 11), (.trans, 6), (.gaucheMinus, 8), (.gauchePlus, 9),
            (.trans, 10),
        ]
        var values: [Float] = []
        for (state, frames) in plan {
            // A little jitter, so the test does not pass merely because every
            // value is exactly a well centre.
            for frame in 0..<frames {
                values.append(state.centre + (frame % 3 == 0 ? 8 : -6))
            }
        }

        let found = JumpDetection.jumps(in: track(values), sweeps: sweeps(values.count))
        XCTAssertEqual(found.count, plan.count - 1, "one jump per planted change")

        for (index, jump) in found.enumerated() {
            XCTAssertEqual(jump.from, plan[index].0)
            XCTAssertEqual(jump.to, plan[index + 1].0)
        }

        // And the frames they were found at are the frames they were planted at.
        var boundary = 0
        for (index, entry) in plan.dropLast().enumerated() {
            boundary += entry.1
            XCTAssertEqual(found[index].frame, boundary, "jump \(index)")
            XCTAssertEqual(found[index].sweep, boundary * 25)
        }
    }

    /// A track that never leaves its well has no jumps, however long it is.
    func testAStaticTrackHasNoJumps() {
        let values = [Float](repeating: -58, count: 500)
        XCTAssertTrue(JumpDetection.jumps(in: track(values), sweeps: sweeps(500)).isEmpty)
    }

    /// A symmetric terminal group has no distinguishable rotamers to jump
    /// between: aspartate's chi2 at -60 and at +120 are the same structure.
    func testSymmetricTorsionsReportNoJumps() {
        // Six frames, every consecutive pair in a different well: five jumps.
        let values: [Float] = [-60, 60, 180, -60, 60, 180]
        XCTAssertEqual(JumpDetection.jumps(in: track(values), sweeps: sweeps(6)).count, 5)
        XCTAssertTrue(
            JumpDetection.jumps(
                in: track(values, kind: .asparticAcid, chiIndex: 1, symmetric: true),
                sweeps: sweeps(6)
            ).isEmpty)
    }

    // MARK: - The report

    func testReportRanksTheBusiestResidues() {
        func rattler(_ residue: Int, changes: Int) -> TorsionTrack {
            var values: [Float] = []
            for index in 0..<(changes + 1) {
                values.append(contentsOf:
                    [Float](repeating: RotamerState.allCases[index % 3].centre, count: 4))
            }
            return track(values, residue: residue)
        }

        let tracks = [rattler(1, changes: 2), rattler(2, changes: 9), rattler(3, changes: 5)]
        // Pad to a common length so one sweeps array serves all three.
        let longest = tracks.map(\.values.count).max() ?? 0
        let report = JumpDetection.report(tracks: tracks, sweeps: sweeps(longest))

        XCTAssertEqual(report.busiest(limit: 3).map(\.residueIndex), [2, 3, 1])
        XCTAssertEqual(report.countsByResidue[2], 9)
        XCTAssertEqual(report.totalJumps, 2 + 9 + 5)
        XCTAssertEqual(report.raster.count, 3, "one raster row per residue that jumped")
    }

    /// A residue that never jumps gets no raster row, so the raster stays
    /// readable on a 300-residue protein where most side chains sit still.
    func testStaticResiduesAreLeftOutOfTheRaster() {
        let tracks = [
            track([Float](repeating: -60, count: 20), residue: 1),
            track(([Float](repeating: -60, count: 10) + [Float](repeating: 180, count: 10)),
                  residue: 2),
        ]
        let report = JumpDetection.report(tracks: tracks, sweeps: sweeps(20))
        XCTAssertEqual(report.raster.map(\.residueIndex), [2])
    }

    func testRatesAreQuotedPerThousandSweeps() {
        let values = ([Float](repeating: -60, count: 10) + [Float](repeating: 180, count: 10))
        let report = JumpDetection.report(
            tracks: [track(values)], sweeps: (0..<20).map { $0 * 100 })
        // One jump over 1,900 sweeps.
        XCTAssertEqual(report.jumpsPerThousandSweeps, 1000.0 / 1900.0, accuracy: 1e-4)
    }
}

/// Ring flips, and the symmetry rule that makes them different from jumps.
final class RingFlipTests: XCTestCase {

    private func ringTrack(_ values: [Float], residue: Int = 3, kind: AminoAcid = .phenylalanine)
        -> TorsionTrack
    {
        TorsionTrack(
            residueIndex: residue, residueKind: kind, chainID: "A",
            label: "A:\(kind.rawValue) \(residue)", chiIndex: 1, values: values,
            isSymmetric: kind.symmetricChiIndices.contains(1),
            isFlippableRing: kind.hasFlippableRing)
    }

    private func sweeps(_ count: Int) -> [Int] { (0..<count).map { $0 * 25 } }

    /// Three planted flips, and the wobble in between must not add a fourth.
    func testPlantedFlipsAreFoundExactly() {
        let values: [Float] = [
            90, 92, 88,      // settled
            -90,             // flip 1
            -88, -92,
            88,              // flip 2
            85, 91,
            -95,             // flip 3
            -90,
        ]
        let report = RingFlipDetection.report(
            chi2Tracks: [ringTrack(values)], sweeps: sweeps(values.count))

        XCTAssertEqual(report.totalFlips, 3)
        XCTAssertEqual(report.flips.map(\.frame), [3, 6, 9])
        XCTAssertEqual(report.flips.map(\.sweep), [75, 150, 225])
        XCTAssertEqual(report.countsByResidue[3], 3)
        for flip in report.flips {
            XCTAssertEqual(abs(flip.turnedBy), 180, accuracy: RingFlipDetection.toleranceDegrees)
        }
    }

    /// Small wobbles are not flips, however many of them there are.
    func testWobbleIsNotAFlip() {
        let values: [Float] = (0..<200).map { 90 + ($0 % 2 == 0 ? 15 : -15) }
        let report = RingFlipDetection.report(
            chi2Tracks: [ringTrack(values)], sweeps: sweeps(200))
        XCTAssertEqual(report.totalFlips, 0)
    }

    /// Only phenylalanine and tyrosine. Histidine and tryptophan rings look
    /// aromatic and are not symmetric, so a 180 degree rotation of one is a
    /// genuine conformational change and counting it as a flip would erase it.
    func testOnlyPheAndTyrRingsAreCounted() {
        let flipping: [Float] = [90, -90, 90, -90]
        for kind in [AminoAcid.phenylalanine, .tyrosine] {
            let report = RingFlipDetection.report(
                chi2Tracks: [ringTrack(flipping, kind: kind)], sweeps: sweeps(4))
            XCTAssertEqual(report.totalFlips, 3, "\(kind.rawValue) should flip")
            XCTAssertEqual(report.flippableResidues, [3])
        }
        for kind in [AminoAcid.histidine, .tryptophan] {
            let report = RingFlipDetection.report(
                chi2Tracks: [ringTrack(flipping, kind: kind)], sweeps: sweeps(4))
            XCTAssertEqual(report.totalFlips, 0, "\(kind.rawValue) has no symmetric ring")
            XCTAssertTrue(report.flippableResidues.isEmpty)
        }
    }

    /// The same 180 degrees that IS a flip must NOT be a rotamer jump. Both
    /// facts come from the same symmetry, which is why one module owns both.
    func testAFlipIsNotAlsoCountedAsARotamerJump() {
        let flipping: [Float] = [90, -90, 90, -90]
        let track = ringTrack(flipping)
        XCTAssertEqual(
            RingFlipDetection.report(chi2Tracks: [track], sweeps: sweeps(4)).totalFlips, 3)
        XCTAssertTrue(
            JumpDetection.jumps(in: track, sweeps: sweeps(4)).isEmpty,
            "a phenylalanine chi2 flip is not a conformational jump")
    }

    /// The denominator is reported, because three flips out of four rings is a
    /// different statement from three out of ninety.
    func testEveryFlippableRingIsCountedWhetherItFlippedOrNot() {
        let still = ringTrack([Float](repeating: 90, count: 10), residue: 1)
        let flipping = ringTrack([90, -90] + [Float](repeating: -90, count: 8), residue: 2)
        let report = RingFlipDetection.report(
            chi2Tracks: [still, flipping], sweeps: sweeps(10))
        XCTAssertEqual(report.flippableResidues, [1, 2])
        XCTAssertEqual(report.totalFlips, 1)
        XCTAssertFalse(report.caveat.isEmpty)
    }
}
