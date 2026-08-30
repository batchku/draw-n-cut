import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Finding the coin in a photograph. Synthetic scenes here, because they let
/// the answer be known exactly; real photographs are the next step and the
/// reason this is split so the candidate stage can be swapped for a trained
/// detector without touching the fit or the scoring.
struct CoinDetectorTests {

    /// A page with a drawing on it and, optionally, a coin.
    static func page(
        size: Int = 600,
        coin: (center: CGPoint, rx: Double, ry: Double, angle: Double)?,
        drawing: Bool = true
    ) -> CGImage {
        TestCanvas.image(size: size) { ctx in
            if drawing {
                ctx.setLineWidth(4)
                ctx.move(to: CGPoint(x: 80, y: 420))
                ctx.addLine(to: CGPoint(x: 300, y: 520))
                ctx.addLine(to: CGPoint(x: 480, y: 400))
                ctx.strokePath()
            }
            guard let coin else { return }
            ctx.saveGState()
            ctx.translateBy(x: coin.center.x, y: coin.center.y)
            ctx.rotate(by: coin.angle)
            ctx.scaleBy(x: coin.rx, y: coin.ry)
            ctx.setFillColor(gray: 0.35, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
            ctx.restoreGState()
        }
    }

    @Test func aRoundCoinIsFoundWithItsSize() throws {
        let image = Self.page(coin: (CGPoint(x: 180, y: 180), 45, 45, 0))
        let found = try #require(CoinDetector.detect(in: image), "no coin found")
        #expect(abs(found.ellipse.semiMajor - 45) < 4, "got \(found.ellipse.semiMajor)")
        #expect(abs(found.ellipse.axisRatio - 1) < 0.08)
        #expect(found.confidence > 0.5, "low confidence \(found.confidence)")
    }

    @Test func aTiltedCoinIsFoundWithItsTilt() throws {
        let image = Self.page(coin: (CGPoint(x: 300, y: 200), 60, 34, 0.5))
        let found = try #require(CoinDetector.detect(in: image), "no coin found")
        #expect(abs(found.ellipse.semiMajor - 60) < 6, "got \(found.ellipse.semiMajor)")
        #expect(abs(found.ellipse.semiMinor - 34) < 6, "got \(found.ellipse.semiMinor)")
        // cos(tilt) = 34/60 -> about 0.96 rad.
        #expect(abs(found.ellipse.tilt - acos(34.0 / 60)) < 0.2, "got \(found.ellipse.tilt)")
    }

    /// The failure that matters: a page with no coin must report no coin,
    /// not pick the roundest bit of the drawing and warp the photo by it.
    @Test func aPageWithNoCoinReportsNothing() {
        let image = Self.page(coin: nil)
        #expect(CoinDetector.detect(in: image) == nil,
                "found a coin on a page that has none")
    }

    @Test func aBlankPageReportsNothing() {
        let image = Self.page(coin: nil, drawing: false)
        #expect(CoinDetector.detect(in: image) == nil)
    }

    /// End to end: detect, correct, and the scale is right. A 90px-wide coin
    /// is a quarter, so a pixel is 24.26/90 mm.
    @Test func detectionFeedsACorrectionWithRealScale() throws {
        let image = Self.page(coin: (CGPoint(x: 200, y: 220), 45, 45, 0))
        let found = try #require(CoinDetector.detect(in: image))
        let rectifier = try #require(CoinRectifier(ellipse: found.ellipse))
        let expected = 24.26 / 90
        #expect(abs(rectifier.millimetersPerPixel - expected) < expected * 0.12,
                "got \(rectifier.millimetersPerPixel), expected about \(expected)")
    }

    @Test func aTiltedDetectionCorrectsTheCoinRound() throws {
        let image = Self.page(coin: (CGPoint(x: 300, y: 260), 60, 36, 0.4))
        let found = try #require(CoinDetector.detect(in: image))
        let rectifier = try #require(CoinRectifier(ellipse: found.ellipse))
        // Apply the correction to the detected ellipse's own outline.
        let corrected = try #require(EllipseFit.fit(polygon: EllipseFitTests.contour(
            center: found.ellipse.center,
            semiMajor: found.ellipse.semiMajor,
            semiMinor: found.ellipse.semiMinor,
            angle: found.ellipse.angle
        ).map(rectifier.apply)))
        #expect(abs(corrected.axisRatio - 1) < 0.05,
                "still elliptical after correction: \(corrected.axisRatio)")
    }
}
