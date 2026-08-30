import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// A coin in the photo gives two things at once: how far off square the shot
/// was, and how big a pixel is in the real world. The geometry is pinned here
/// against synthetic ellipses with known answers, so a detector regression
/// cannot be mistaken for a maths regression.
struct EllipseFitTests {

    /// Samples a closed contour from an ellipse with known parameters.
    static func contour(
        center: SIMD2<Double>, semiMajor: Double, semiMinor: Double,
        angle: Double, samples: Int = 120
    ) -> [SIMD2<Double>] {
        (0..<samples).map { i in
            let t = Double(i) / Double(samples) * 2 * .pi
            let local = SIMD2(semiMajor * cos(t), semiMinor * sin(t))
            return center + SIMD2(
                local.x * cos(angle) - local.y * sin(angle),
                local.x * sin(angle) + local.y * cos(angle)
            )
        }
    }

    @Test func aCircleFitsAsACircle() throws {
        let fitted = try #require(EllipseFit.fit(
            polygon: Self.contour(center: SIMD2(100, 80), semiMajor: 40, semiMinor: 40, angle: 0)))
        #expect(abs(fitted.center.x - 100) < 0.5)
        #expect(abs(fitted.center.y - 80) < 0.5)
        #expect(abs(fitted.semiMajor - 40) < 0.5, "got \(fitted.semiMajor)")
        #expect(abs(fitted.semiMinor - 40) < 0.5, "got \(fitted.semiMinor)")
        #expect(abs(fitted.axisRatio - 1) < 0.02)
        #expect(fitted.tilt < 0.15, "a face-on coin must read as barely tilted")
    }

    @Test func aTiltedCoinRecoversItsAxesAndAngle() throws {
        let angle = 0.6
        let fitted = try #require(EllipseFit.fit(
            polygon: Self.contour(
                center: SIMD2(200, 150), semiMajor: 50, semiMinor: 30, angle: angle)))
        #expect(abs(fitted.semiMajor - 50) < 0.8, "got \(fitted.semiMajor)")
        #expect(abs(fitted.semiMinor - 30) < 0.8, "got \(fitted.semiMinor)")
        // The axis is a line, so the angle is only defined modulo pi.
        let error = abs(atan2(sin(fitted.angle - angle), cos(fitted.angle - angle)))
        #expect(min(error, .pi - error) < 0.03, "got angle \(fitted.angle)")
    }

    @Test func theAxisRatioReadsTheTilt() throws {
        // 60 degrees of tilt foreshortens by cos(60) = 0.5.
        let fitted = try #require(EllipseFit.fit(
            polygon: Self.contour(
                center: .zero, semiMajor: 40, semiMinor: 20, angle: 0.3)))
        #expect(abs(fitted.tilt - .pi / 3) < 0.05, "got \(fitted.tilt) rad")
    }

    @Test func aRoundContourScoresFarBetterThanASquareOne() throws {
        let round = Self.contour(center: .zero, semiMajor: 40, semiMinor: 25, angle: 0.4)
        let fitted = try #require(EllipseFit.fit(polygon: round))
        let roundResidual = EllipseFit.residual(of: round, to: fitted)

        // A square, sampled the same way.
        var square: [SIMD2<Double>] = []
        for i in 0..<120 {
            let t = Double(i) / 120 * 4
            switch Int(t) {
            case 0: square.append(SIMD2(-40 + 80 * (t - 0), -40))
            case 1: square.append(SIMD2(40, -40 + 80 * (t - 1)))
            case 2: square.append(SIMD2(40 - 80 * (t - 2), 40))
            default: square.append(SIMD2(-40, 40 - 80 * (t - 3)))
            }
        }
        let squareFit = try #require(EllipseFit.fit(polygon: square))
        let squareResidual = EllipseFit.residual(of: square, to: squareFit)

        #expect(roundResidual < 0.02, "a clean ellipse scored \(roundResidual)")
        #expect(squareResidual > 4 * roundResidual,
                "a square scored \(squareResidual) against an ellipse's \(roundResidual)")
    }

    @Test func tooFewPointsIsRefused() {
        #expect(EllipseFit.fit(polygon: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1)]) == nil)
    }

    @Test func aDegenerateContourIsRefused() {
        // All points on a line: no enclosed area.
        let line = (0..<10).map { SIMD2(Double($0), 0.0) }
        #expect(EllipseFit.fit(polygon: line) == nil)
    }
}

/// Correcting the photo from the coin.
struct CoinRectifierTests {

    private func ellipse(major: Double, minor: Double, angle: Double) -> FittedEllipse {
        FittedEllipse(center: SIMD2(100, 100), semiMajor: major, semiMinor: minor, angle: angle)
    }

