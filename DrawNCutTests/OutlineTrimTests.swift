import Foundation
import Testing
import simd
@testable import DrawNCut

/// Trimming traced lines against the cut outline, instead of hiding them
/// whole. The whole-polyline rule is what made a well-segmented drawing lose
/// its interior detail.
struct OutlineTrimTests {

    /// A horizontal line along y=0, which will stand in for the cut.
    private func outlineEdges() -> [[SIMD2<Double>]] {
        OutlineTrim.edges(of: [
            Polyline(points: [SIMD2(-100, 0), SIMD2(100, 0)], isClosed: false)
        ])
    }

    @Test func aLineNowhereNearTheOutlineSurvivesWhole() {
        let away = Polyline(
            points: (0...10).map { SIMD2(Double($0) * 5, 60.0) }, isClosed: false)
        let pieces = OutlineTrim.trimmed(away, awayFrom: outlineEdges(), distance: 5)
        #expect(pieces.count == 1)
        #expect(pieces.first?.points.count == away.points.count)
    }

    @Test func aLineLyingOnTheOutlineIsRemoved() {
        let onTop = Polyline(
            points: (0...10).map { SIMD2(Double($0) * 5, 0.0) }, isClosed: false)
        #expect(OutlineTrim.trimmed(onTop, awayFrom: outlineEdges(), distance: 5).isEmpty)
    }

    /// The case that broke the app: a line that runs along the cut and then
    /// heads off into the drawing. The stretch on the cut goes, the interior
    /// branch stays.
    @Test func theInteriorPartOfALineSurvivesEvenWhenMostOfItIsOnTheOutline() throws {
        var points: [SIMD2<Double>] = []
        for i in 0...30 { points.append(SIMD2(Double(i) * 3, 0)) }   // along the cut
        for i in 1...8 { points.append(SIMD2(90, Double(i) * 10)) }  // into the interior
        let mixed = Polyline(points: points, isClosed: false)

        // 30 of 38 points sit on the outline — the old 80% rule hid this
        // entire line, interior branch and all.
        let pieces = OutlineTrim.trimmed(mixed, awayFrom: outlineEdges(), distance: 5)

        #expect(!pieces.isEmpty, "the interior branch was thrown away with the outline part")
        let kept = pieces.flatMap(\.points)
        #expect(kept.allSatisfy { abs($0.y) > 5 }, "a piece on the outline survived")
        #expect(kept.count >= 6, "only \(kept.count) interior points survived")
    }

    @Test func aLineCrossingTheOutlineIsSplitInTwo() {
        var points: [SIMD2<Double>] = []
        for i in 0...6 { points.append(SIMD2(0, -70 + Double(i) * 10)) }  // above
        points.append(SIMD2(0, 0))                                        // on it
        for i in 1...6 { points.append(SIMD2(0, Double(i) * 10)) }        // below
        let crossing = Polyline(points: points, isClosed: false)
        let pieces = OutlineTrim.trimmed(crossing, awayFrom: outlineEdges(), distance: 5)
        #expect(pieces.count == 2, "got \(pieces.count) pieces")
    }

    @Test func fragmentsTooShortToBeALineAreDropped() {
        // One stray point clear of the outline is not a line.
        let points = [SIMD2(0.0, 0.0), SIMD2(5, 0), SIMD2(10, 40), SIMD2(15, 0), SIMD2(20, 0)]
        let pieces = OutlineTrim.trimmed(
            Polyline(points: points, isClosed: false), awayFrom: outlineEdges(), distance: 5)
        #expect(pieces.isEmpty, "a single point became a line")
    }

    /// A loop meeting the outline at one place must come back as one open
    /// piece, not two split across the seam.
    @Test func aClosedLoopIsNotSplitAtItsOwnSeam() throws {
        let loop = Polyline(
            points: (0..<36).map { i in
                let a = Double(i) / 36 * 2 * .pi
                return SIMD2(50 * cos(a), 50 * sin(a) + 50)
            },
            isClosed: true
        )
        // The outline grazes the bottom of the loop near y=0.
        let pieces = OutlineTrim.trimmed(loop, awayFrom: outlineEdges(), distance: 8)
        #expect(pieces.count == 1, "the loop came back in \(pieces.count) pieces")
    }

    @Test func noOutlineMeansNoTrimming() {
        let line = Polyline(points: [SIMD2(0, 0), SIMD2(10, 0)], isClosed: false)
        #expect(OutlineTrim.trimmed(line, awayFrom: [], distance: 5).count == 1)
    }
}
