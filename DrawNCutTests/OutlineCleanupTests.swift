import Foundation
import Testing
import simd
@testable import DrawNCut

/// A cut outline has to be one simple closed loop. Reported from the device
/// with screenshots: outlines came back with "squiggly intersecting lines
/// that are actually outside of the closed curve... extra lines that are
/// going to get cut and reduce down to a bunch of pieces of material falling
/// out." Turning Detail down and Smoothing up did not remove them.
struct OutlineCleanupTests {

    private func circle(radius: Double = 100, points n: Int = 48) -> [SIMD2<Double>] {
        (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return SIMD2(radius * cos(a), radius * sin(a))
        }
    }

    @Test func aCleanLoopIsLeftAlone() {
        let loop = Polyline(points: circle(), isClosed: true)
        #expect(OutlineCleanup.isSimple(loop))
        let cleaned = OutlineCleanup.withoutCurls(loop)
        #expect(cleaned.points.count == loop.points.count, "a clean loop was altered")
    }

    /// The reported defect: a small knot hanging off an otherwise good
    /// outline, crossing the path and enclosing a scrap of material.
    @Test func aCurlIsExcisedAndTheLoopStaysClosed() throws {
        var points = circle()
        // Splice a little crossing loop into one edge.
        let at = 12
        let base = points[at]
        points.insert(contentsOf: [
            base + SIMD2(18, -14), base + SIMD2(34, 6), base + SIMD2(8, 12),
            base + SIMD2(6, -10),
        ], at: at + 1)
        let knotted = Polyline(points: points, isClosed: true)
        try #require(!OutlineCleanup.isSimple(knotted), "the fixture has no crossing")

        let cleaned = OutlineCleanup.withoutCurls(knotted)

        #expect(OutlineCleanup.isSimple(cleaned), "the outline still crosses itself")
        #expect(cleaned.isClosed, "the cut loop was opened")
        #expect(cleaned.points.count < knotted.points.count, "nothing was removed")
    }

    @Test func severalCurlsAreAllRemoved() throws {
        var points = circle()
        for at in [30, 20, 10] {
            let base = points[at]
            points.insert(contentsOf: [
                base + SIMD2(16, -12), base + SIMD2(30, 5), base + SIMD2(7, 11),
                base + SIMD2(5, -9),
            ], at: at + 1)
        }
        let knotted = Polyline(points: points, isClosed: true)
        try #require(!OutlineCleanup.isSimple(knotted))
        #expect(OutlineCleanup.isSimple(OutlineCleanup.withoutCurls(knotted)),
                "some crossings survived")
    }

    /// The shape itself must not be eaten. A figure-eight crosses itself, but
    /// both halves are the drawing — removing either would destroy it, so it
    /// is left alone rather than "cleaned".
    @Test func aFigureEightIsNotDestroyed() {
        var points: [SIMD2<Double>] = []
        for i in 0..<60 {
            let t = Double(i) / 60 * 2 * .pi
            points.append(SIMD2(80 * sin(t), 60 * sin(t) * cos(t)))
        }
        let eight = Polyline(points: points, isClosed: true)
        let cleaned = OutlineCleanup.withoutCurls(eight)
        // Nearly all of it survives: neither lobe is a curl.
        #expect(cleaned.points.count > points.count * 3 / 4,
                "a genuine figure-eight was carved up: \(points.count) → \(cleaned.points.count)")
    }

    @Test func theOverallShapeIsPreserved() throws {
        var points = circle()
        let at = 12
        let base = points[at]
        points.insert(contentsOf: [
            base + SIMD2(18, -14), base + SIMD2(34, 6), base + SIMD2(8, 12),
        ], at: at + 1)
        let cleaned = OutlineCleanup.withoutCurls(Polyline(points: points, isClosed: true))

        // Still a circle of about the same size, centred where it was.
        let box = PathGeometry.boundingBox(of: cleaned.points)
        #expect(abs(box.width - 200) < 40, "width became \(box.width)")
        #expect(abs(box.height - 200) < 40, "height became \(box.height)")
    }

    @Test func aTouchingCornerIsNotMistakenForACrossing() {
        // A path that comes back to touch a previous vertex without crossing.
        let points = [
            SIMD2(0.0, 0.0), SIMD2(100, 0), SIMD2(100, 100),
            SIMD2(0, 100), SIMD2(0, 50), SIMD2(50, 50),
        ]
        let path = Polyline(points: points, isClosed: false)
        #expect(OutlineCleanup.excisingFirstCurl(path, fraction: 0.25) == nil,
                "a corner was treated as a self-crossing")
    }

    @Test func aDegenerateOutlineIsHandled() {
        #expect(OutlineCleanup.withoutCurls(
            Polyline(points: [SIMD2(0, 0), SIMD2(1, 1)], isClosed: false)).points.count == 2)
    }
}
