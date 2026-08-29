import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Renders simple synthetic "drawings" into a CGImage for pipeline tests.
enum TestCanvas {
    static func image(size: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setFillColor(gray: 0, alpha: 1)
        draw(context)
        return context.makeImage()!
    }
}

struct TraceEngineTests {
    @Test func straightStrokeBecomesOneOpenCenterline() throws {
        let image = TestCanvas.image(size: 200) { ctx in
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: 30, y: 100))
            ctx.addLine(to: CGPoint(x: 170, y: 100))
            ctx.strokePath()
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.8))
        try #require(result.elements.count == 1)
        let element = result.elements[0]
        try #require(element.polylines.count == 1)
        let line = element.polylines[0]
        #expect(!line.isClosed)
        // Centerline should run the stroke's length, not around its outline.
        #expect(line.length > 120 && line.length < 160)
        // A 5px pen should be estimated near 5px wide.
        #expect(element.estimatedStrokeWidth > 2.5 && element.estimatedStrokeWidth < 9)
    }

    @Test func drawnCircleBecomesClosedLoop() throws {
        let image = TestCanvas.image(size: 200) { ctx in
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: 40, y: 40, width: 120, height: 120))
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.8))
        try #require(result.elements.count == 1)
        let loops = result.elements[0].polylines.filter(\.isClosed)
        try #require(loops.count == 1)
        // Circumference of a 120px-diameter circle ≈ 377px.
        #expect(loops[0].length > 300 && loops[0].length < 450)
    }

    @Test func lowDetailDropsSpecksHighDetailKeepsThem() throws {
        let image = TestCanvas.image(size: 400) { ctx in
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: 50, y: 200))
            ctx.addLine(to: CGPoint(x: 350, y: 200))
            ctx.strokePath()
            // A small but real dot, and scattered specks.
            ctx.fillEllipse(in: CGRect(x: 200, y: 100, width: 10, height: 10))
            ctx.fill(CGRect(x: 80, y: 300, width: 2, height: 2))
            ctx.fill(CGRect(x: 300, y: 320, width: 2, height: 2))
        }
        let high = try #require(TraceEngine.trace(image: image, detail: 1.0))
        let low = try #require(TraceEngine.trace(image: image, detail: 0.0))
        #expect(low.elements.count < high.elements.count)
        // The long stroke always survives.
        #expect(low.elements.contains { $0.totalLength > 200 })
    }

    @Test func maskExcludesInkOutsideIt() throws {
        let image = TestCanvas.image(size: 200) { ctx in
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: 10, y: 50)); ctx.addLine(to: CGPoint(x: 190, y: 50))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 10, y: 150)); ctx.addLine(to: CGPoint(x: 190, y: 150))
            ctx.strokePath()
        }
        // Mask covering only the top half. Note: CGContext y is flipped vs
        // bitmap rows; build the mask against traced-bitmap coordinates.
        let unmasked = try #require(TraceEngine.trace(image: image, detail: 0.8))
        #expect(unmasked.elements.count == 2)
        var mask = BinaryBitmap(width: 200, height: 200)
        for y in 0..<100 {
            for x in 0..<200 { mask[x, y] = true }
        }
        let masked = try #require(TraceEngine.trace(image: image, mask: mask, detail: 0.8))
        #expect(masked.elements.count == 1)
    }

    @Test func detailSliderMapsMonotonically() {
        let coarse = TraceParameters.from(detail: 0, imageDiagonal: 1000)
        let mid = TraceParameters.from(detail: 0.5, imageDiagonal: 1000)
        let fine = TraceParameters.from(detail: 1, imageDiagonal: 1000)
        #expect(coarse.speckleMinArea > mid.speckleMinArea)
        #expect(mid.speckleMinArea > fine.speckleMinArea)
        #expect(coarse.minPolylineLength > fine.minPolylineLength)
        // Detail no longer touches how curves are drawn — that's Smoothness.
        #expect(coarse.simplifyTolerance == fine.simplifyTolerance)
    }

    @Test func smoothnessSliderMapsMonotonically() {
        let jagged = TraceParameters.from(detail: 0.7, smoothness: 0, imageDiagonal: 1000)
        let smooth = TraceParameters.from(detail: 0.7, smoothness: 1, imageDiagonal: 1000)
        #expect(jagged.simplifyTolerance < smooth.simplifyTolerance)
        #expect(jagged.smoothingPasses == 0, "full jaggedness must keep raw corners")
        #expect(smooth.smoothingPasses > jagged.smoothingPasses)
        // Smoothness must not change which marks survive.
        #expect(jagged.speckleMinArea == smooth.speckleMinArea)
        #expect(jagged.minPolylineLength == smooth.minPolylineLength)
    }

    /// The sliders' extremes must be unmistakable: max smoothness simplifies
    /// hard with triple rounding, and the Detail range spreads wide — while
    /// the long-standing defaults keep their exact look.
    @Test func sliderExtremesAreWideAndDefaultsAnchored() {
        let maxSmooth = TraceParameters.from(detail: 0.7, smoothness: 1, imageDiagonal: 1000)
        #expect(maxSmooth.simplifyTolerance >= 5.5, "got \(maxSmooth.simplifyTolerance)")
        #expect(maxSmooth.smoothingPasses == 3)

        let coarse = TraceParameters.from(detail: 0, imageDiagonal: 1000)
        let fine = TraceParameters.from(detail: 1, imageDiagonal: 1000)
        #expect(coarse.minPolylineLength >= 50, "full-left must cull aggressively")
        #expect(fine.minPolylineLength <= 3, "full-right must keep nearly everything")
        #expect(coarse.speckleMinArea >= 300)

        // The defaults are anchored: detail 0.7 / smoothness 0.4 look as
        // they always did.
        let anchored = TraceParameters.from(detail: 0.7, smoothness: 0.4, imageDiagonal: 1000)
        #expect(abs(anchored.minPolylineLength - 11) < 0.5)
        #expect(anchored.speckleMinArea == 25)
        #expect(abs(anchored.simplifyTolerance - 1.5) < 0.05)
        #expect(anchored.smoothingPasses == 1)
    }
}

