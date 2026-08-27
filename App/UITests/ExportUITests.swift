import XCTest

/// The export path, driven in the running app.
///
/// The package tests prove the exporter writes a file AVFoundation can read.
/// They say nothing about whether the app hands it the right frames, the right
/// caption and the right options, and that wiring is exactly where a working
/// exporter turns into a button that does nothing.
final class ExportUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testExportingAMovieProducesSomethingShareable() {
        let app = XCUIApplication()
        app.launchEnvironment["JUMPJET_AUTOLOAD"] = "P69905"
        // Short, because interface tests build DEBUG and a debug build samples
        // about 36 times slower than release.
        app.launchEnvironment["JUMPJET_AUTORUN"] = "200"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Export"].waitForExistence(timeout: 300),
            "the export panel never appeared")

        // Square 720 rather than 1080p: a sixth of the pixels per frame, and
        // what is being tested is the wiring, not the encoder's throughput.
        let square = app.buttons["Square 720"]
        if square.exists { square.tap() }

        let export = app.buttons["EXPORT MOVIE"]
        var attempts = 0
        while !export.isHittable && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(export.isHittable, "the export control was never reachable")
        export.tap()

        // The share link only appears once a file exists on disk.
        let share = app.buttons["Share the movie"]
        XCTAssertTrue(
            share.waitForExistence(timeout: 240),
            "the movie never finished, or finished without a file to share")
    }

    func testTheSortieReportCardRenders() {
        let app = XCUIApplication()
        app.launchEnvironment["JUMPJET_AUTOLOAD"] = "P69905"
        app.launchEnvironment["JUMPJET_AUTORUN"] = "200"
        app.launch()

        XCTAssertTrue(app.staticTexts["Export"].waitForExistence(timeout: 300))

        let card = app.buttons["Sortie report card"]
        var attempts = 0
        while !card.isHittable && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(card.isHittable)
        card.tap()

        XCTAssertTrue(
            app.buttons["Share the card"].waitForExistence(timeout: 60),
            "the report card did not render")
    }
}
