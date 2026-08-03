import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

/// Regression for stroke continuity on a low-contrast photo-of-a-screen
/// (real user capture): the local threshold perforates faint strokes into
/// dashes unless binarization re-bridges them.
struct ButterflyContinuityTests {
    @Test func screenPhotoTracesWithContinuousOutlineRuns() throws {
        let image = try FixtureTraceTests.fixtureImage("butterfly-screen-photo", extension: "jpg")
        let result = try #require(TraceEngine.trace(image: image, detail: 0.7))
        let polylines = result.elements.flatMap(\.polylines)
        let diagonal = hypot(result.imageSize.width, result.imageSize.height)

        // The drawing must substantially survive...
        #expect(result.elements.count >= 20, "got \(result.elements.count) elements")
        let totalLength = polylines.reduce(0.0) { $0 + $1.length }
        #expect(totalLength >= 8000, "got total length \(Int(totalLength))")
        // ...and the wing outline must form long continuous runs, not dashes.
        let longestRun = polylines.map(\.length).max() ?? 0
        #expect(longestRun >= 0.15 * diagonal, "longest run \(Int(longestRun)) vs diagonal \(Int(diagonal))")
    }
}
