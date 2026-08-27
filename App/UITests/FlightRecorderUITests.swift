import XCTest

/// The flight recorder panels, verified in the running app.
///
/// A screenshot can only show what fits on screen, and the recorder is six
/// panels in a scrolling column. These assertions reach the ones a screenshot
/// cannot, which is why the raster, the terrain map and the jump matrix each
/// carry an accessibility label describing what they contain.
final class FlightRecorderUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchedWithACompletedRun() -> XCUIApplication {
        let app = XCUIApplication()
        // The same seams the screenshots use: load an accession and run it
        // without anybody having to drive the keyboard, which is the flakiest
        // part of any interface test.
        app.launchEnvironment["JUMPJET_AUTOLOAD"] = "P69905"
        // 300 sweeps, not 3,000. Interface tests build DEBUG, because that is
        // where `@testable` works, and a debug build samples about 36 times
        // slower than release. A sweep count chosen for release turns a
        // two-minute test into an hour-long one.
        app.launchEnvironment["JUMPJET_AUTORUN"] = "300"
        app.launch()
        return app
    }

    func testEveryFlightRecorderPanelAppears() {
        let app = launchedWithACompletedRun()

        // The run has to finish before the recorder exists. Generous, because
        // a simulator on a loaded machine is not a phone.
        let flightData = app.staticTexts["Flight data"]
        XCTAssertTrue(
            flightData.waitForExistence(timeout: 300),
            "the flight recorder never appeared")

        // 1 and 2: basics and validation.
        XCTAssertTrue(app.staticTexts["Validation"].exists)

        // 3, 4, 5 and 6, reached by scrolling the instrument column.
        let panels = ["Rotamer jumps", "Ring flips", "Terrain", "Basins"]
        for panel in panels {
            let element = app.staticTexts[panel]
            var attempts = 0
            while !element.exists && attempts < 12 {
                app.swipeUp()
                attempts += 1
            }
            XCTAssertTrue(element.exists, "the \(panel) panel never appeared")
        }
    }

    /// The three custom-drawn views are Canvas and Grid, which have no text of
    /// their own. Their accessibility labels are the only way anything, a test
    /// or a screen reader, can tell what they contain.
    func testTheDrawnViewsDescribeThemselves() {
        let app = launchedWithACompletedRun()
        XCTAssertTrue(
            app.staticTexts["Flight data"].waitForExistence(timeout: 300))

        let descriptions = [
            "Rotamer state raster", "Conformational landscape", "Basin transition matrix",
        ]
        for description in descriptions {
            let element = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", description))
                .firstMatch
            var attempts = 0
            while !element.exists && attempts < 12 {
                app.swipeUp()
                attempts += 1
            }
            XCTAssertTrue(element.exists, "no accessible element for \(description)")
        }
    }
}
