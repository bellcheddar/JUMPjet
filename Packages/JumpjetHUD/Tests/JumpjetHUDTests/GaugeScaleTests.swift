import XCTest

@testable import JumpjetHUD

final class GaugeScaleTests: XCTestCase {

    func testFractionMapsTheEndsAndTheMiddle() {
        let scale = GaugeScale(lower: 0, upper: 10)
        XCTAssertEqual(scale.fraction(of: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(scale.fraction(of: 5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scale.fraction(of: 10), 1, accuracy: 1e-9)
    }

    /// A needle that leaves its dial is worse than one pinned at the limit.
    func testFractionIsClampedAndPinningIsReportedSeparately() {
        let scale = GaugeScale(lower: 2, upper: 4)
        XCTAssertEqual(scale.fraction(of: -100), 0, accuracy: 1e-9)
        XCTAssertEqual(scale.fraction(of: 100), 1, accuracy: 1e-9)
        XCTAssertTrue(scale.isPinned(-100))
        XCTAssertTrue(scale.isPinned(100))
        XCTAssertFalse(scale.isPinned(3))
    }

    /// A constant signal is a legitimate thing for an instrument to show, so a
    /// zero-width range must widen rather than divide by zero on every reading.
    func testDegenerateRangeIsWidenedRatherThanTrapping() {
        let scale = GaugeScale(lower: 5, upper: 5)
        XCTAssertGreaterThan(scale.span, 0)
        XCTAssertTrue(scale.fraction(of: 5).isFinite)

        let inverted = GaugeScale(lower: 10, upper: 1)
        XCTAssertGreaterThan(inverted.span, 0)
        XCTAssertTrue(inverted.fraction(of: 10).isFinite)
    }

    func testNiceStepPicksOneTwoOrFiveTimesAPowerOfTen() {
        XCTAssertEqual(GaugeScale.niceStep(0.11), 0.1, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(0.3), 0.2, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(4), 5, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(9), 10, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(230), 200, accuracy: 1e-9)
    }

    /// A step that rounded to nothing, or a non-finite one, must not spin the
    /// tick loop forever.
    func testNiceStepIsDefendedAgainstNonsense() {
        XCTAssertEqual(GaugeScale.niceStep(0), 1, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(-3), 1, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(.nan), 1, accuracy: 1e-12)
        XCTAssertEqual(GaugeScale.niceStep(.infinity), 1, accuracy: 1e-12)
    }

    func testTicksAreRoundNumbersInsideTheScale() {
        let ticks = GaugeScale(lower: 0, upper: 10).ticks(approximately: 5)
        XCTAssertEqual(ticks, [0, 2, 4, 6, 8, 10])
    }

    func testTicksNeverEscapeTheScale() {
        for (lower, upper) in [(0.0, 1.0), (-7.3, 12.9), (100.0, 103.0), (0.0, 0.05)] {
            let scale = GaugeScale(lower: lower, upper: upper)
            for tick in scale.ticks() {
                XCTAssertGreaterThanOrEqual(tick, scale.lower - 1e-9, "scale \(lower)..\(upper)")
                XCTAssertLessThanOrEqual(tick, scale.upper + 1e-9, "scale \(lower)..\(upper)")
            }
        }
    }

    func testNiceScaleCoversTheDataWithRoundEnds() {
        let scale = GaugeScale.nice(covering: [0.3, 4.7, 2.1])
        XCTAssertLessThanOrEqual(scale.lower, 0.3)
        XCTAssertGreaterThanOrEqual(scale.upper, 4.7)
        XCTAssertEqual(scale.lower, 0, accuracy: 1e-9)
        XCTAssertEqual(scale.upper, 5, accuracy: 1e-9)
    }

    /// A flat series still needs a readable dial rather than a hairline.
    func testNiceScaleWidensAFlatSeries() {
        let scale = GaugeScale.nice(covering: [3, 3, 3], minimumSpan: 2)
        XCTAssertGreaterThanOrEqual(scale.span, 2)
        XCTAssertLessThanOrEqual(scale.lower, 3)
        XCTAssertGreaterThanOrEqual(scale.upper, 3)
    }

    func testEmptyDataGivesAUsableScale() {
        let scale = GaugeScale.nice(covering: [])
        XCTAssertGreaterThan(scale.span, 0)
    }
}

final class HUDFormatTests: XCTestCase {

    func testFixedWidthIsStableSoReadoutsDoNotReflow() {
        XCTAssertEqual(HUDFormat.fixed(1.5), "1.50")
        XCTAssertEqual(HUDFormat.fixed(1.0), "1.00")
        XCTAssertEqual(HUDFormat.fixed(0.126, decimals: 2), "0.13")
    }

    /// A NaN in a readout must show as an em-free dash, not as "nan": the
    /// sampler can produce one and an instrument saying "nan" reads as a crash.
    func testNonFiniteValuesShowADash() {
        XCTAssertEqual(HUDFormat.fixed(.nan), "—")
        XCTAssertEqual(HUDFormat.fixed(.infinity), "—")
        XCTAssertEqual(HUDFormat.percent(.nan), "—")
        XCTAssertEqual(HUDFormat.elapsed(.nan), "—")
        XCTAssertEqual(HUDFormat.elapsed(-1), "—")
    }

    func testCountsAreGrouped() {
        XCTAssertEqual(HUDFormat.count(5_000), "5,000")
        XCTAssertEqual(HUDFormat.count(142), "142")
    }

    func testPercentAndAngstroms() {
        XCTAssertEqual(HUDFormat.percent(0.42), "42%")
        XCTAssertEqual(HUDFormat.percent(0.4237, decimals: 1), "42.4%")
        XCTAssertEqual(HUDFormat.angstroms(1.234), "1.23 A")
    }

    func testElapsedIsMinutesAndSeconds() {
        XCTAssertEqual(HUDFormat.elapsed(0), "0:00")
        XCTAssertEqual(HUDFormat.elapsed(9), "0:09")
        XCTAssertEqual(HUDFormat.elapsed(75), "1:15")
        XCTAssertEqual(HUDFormat.elapsed(3_600), "60:00")
    }
}

final class PaletteTests: XCTestCase {

    /// The build plan's accessibility rule: never colour alone. Every semantic
    /// role must carry a distinct symbol as well as a distinct colour.
    func testEverySemanticRoleCarriesADistinctSymbol() {
        let symbols = HUDPalette.Role.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, HUDPalette.Role.allCases.count)
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }
}