/// The Threshold slider: it changes what binarization *sees*, which is the
/// only stage that can recover faint marks.
struct InkThresholdTests {

    @Test func thresholdDefaultReproducesTheFixedBehavior() {
        let gate = InkThreshold(slider: BinaryBitmap.defaultThreshold)
        #expect(gate.minContrast == 25, "the default must trace exactly as before")
        #expect(gate.darkCutPercent == 60)
    }

    @Test func thresholdMapsMonotonically() {
        var previousContrast = Int64.max
        var previousCut = Int64.min
        for step in 0...10 {
            let gate = InkThreshold(slider: Double(step) / 10)
            #expect(gate.minContrast <= previousContrast, "contrast must relax as the slider rises")
            #expect(gate.darkCutPercent >= previousCut, "the ink cut must widen as the slider rises")
            previousContrast = gate.minContrast
            previousCut = gate.darkCutPercent
        }
        #expect(InkThreshold(slider: 0).minContrast == 90)
        #expect(InkThreshold(slider: 1).minContrast == 2)
    }

    /// The point of the slider: a stroke too faint to register at the default
    /// comes back when Threshold is raised, and the raise is what does it —
    /// no Detail setting can recover a mark binarization never found.
    /// The ends have to be far enough apart to be worth reaching for: the
    /// first version of this slider was reported as "very subtle".
    @Test func theSliderEndsAreFarApart() {
        let low = InkThreshold(slider: 0)
        let high = InkThreshold(slider: 1)
        #expect(low.minContrast >= 8 * high.minContrast,
                "the strict end must demand far more contrast than the permissive one")
        #expect(high.darkCutPercent - low.darkCutPercent >= 60,
                "the ink cut barely moves across the slider's range")
    }

    @Test func raisingThresholdRecoversAFaintStroke() throws {
        let image = TestCanvas.image(size: 300) { ctx in
            // Bold mark: always found, so the comparison isn't "empty vs not".
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: 40, y: 60))
            ctx.addLine(to: CGPoint(x: 260, y: 60))
            ctx.strokePath()
            // Faint mark: a light pencil line, the engraving detail case.
            // 0.93 gray sits ~18 levels under the paper — below the default
            // 25-level contrast gate, above the 6-level floor the slider's
            // top end reaches. That gap is exactly what Threshold buys.
            ctx.setStrokeColor(gray: 0.93, alpha: 1)
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: 40, y: 220))
            ctx.addLine(to: CGPoint(x: 260, y: 220))
            ctx.strokePath()
        }

        func inkNear(y target: Double, threshold: Double) throws -> Int {
            let bitmap = try #require(BinaryBitmap(cgImage: image, threshold: threshold))
            let scale = Double(bitmap.height) / 300
            let row = Int(target * scale)
            var count = 0
            for y in max(0, row - 8)...min(bitmap.height - 1, row + 8) {
                for x in 0..<bitmap.width where bitmap[x, y] { count += 1 }
            }
            return count
        }

        // CGContext y is flipped relative to the bitmap; the faint stroke
        // drawn at y=220 lands near y=80 in image space.
        let faintDefault = try inkNear(y: 80, threshold: BinaryBitmap.defaultThreshold)
        let faintRaised = try inkNear(y: 80, threshold: 1.0)
        let boldRaised = try inkNear(y: 240, threshold: 1.0)

        #expect(boldRaised > 0, "the bold stroke must survive at any threshold")
        #expect(faintDefault == 0, "this stroke is meant to be invisible by default, got \(faintDefault)")
        #expect(faintRaised > 0,
                "raising Threshold must find the faint stroke (\(faintDefault) → \(faintRaised))")
    }
}
