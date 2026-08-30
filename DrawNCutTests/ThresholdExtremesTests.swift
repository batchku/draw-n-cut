import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

/// The two ends of the Threshold slider, stated as the user stated them:
/// "at absolute zero I'd expect to see lots of noise as vector lines... a dot
/// with a pen should appear; at the maximum I should see no engraving lines."
///
/// These are the acceptance criteria for the control, so they are asserted
/// directly rather than inferred from a count trend.
struct ThresholdExtremesTests {

    /// A page with a single small pen dot and nothing else.
    static func pageWithADot(size: Int = 400, gray: Double = 0.35) -> CGImage {
        TestCanvas.image(size: size) { ctx in
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: size / 2 - 5, y: size / 2 - 5, width: 10, height: 10))
        }
    }

    private func inkCount(_ image: CGImage, threshold: Double) throws -> Int {
        try #require(BinaryBitmap(cgImage: image, threshold: threshold)).pixels.count { $0 }
    }

    @Test func aSinglePenDotSurvivesTheLowestThreshold() throws {
        let ink = try inkCount(Self.pageWithADot(), threshold: 0)
        #expect(ink > 0, "a pen dot vanished at the bottom of the slider")
    }

    /// Even a faint one. This is the case the previous scheme could not do:
    /// the bar it moved was not what rejected a light mark.
    @Test func aFaintPenDotAlsoSurvivesTheLowestThreshold() throws {
        let ink = try inkCount(Self.pageWithADot(gray: 0.88), threshold: 0)
        #expect(ink > 0, "a faint pen dot vanished at the bottom of the slider")
    }

    @Test func theLowestThresholdBringsUpPaperNoiseAsWell() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let dense = try inkCount(image, threshold: 0)
        let normal = try inkCount(image, threshold: BinaryBitmap.defaultThreshold)
        #expect(dense > 3 * normal,
                "the bottom of the slider is not dense: \(normal) → \(dense) ink pixels")
    }

    /// The other end has to mean *nothing*, on any image.
    @Test func theHighestThresholdLeavesNothingAtAll() throws {
        for name in ["fish-photo", "butterfly-screen-photo", "fish-circle-shadow-photo"] {
            let image = try FixtureTraceTests.fixtureImage(name, extension: "jpg")
            #expect(try inkCount(image, threshold: 1) == 0,
                    "\(name) still had ink at maximum Threshold")
        }
    }

    @Test func theHighestThresholdTracesNoEngraveLines() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let traced = TraceEngine.trace(image: image, detail: 0.7, threshold: 1)
        let lines = traced?.elements.reduce(0) { $0 + $1.polylines.count } ?? 0
        #expect(lines == 0, "maximum Threshold still produced \(lines) engrave lines")
    }

    /// Monotonicity is a property of Sauvola's formula, not of tuning: s is
    /// capped at R, so the bracket never exceeds 1 and the threshold can only
    /// fall as k rises. Pinned here so a future mapping change cannot break it.
    @Test func theThresholdFallsAsTheSliderRises() {
        var previous = -Double.infinity
        for step in 0...20 {
            let k = InkThreshold(slider: Double(step) / 20).k
            #expect(k >= previous, "k dipped at step \(step)")
            previous = k
        }
        // Not 0: at exactly the local mean about half of any photograph is
        // "ink", which is a filled page rather than lines. See InkThreshold.
        #expect(InkThreshold(slider: 0).k <= 0.03,
                "the lowest setting must sit at the dense end of Sauvola's useful range")
        #expect(InkThreshold(slider: 1).k >= InkThreshold.silentK,
                "the highest setting must reach the silent point")
    }
}
