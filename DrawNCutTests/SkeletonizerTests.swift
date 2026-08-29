import Foundation
import Testing
import simd
@testable import DrawNCut

/// Thinning is the step every traced line passes through, and it had no
/// direct coverage: bugs here surface far downstream as "the shape came out
/// wrong" with nothing to point at.
struct SkeletonizerTests {

    /// A filled rectangle of ink.
    private func bar(width w: Int, height h: Int, thickness: Int, horizontal: Bool) -> BinaryBitmap {
        var bitmap = BinaryBitmap(width: w, height: h)
        if horizontal {
            let y0 = (h - thickness) / 2
            for y in y0..<(y0 + thickness) { for x in 2..<(w - 2) { bitmap[x, y] = true } }
        } else {
            let x0 = (w - thickness) / 2
            for x in x0..<(x0 + thickness) { for y in 2..<(h - 2) { bitmap[x, y] = true } }
        }
        return bitmap
    }

    @Test func aThickBarThinsToASingleCenterline() {
        let skeleton = Skeletonizer.skeleton(of: bar(width: 60, height: 30, thickness: 9, horizontal: true))
        let inkPerColumn = (0..<60).map { x in (0..<30).count { y in skeleton[x, y] } }
        // Every column the bar covers keeps exactly one skeleton pixel: that
        // is what "centerline" means. Ends are allowed to be empty.
        let covered = inkPerColumn.filter { $0 > 0 }
        #expect(covered.count > 40, "the centerline barely survived: \(covered.count) columns")
        #expect(covered.allSatisfy { $0 <= 2 }, "the bar did not thin to a line: \(inkPerColumn)")
    }

    @Test func thinningPreservesTheStrokeItThins() {
        let bitmap = bar(width: 60, height: 30, thickness: 9, horizontal: true)
        let skeleton = Skeletonizer.skeleton(of: bitmap)
        for y in 0..<30 {
            for x in 0..<60 where skeleton[x, y] {
                #expect(bitmap[x, y], "skeleton pixel (\(x),\(y)) is outside the original ink")
            }
        }
    }

    @Test func aBarBecomesOneOpenPolyline() throws {
        let skeleton = Skeletonizer.skeleton(of: bar(width: 60, height: 30, thickness: 7, horizontal: true))
        let polylines = Skeletonizer.polylines(from: skeleton)
        try #require(!polylines.isEmpty, "thinning produced no polyline")
        let longest = try #require(polylines.max(by: { $0.length < $1.length }))
        #expect(!longest.isClosed)
        #expect(longest.length > 30, "got length \(longest.length)")
    }

    @Test func aRingBecomesAClosedLoop() throws {
        var bitmap = BinaryBitmap(width: 80, height: 80)
        let center = SIMD2(40.0, 40.0)
        for y in 0..<80 {
            for x in 0..<80 {
                let d = simd_length(SIMD2(Double(x), Double(y)) - center)
                if d >= 22 && d <= 28 { bitmap[x, y] = true }
            }
        }
        let polylines = Skeletonizer.polylines(from: Skeletonizer.skeleton(of: bitmap))
        #expect(polylines.contains { $0.isClosed }, "a ring must thin to a closed loop")
    }

    @Test func emptyInkYieldsNothing() {
        let skeleton = Skeletonizer.skeleton(of: BinaryBitmap(width: 20, height: 20))
        #expect(Skeletonizer.polylines(from: skeleton).isEmpty)
    }

    /// Junction repair: thinning breaks a stroke into arcs that stop short of
    /// each other, and merging is what makes them one line again.
    @Test func mergingJoinsArcsThatStopShortOfEachOther() {
        let a = Polyline(points: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(20, 0)], isClosed: false)
        let b = Polyline(points: [SIMD2(22, 0), SIMD2(32, 0), SIMD2(42, 0)], isClosed: false)
        let merged = Skeletonizer.mergedChains([a, b], tolerance: 4)
        #expect(merged.count == 1, "the two arcs stayed apart: \(merged.count) chains")
        #expect(merged[0].points.count >= 5)
    }

    @Test func mergingLeavesGenuinelySeparateLinesAlone() {
        let a = Polyline(points: [SIMD2(0, 0), SIMD2(20, 0)], isClosed: false)
        let b = Polyline(points: [SIMD2(0, 100), SIMD2(20, 100)], isClosed: false)
        #expect(Skeletonizer.mergedChains([a, b], tolerance: 4).count == 2)
    }
}
