import XCTest

/// The App Store screenshots, taken by driving the real app on a simulator
/// sized for the store (iPhone 6.5" and iPad 13"). Not part of the gate: run
/// it by name, then export the attachments (appstore/README.md).
///
///   xcodebuild test ... -only-testing:DrawNCutUITests/StoreScreenshotTests
final class StoreScreenshotTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testStoreScreenshots() throws {
        let bundle = Bundle(for: Self.self)
        let photo = try XCTUnwrap(bundle.url(forResource: "fish-circle-shadow-photo", withExtension: "jpg"))
        let mask = try XCTUnwrap(bundle.url(forResource: "fish-circle-shadow-mask", withExtension: "png"))

        let app = XCUIApplication()
        app.launchEnvironment["DEMO_IMAGE"] = photo.path
        app.launchEnvironment["DEMO_MASK"] = mask.path
        app.launch()

        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForTrace(on: canvas, timeout: 60), "the demo drawing did not trace")
        // The fixture is a whole page with the fish a third of it. Left at
        // fit-to-page: a pinch zooms about the canvas centre, which sits
        // under the control panel, and pushed the figure off the visible
        // part of the screen.
        sleep(1)
        shoot(app, "1-trace")

        // The export sheet, with a DXF made.
        let export = app.buttons["Export DXF"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let create = app.buttons["Create DXF"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        sleep(1)
        shoot(app, "3-export")
        create.tap()
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Share '")).firstMatch.waitForExistence(timeout: 20)
        sleep(1)
        shoot(app, "4-export-ready")

        // Back to the library, which now holds the drawing.
        app.swipeDown(velocity: .fast)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        _ = app.otherElements["projectRow"].firstMatch.waitForExistence(timeout: 10)
        sleep(2)
        shoot(app, "5-library")
    }

    private func waitForTrace(on canvas: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = canvas.value as? String,
               let count = Int(value.split(separator: " ").first ?? ""), count > 0 {
                return true
            }
            usleep(500_000)
        }
        return false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
