import XCTest

/// True end-to-end tests: launch the real app (simulator or physical device)
/// and drive it as a user would. Screenshots are attached to the result
/// bundle; app-side [trace] diagnostics stream to the console.
final class EndToEndTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The full pipeline against the bundled real-photo fixture (an actual
    /// kid's drawing photographed on an iPhone): capture-equivalent input →
    /// trace → visible paths on the canvas.
    func testBundledRealPhotoTracesToVisiblePaths() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DEMO_IMAGE"] = "bundled:fish-photo"
        app.launch()

        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "trace screen should appear")

        let paths = try waitForTracedPaths(on: canvas, timeout: 45)
        attachScreenshot(of: app, named: "traced-fish-photo")
        XCTAssertGreaterThan(paths, 5, "the fish drawing should trace to several visible paths")
        XCTAssertFalse(app.staticTexts["Nothing to Trace"].exists)
    }

    /// Camera hardware smoke test — only meaningful on a physical device.
    /// Points the camera at whatever is in front of it, so it asserts the app
    /// survives the full capture → trace flow, not trace content.
    func testCameraCaptureFlowSurvives() throws {
        let app = XCUIApplication()
        app.launch()

        let takePhoto = app.buttons["Take Photo"]
        guard takePhoto.waitForExistence(timeout: 5) else {
            throw XCTSkip("No camera on this destination")
        }
        // First run shows the camera permission alert.
        addUIInterruptionMonitor(withDescription: "camera permission") { alert in
            let allow = alert.buttons.matching(
                NSPredicate(format: "label IN %@", ["OK", "Allow", "Allow While Using App"])
            ).firstMatch
            if allow.exists { allow.tap(); return true }
            return false
        }
        takePhoto.tap()
        app.tap()   // deliver any pending interruption

        let shutter = app.buttons["PhotoCapture"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 15), "camera shutter should appear")
        shutter.tap()

        let usePhoto = app.buttons["Use Photo"]
        XCTAssertTrue(usePhoto.waitForExistence(timeout: 15))
        usePhoto.tap()

        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30), "should land on the trace screen")
        _ = try? waitForTracedPaths(on: canvas, timeout: 45)
        attachScreenshot(of: app, named: "traced-camera-capture")
        // Reaching a settled trace screen without crashing is the assertion;
        // an arbitrary camera scene may legitimately trace to nothing.
    }

    private func waitForTracedPaths(on canvas: XCUIElement, timeout: TimeInterval) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = canvas.value as? String,
               let count = Int(value.split(separator: " ").first ?? ""),
               count > 0 {
                return count
            }
            usleep(500_000)
        }
        return 0
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension EndToEndTests {
    /// Library rows must open their project's trace screen.
    func testLibraryRowOpensProject() throws {
        // First launch seeds a project via the demo hook, then we return to
        // the library and reopen it by tapping the row.
        let app = XCUIApplication()
        app.launchEnvironment["DEMO_IMAGE"] = "bundled:fish-photo"
        app.launch()

        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        app.navigationBars.buttons.firstMatch.tap()   // back to library

        let row = app.buttons["projectRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "library should list the project")
        attachScreenshot(of: app, named: "library-before-tap")
        row.tap()
        let opened = canvas.waitForExistence(timeout: 20)
        attachScreenshot(of: app, named: "after-row-tap")
        XCTAssertTrue(opened, "tapping a row should open the trace screen")
    }
}
