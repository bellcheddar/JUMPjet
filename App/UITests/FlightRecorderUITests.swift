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

        // The raster is there whenever anything jumped, which over 300 sweeps
        // it always does.
        XCTAssertTrue(
            scrollToElement(app, labelStartingWith: "Rotamer state raster"),
            "the jump raster has no accessible description")

        // The landscape and the transition matrix are CONDITIONAL, and the
        // condition is real rather than a flaky test: a short run may not move
        // two residues by eight degrees, in which case there is no plane to
        // project onto. The panel then says so, and this asserts one or the
        // other rather than pretending the absence is a failure.
        let hasLandscape = scrollToElement(app, labelStartingWith: "Conformational landscape")
        if !hasLandscape {
            XCTAssertTrue(
                app.staticTexts["NO PROJECTION"].exists,
                "no landscape and no explanation of why not")
        } else {
            XCTAssertTrue(
                scrollToElement(app, labelStartingWith: "Basin transition matrix"),
                "a landscape but no transition matrix")
        }
    }

    /// Scroll the instrument column looking for an element by label prefix.
    private func scrollToElement(
        _ app: XCUIApplication, labelStartingWith prefix: String
    ) -> Bool {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        var attempts = 0
        while !element.exists && attempts < 12 {
            app.swipeUp()
            attempts += 1
        }
        return element.exists
    }
}
