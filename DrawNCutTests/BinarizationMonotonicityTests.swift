import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

/// The guarantee the whole Threshold control now rests on.
///
/// Sauvola's threshold is `T = m(1 + k(s/R - 1))`. Because `s/R` is capped at
/// 1, the bracket can never exceed 1, so `T` falls as `k` rises and the ink
/// can only shrink. That is a property of the formula, not of tuning — which
/// is the point of adopting it. Three separate hand-rolled schemes were
/// reported broken for lacking exactly this.
struct BinarizationMonotonicityTests {

    private func inkCounts(_ image: CGImage) -> [(Double, Int)] {
        stride(from: 0.0, through: 1.0, by: 0.05).map { step in
            (step, BinaryBitmap(cgImage: image, threshold: step)?.pixels.count { $0 } ?? 0)
        }
    }

    @Test func inkFallsAtEveryStepOnEveryRealPhoto() throws {
        for name in ["fish-photo", "butterfly-screen-photo", "fish-circle-shadow-photo"] {
            let counts = inkCounts(try FixtureTraceTests.fixtureImage(name, extension: "jpg"))
            let line = counts.map { "\(String(format: "%.2f", $0.0)):\($0.1)" }
                .joined(separator: " ")
            for (a, b) in zip(counts, counts.dropFirst()) {
                #expect(b.1 <= a.1, "\(name): ink rose from \(a.0) to \(b.0) — \(line)")
            }
            #expect(counts.first!.1 > 10 * max(1, counts.last!.1), "\(name) barely moved — \(line)")
        }
    }

    /// s is clamped to R so the bracket cannot exceed 1 even on a
    /// pathological neighbourhood. Without that clamp a very high-variance
    /// window would invert the control locally.
    @Test func aHighVarianceEdgeCannotInvertTheControl() throws {
        // Half black, half white: the highest local deviation an 8-bit image
        // can produce.
        let image = TestCanvas.image(size: 200) { ctx in
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        let counts = inkCounts(image)
        for (a, b) in zip(counts, counts.dropFirst()) {
            #expect(b.1 <= a.1, "a hard edge inverted the control at \(b.0)")
        }
    }
}
