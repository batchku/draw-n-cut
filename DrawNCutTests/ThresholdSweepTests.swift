import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

/// The Threshold slider has to behave over its whole range, not just near the
/// middle. Reported from the device: past halfway, raising it *reduced*
/// detail, and at the top the screen said "Nothing to Trace".
struct ThresholdSweepTests {

    private static let steps = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }

    private func polylineCounts(in image: CGImage) -> [(threshold: Double, count: Int)] {
        Self.steps.map { t in
            let traced = TraceEngine.trace(image: image, detail: 0.7, threshold: t)
            return (t, traced?.elements.reduce(0) { $0 + $1.polylines.count } ?? 0)
        }
    }

    /// A real photograph, with all the paper texture and lighting gradient
    /// that makes the top of the range hard.
    @Test func aRealPhotoTracesAcrossTheWholeRange() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let counts = polylineCounts(in: image)
        let report = counts.map { "\(String(format: "%.1f", $0.threshold)):\($0.count)" }
            .joined(separator: " ")
        print("UNMASKED SWEEP: \(report)")

        // Silence at the very top is now the requirement, not a failure.
        for (threshold, count) in counts where threshold < 1 {
            #expect(count > 0, "threshold \(threshold) traced nothing — \(report)")
        }
        #expect(counts.last?.count == 0, "maximum Threshold must trace nothing — \(report)")
    }

    /// Every setting must still trace *something*. Fewer lines at the top
    /// of the range is now the intended behaviour — see
    /// ThresholdMonotonicTests — but no setting may empty the screen.
    @Test func noSettingEmptiesTheDrawing() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let counts = polylineCounts(in: image)
        let report = counts.map { "\(String(format: "%.1f", $0.threshold)):\($0.count)" }
            .joined(separator: " ")
        // Silence at the very top is now the requirement, not a failure.
        for (threshold, count) in counts where threshold < 1 {
            #expect(count > 0, "threshold \(threshold) traced nothing — \(report)")
        }
        #expect(counts.last?.count == 0, "maximum Threshold must trace nothing — \(report)")
    }

    @Test func aScreenPhotoAlsoSurvivesTheTopOfTheRange() throws {
        let image = try FixtureTraceTests.fixtureImage("butterfly-screen-photo", extension: "jpg")
        let counts = polylineCounts(in: image)
        let report = counts.map { "\(String(format: "%.1f", $0.threshold)):\($0.count)" }
            .joined(separator: " ")
        // Everything below the maximum must survive; the maximum must not.
        #expect(counts.dropLast().allSatisfy { $0.count > 0 },
                "a setting below maximum traced nothing — \(report)")
        #expect(try #require(counts.last).count == 0,
                "maximum Threshold must trace nothing — \(report)")
    }
}

/// The same sweep with a subject mask, which is how the drawings that failed
/// were actually traced. The masked path has its own guards, and at the top
/// of the range saturated ink merges into one component large enough to trip
/// them — which is what produced "Nothing to Trace" at full Threshold.
struct MaskedThresholdSweepTests {

    @Test func aMaskedDrawingTracesAcrossTheWholeRange() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let traceSpace = BinaryBitmap.traceSize(for: image)
        let w = Int(traceSpace.width), h = Int(traceSpace.height)
        // A generous mask over the drawing, as a +/- selection would leave.
        var mask = BinaryBitmap(width: w, height: h)
        let inset = Int(Double(min(w, h)) * 0.08)
        for y in inset..<(h - inset) {
            for x in inset..<(w - inset) { mask[x, y] = true }
        }

        var report: [String] = []
        var counts: [(Double, Int)] = []
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            let traced = TraceEngine.trace(
                image: image, mask: mask, detail: 0.7, threshold: step)
            let count = traced?.elements.reduce(0) { $0 + $1.polylines.count } ?? 0
            counts.append((step, count))
            report.append("\(String(format: "%.1f", step)):\(count)")
        }
        let line = report.joined(separator: " ")
        print("MASKED SWEEP: \(line)")
        for (threshold, count) in counts where threshold < 1 {
            #expect(count > 0, "masked threshold \(threshold) traced nothing — \(line)")
        }
        #expect(counts.last?.1 == 0, "maximum Threshold must trace nothing — \(line)")
    }
}
