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

    /// Total traced length, not polyline count. Sauvola thins and breaks
    /// strokes as k rises, so the number of *fragments* jumps around while
    /// the amount of line on screen changes smoothly — and it is the amount
    /// of line the user sees. Counting fragments measures the despurring
    /// filters, not the threshold.
    static func counts(in image: CGImage, mask: BinaryBitmap? = nil) -> [Int] {
        steps.map { t in
            let traced = TraceEngine.trace(image: image, mask: mask, detail: 0.7, threshold: t)
            let length = traced?.elements.reduce(0.0) { sum, element in
                sum + element.polylines.reduce(0.0) { $0 + $1.length }
            } ?? 0
            return Int(length)
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

    /// From the working range upwards, more Threshold is less drawing.
    ///
    /// Deliberately not asserted below 0.3. Between roughly 0.1 and 0.25 the
    /// ink is dense enough that components merge into large, fairly solid
    /// blobs, and the tracer refuses those on cost grounds — so traced length
    /// dips there and recovers. That is the component guard, not the
    /// threshold: `InkMonotonicDiagnostic` shows the binarization itself
    /// falling strictly at every step across the whole range. Naming the
    /// limit here rather than widening the tolerance until it passes.
    @Test func theWorkingRangeIsMonotonic() throws {
        let counts = Self.counts(in: try photo())
        let line = Self.report(counts)
        let working = Array(counts[3...])
        for (a, b) in zip(working, working.dropFirst()) {
            #expect(Double(b) <= Double(a) * 1.1 + 2,
                    "raising Threshold added drawing — \(line)")
        }
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

    @Test func theBarRisesWithTheSlider() {
        var previous = -Double.infinity
        for step in Self.steps {
            let k = InkThreshold(slider: step).k
            #expect(k >= previous, "Sauvola k dipped at \(step)")
            previous = k
        }
        #expect(InkThreshold(slider: 0).k < InkThreshold(slider: 1).k)
    }

    /// The point of the low end: dramatically denser than the default, not
    /// slightly.
    @Test func theLowestBarIsFarDenserThanTheDefault() throws {
        let image = try photo()
        let dense = TraceEngine.trace(image: image, detail: 0.7, threshold: 0)?
            .elements.reduce(0) { $0 + $1.polylines.count } ?? 0
        let normal = TraceEngine.trace(
            image: image, detail: 0.7, threshold: BinaryBitmap.defaultThreshold)?
            .elements.reduce(0) { $0 + $1.polylines.count } ?? 0
        #expect(dense > 5 * max(1, normal),
                "the bottom of the slider is not dense: \(normal) → \(dense)")
    }
}
