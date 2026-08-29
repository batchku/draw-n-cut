import XCTest

/// Tapping a traced line on the canvas must turn it into a CUT path. This is
/// driven through the real gesture stack because the session-level logic was
/// already correct when the feature broke -- what regressed was the view.
final class CutTapUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DEMO_IMAGE"] = "bundled:fish-photo"
        app.launch()
        return app
    }

    /// "N paths, M cuts" — the canvas publishes both so a tap's effect is
    /// observable from here.
    private func cuts(_ value: String) -> Int? {
        guard let range = value.range(of: ", "),
              let count = Int(value[range.upperBound...].split(separator: " ").first ?? "") else {
            return nil
        }
        return count
    }

    func testTappingALineTurnsItIntoACut() throws {
        let app = launchedApp()
        let canvas = app.otherElements["traceCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))

        // Wait for the trace to produce paths before touching anything.
        let traced = NSPredicate(format: "value BEGINSWITH[c] %@", "0 paths") 
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, canvas.value as? String == nil
            || traced.evaluate(with: canvas) {
            usleep(200_000)
        }
        let before = try XCTUnwrap(cuts(try XCTUnwrap(canvas.value as? String)))

        // Sweep a few points across the drawing: the fixture's strokes do not
        // sit at a known coordinate, so try several and require one to land.
        var after = before
        for (dx, dy) in [(0.5, 0.5), (0.5, 0.42), (0.42, 0.5), (0.58, 0.5), (0.5, 0.58)] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            usleep(400_000)
            after = try XCTUnwrap(cuts(try XCTUnwrap(canvas.value as? String)))
            if after != before { break }
        }
        XCTAssertNotEqual(after, before, "tapping a line did not change the cut count")
    }
}
