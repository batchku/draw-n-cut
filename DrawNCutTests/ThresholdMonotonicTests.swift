import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Threshold must behave like a threshold: a bar a mark has to clear before
/// it counts as ink. Low bar, more engraving lines; high bar, fewer.
///
/// Reported twice from the device. First it did nothing at all; then, after a
/// retune, "basically the same level of detail, but the lines change". Both
/// were the same cause — the slider drove a darkness bar and a stroke-fatness
/// knob in opposite directions, and they cancelled. Measured across the range
/// it went 44, 39, 38, 39, 38, 60, 70, 72, 168, 257, 321: flat through the
/// whole bottom half, then climbing, which is backwards.
struct ThresholdMonotonicTests {

    static let steps = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }

    static func counts(in image: CGImage, mask: BinaryBitmap? = nil) -> [Int] {
        steps.map { t in
            TraceEngine.trace(image: image, mask: mask, detail: 0.7, threshold: t)?
                .elements.reduce(0) { $0 + $1.polylines.count } ?? 0
        }
    }

    static func report(_ counts: [Int]) -> String {
        zip(steps, counts).map { "\(String(format: "%.1f", $0)):\($1)" }.joined(separator: " ")
    }

    /// Smoothed over three steps. A raw count wobbles by a few lines as
    /// strokes merge and split, which says nothing about whether the control
    /// works; the trend does.
    static func smoothed(_ counts: [Int]) -> [Double] {
        counts.indices.map { i in
            let window = counts[max(0, i - 1)...min(counts.count - 1, i + 1)]
            return Double(window.reduce(0, +)) / Double(window.count)
        }
    }

    /// A real photograph: paper, ink and lighting with finite contrast, which
    /// is the only kind of image a darkness bar can discriminate on. A
    /// synthetic black-on-white canvas clears any bar and would report the
    /// control as dead however well it worked.
    private func photo() throws -> CGImage {
        try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
    }

    private func disc(for image: CGImage) -> BinaryBitmap {
        let space = BinaryBitmap.traceSize(for: image)
        let w = Int(space.width), h = Int(space.height)
        var mask = BinaryBitmap(width: w, height: h)
        let cx = Double(w) / 2, cy = Double(h) / 2
        // Generous: a disc that slices through the drawing samples too few
        // lines for a trend to show above the noise of strokes merging.
        let radius = 0.60 * Double(min(w, h))
        for y in 0..<h {
            for x in 0..<w where hypot(Double(x) - cx, Double(y) - cy) <= radius {
                mask[x, y] = true
            }
        }
        return mask
    }

    @Test func aLowBarKeepsFarMoreLinesThanAHighOne() throws {
        let counts = Self.counts(in: try photo())
        let line = Self.report(counts)
        print("THRESH unmasked: \(line)")
        #expect(counts.first! > 3 * max(1, counts.last!),
                "the two ends are barely different — \(line)")
    }

    @Test func theTrendIsDownwardsWithNoDeadHalf() throws {
        let counts = Self.counts(in: try photo())
        let line = Self.report(counts)
        let curve = Self.smoothed(counts)

        for (a, b) in zip(curve, curve.dropFirst()) {
            #expect(b <= a * 1.25 + 2, "raising Threshold added lines — \(line)")
        }
        // The old failure was a flat bottom half. Each half has to move.
        let lower = Array(counts[0...5]), upper = Array(counts[5...])
        #expect(lower.max()! > lower.min()! * 3 / 2,
                "the lower half of the slider does nothing — \(line)")
        #expect(upper.max()! > upper.min()! * 3 / 2,
                "the upper half of the slider does nothing — \(line)")
    }

    /// The way the drawing is actually traced: confined to a subject mask.
    @Test func aMaskedDrawingBehavesTheSameWay() throws {
        let image = try photo()
        let counts = Self.counts(in: image, mask: disc(for: image))
        let line = Self.report(counts)
        print("THRESH masked: \(line)")
        #expect(counts.first! > 2 * max(1, counts.last!),
                "the two ends are barely different under a mask — \(line)")
    }

    /// The midpoint is the value that predates the slider, so an untouched
    /// drawing traces exactly as it always did.
    @Test func theMidpointIsTheHistoricalDefault() {
        #expect(InkThreshold(slider: BinaryBitmap.defaultThreshold).minContrast == 25)
        #expect(InkThreshold(slider: BinaryBitmap.defaultThreshold).darkCutPercent == 60)
    }

    @Test func theBarRisesWithTheSlider() {
        var previous = Int64.min
        for step in Self.steps {
            let bar = InkThreshold(slider: step).minContrast
            #expect(bar >= previous, "the bar dipped at \(step)")
            previous = bar
        }
        #expect(InkThreshold(slider: 0).minContrast < InkThreshold(slider: 1).minContrast)
    }

    /// Stroke fatness is no longer tied to the slider — that coupling is what
    /// made the two ends look equally detailed while showing different lines.
    @Test func strokeFatnessNoLongerMovesWithTheSlider() {
        let values = Set(Self.steps.map { InkThreshold(slider: $0).darkCutPercent })
        #expect(values.count == 1, "the ink cut still varies with Threshold: \(values)")
    }
}
