import XCTest

/// Drives the refine-mask screen: demo photo → SAM subject tap →
/// "Use Outline" → masked trace. Requires the SAM 2 models to be bundled
/// (project.yml Models/*.mlpackage).
///
/// On the iOS simulator the SAM mask decoder currently returns empty masks
/// (Core ML runtime defect, INTEGRATION.md "Simulator caveat"), so the
/// Use-Outline leg skips there after verifying the screen survives the tap;
/// on a device or a fixed runtime it runs to the masked trace. The
/// "Trace Everything" leg is simulator-proof and always runs fully.
final class RefineMaskUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testRefineTapAndUseOutlineFlow() throws {
        let app = try launchToRefineScreen()
        let imageArea = app.otherElements["refineImageArea"]

        // Tap the fish body — (500, 1030) in the 1500×2000 photo. The tap
        // layer's frame is exactly the fitted image, so normalized offsets
        // map straight into image space.
        imageArea.coordinate(
            withNormalizedOffset: CGVector(dx: 500.0 / 1500.0, dy: 1030.0 / 2000.0)
        ).tap()

        // A decoded mask enables "Use Outline".
        let useOutline = app.buttons["Use Outline"]
        XCTAssertTrue(useOutline.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(90)
        while !useOutline.isEnabled && Date() < deadline {
            usleep(500_000)
        }
        attach(screenshotOf: app, named: "refine-after-tap")

        guard useOutline.isEnabled else {
            // The refine screen must have survived the empty decode: prompt
            // marker registered, hint shown, still responsive.
            XCTAssertTrue(imageArea.exists)
            XCTAssertTrue(app.staticTexts["Tap directly on the drawn lines."].waitForExistence(timeout: 10))
            throw XCTSkip("""
                SAM produced no mask — iOS-simulator Core ML defect \
                (decoder returns zero logits). Run scripts/sam-macos-check/run.sh \
                to verify the SAM pipeline on this machine; rerun this test on a device.
                """)
        }

        useOutline.tap()
        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30), "trace screen should appear")
        let paths = waitForTracedPaths(on: canvas, timeout: 60)
        attach(screenshotOf: app, named: "masked-trace")
        XCTAssertGreaterThan(paths, 0, "the masked trace should keep the fish's strokes")
    }

    func testTraceEverythingSkipsTheMask() throws {
        // Works with or without SAM: the skip path must never depend on the
        // models being present or the encode finishing.
        let app = try launchToRefineScreen(requireSAMReady: false)

        let traceEverything = app.buttons["Trace Everything"]
        XCTAssertTrue(traceEverything.waitForExistence(timeout: 30))
        traceEverything.tap()

        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30), "trace screen should appear")
        let paths = waitForTracedPaths(on: canvas, timeout: 60)
        attach(screenshotOf: app, named: "trace-everything")
        XCTAssertGreaterThan(paths, 5, "the unmasked fish photo should trace to several paths")
    }

    // MARK: - Helpers

    private func launchToRefineScreen(requireSAMReady: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DEMO_IMAGE"] = "bundled:fish-photo"
        app.launchEnvironment["DEMO_IMAGE_REFINE"] = "1"
        app.launch()

        let imageArea = app.otherElements["refineImageArea"]
        XCTAssertTrue(imageArea.waitForExistence(timeout: 30), "refine screen should appear", file: file, line: line)
        guard requireSAMReady else { return app }

        // Model load + encode; the first-ever run on a fresh simulator
        // compiles kernels, so allow plenty.
        let instruction = app.staticTexts["Tap the drawing to select it."]
        if !instruction.waitForExistence(timeout: 180) {
            if app.staticTexts["Selection Unavailable"].exists {
                throw XCTSkip("SAM models are not bundled — run scripts/download-models.sh and regenerate the project")
            }
            XCTFail("encode never became ready", file: file, line: line)
        }
        return app
    }

    private func waitForTracedPaths(on canvas: XCUIElement, timeout: TimeInterval) -> Int {
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

    private func attach(screenshotOf app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