    /// The whole point: after correction the coin is round again.
    @Test func correctionMakesTheCoinRoundAgain() throws {
        let angle = 0.7
        let source = ellipse(major: 50, minor: 25, angle: angle)
        let rectifier = try #require(CoinRectifier(ellipse: source))

        let corrected = EllipseFit.fit(polygon: EllipseFitTests.contour(
            center: source.center, semiMajor: source.semiMajor,
            semiMinor: source.semiMinor, angle: angle
        ).map(rectifier.apply))

        let fitted = try #require(corrected)
        #expect(abs(fitted.axisRatio - 1) < 0.02,
                "the coin is still an ellipse after correction: ratio \(fitted.axisRatio)")
    }

    @Test func scaleComesFromTheKnownDiameter() throws {
        // A 50px semi-major axis is a 100px-wide quarter: 24.26mm / 100px.
        let rectifier = try #require(CoinRectifier(ellipse: ellipse(major: 50, minor: 30, angle: 0)))
        #expect(abs(rectifier.millimetersPerPixel - 24.26 / 100) < 1e-6,
                "got \(rectifier.millimetersPerPixel)")
    }

    /// A drawing must not spin just because it was corrected — the stretch is
    /// symmetric, so it carries no rotation of its own.
    @Test func correctionIntroducesNoRotation() throws {
        let rectifier = try #require(CoinRectifier(ellipse: ellipse(major: 50, minor: 30, angle: 0.9)))
        let t = rectifier.transform
        // A symmetric linear part means no rotational component.
        #expect(abs(t.b - t.c) < 1e-9, "the correction rotates: b=\(t.b) c=\(t.c)")
    }

    @Test func aFaceOnCoinCorrectsToAlmostNothing() throws {
        let rectifier = try #require(CoinRectifier(ellipse: ellipse(major: 40, minor: 40, angle: 0.3)))
        let moved = rectifier.apply(to: SIMD2(300, 220))
        #expect(simd_distance(moved, SIMD2(300, 220)) < 0.01,
                "a square-on shot was distorted anyway: \(moved)")
        #expect(rectifier.tilt < 0.05)
    }

    /// Past a steep angle the minor axis is a handful of pixels and the
    /// correction multiplies that error across the page, so it is refused
    /// rather than applied badly.
    @Test func anImpossiblySteepCoinIsRefused() {
        #expect(CoinRectifier(ellipse: ellipse(major: 50, minor: 2, angle: 0)) == nil)
    }

    @Test func degenerateEllipsesAreRefused() {
        #expect(CoinRectifier(ellipse: ellipse(major: 0, minor: 0, angle: 0)) == nil)
        #expect(CoinRectifier(ellipse: ellipse(major: 50, minor: 30, angle: 0),
                              diameterMM: 0) == nil)
    }

    @Test func correctedBoundsGrowToHoldTheStretchedPhoto() throws {
        let rectifier = try #require(CoinRectifier(ellipse: ellipse(major: 50, minor: 25, angle: 0)))
        let bounds = rectifier.correctedBounds(of: CGSize(width: 400, height: 300))
        // Stretching by 2 along y must not silently crop the drawing away.
        #expect(bounds.height > 300 * 1.5, "got \(bounds.height)")
        #expect(bounds.width >= 400 - 1)
    }
}

/// End to end on a rendered photo: correct it, then look again and confirm
/// the coin really did come out round. This is the check that would catch a
/// transform composed in the wrong order or a y-axis flip — the errors that
/// unit-testing the matrix alone cannot see.
struct CoinRectificationEndToEndTests {

    @Test func rectifyingAPhotoMakesItsCoinRound() throws {
        let image = CoinDetectorTests.page(coin: (CGPoint(x: 300, y: 300), 60, 33, 0.35))
        let found = try #require(CoinDetector.detect(in: image), "no coin in the test page")
        try #require(found.ellipse.axisRatio < 0.75, "fixture coin is not tilted enough")

        let rectifier = try #require(CoinRectifier(ellipse: found.ellipse))
        let corrected = try #require(rectifier.rectified(image), "rectification produced nothing")

        let again = try #require(
            CoinDetector.detect(in: corrected), "the coin vanished from the corrected photo")
        #expect(again.ellipse.axisRatio > 0.9,
                "the coin is still an ellipse after correcting the photo: \(again.ellipse.axisRatio)")
    }

    @Test func rectifyingKeepsTheWholePhoto() throws {
        let image = CoinDetectorTests.page(coin: (CGPoint(x: 300, y: 300), 60, 33, 0.35))
        let found = try #require(CoinDetector.detect(in: image))
        let rectifier = try #require(CoinRectifier(ellipse: found.ellipse))
        let corrected = try #require(rectifier.rectified(image))
        // The stretch grows the frame; nothing should be cropped to fit.
        #expect(corrected.height >= image.height, "the corrected photo lost height")
    }

    @Test func aSteepCorrectionStaysWithinItsSizeCap() throws {
        let ellipse = FittedEllipse(
            center: SIMD2(300, 300), semiMajor: 60, semiMinor: 22, angle: 0)
        let rectifier = try #require(CoinRectifier(ellipse: ellipse))
        let image = CoinDetectorTests.page(coin: nil)
        let corrected = try #require(rectifier.rectified(image, maxDimension: 800))
        #expect(max(corrected.width, corrected.height) <= 800)
    }
}
