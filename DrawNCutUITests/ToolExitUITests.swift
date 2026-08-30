import XCTest

/// There must be a visible way out of an edit tool. Reported from the device:
/// after using the pen, "all of the sliders became deactivated... I don't know
/// how to get out." The only exit was tapping the same unlabelled icon again.
final class ToolExitUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testThePenToolCanBeLeftAndReleasesTheSliders() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DEMO_IMAGE"] = "bundled:fish-photo"
        app.launch()

        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))

        let threshold = app.sliders["slider-Threshold"]
        XCTAssertTrue(threshold.waitForExistence(timeout: 10))
        XCTAssertTrue(threshold.isEnabled, "sliders should start live")

        let pen = app.buttons["penToggle"]
        XCTAssertTrue(pen.exists)
        pen.tap()

        // The trap: sliders go dead and nothing says how to revive them.
        XCTAssertFalse(threshold.isEnabled, "the pen should pause the sliders")
        let done = app.buttons["finishEditing"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "no visible way out of the pen tool")

        done.tap()

        XCTAssertTrue(threshold.isEnabled, "Done did not give the sliders back")
        XCTAssertFalse(done.exists, "the Done button lingered after leaving the tool")
    }
}
