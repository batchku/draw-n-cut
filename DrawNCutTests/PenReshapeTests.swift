import Foundation
import Testing
import simd
@testable import DrawNCut

/// The pen tool: draw over a stretch of a line and it becomes the line you
/// drew. Unlike the smoothing brush, which can only nudge existing points,
/// the pen replaces them — that is what makes it able to simplify.
struct PenReshapeTests {

    /// A jagged horizontal line at y≈0: 21 points that zigzag ±4.
    private func jaggedLine() -> Polyline {
        Polyline(
            points: (0...20).map { i in
                SIMD2(Double(i) * 10, i.isMultiple(of: 2) ? 4.0 : -4.0)
            },
            isClosed: false
        )
    }

    /// A clean straight stroke along the middle of that line.
    private func straightPen(fromX: Double, toX: Double) -> [SIMD2<Double>] {
        stride(from: fromX, through: toX, by: 5).map { SIMD2($0, 0) }
    }

    @Test func penReplacesTheCoveredStretchWithItsOwnLine() throws {
        let path = jaggedLine()
        let pen = straightPen(fromX: 60, toX: 140)

        let result = try #require(
            PenReshape.reshaped(path, pen: pen, radius: 6, tolerance: 1))

        #expect(result.points.count < path.points.count,
                "the pen must simplify, not add points")
        // The stretch the pen covered is now flat; the rest still zigzags.
        let middle = result.points.filter { $0.x >= 60 && $0.x <= 140 }
        for point in middle {
            #expect(abs(point.y) < 1, "point \(point) survived inside the penned stretch")
        }
        #expect(result.points.contains { $0.x < 60 && abs($0.y) > 3 },
                "the untouched head must keep its shape")
        #expect(result.points.contains { $0.x > 140 && abs($0.y) > 3 },
                "the untouched tail must keep its shape")
    }

    @Test func endpointsOutsideTheStrokeAreLeftAlone() throws {
        let path = jaggedLine()
        let result = try #require(
            PenReshape.reshaped(path, pen: straightPen(fromX: 60, toX: 140),
                                radius: 6, tolerance: 1))
        #expect(result.points.first == path.points.first)
        #expect(result.points.last == path.points.last)
    }

    @Test func aStrokeDrawnBackwardsDoesNotFoldTheLine() throws {
        let path = jaggedLine()
        let forward = try #require(
            PenReshape.reshaped(path, pen: straightPen(fromX: 60, toX: 140),
                                radius: 6, tolerance: 1))
        let backward = try #require(
            PenReshape.reshaped(path, pen: straightPen(fromX: 60, toX: 140).reversed(),
                                radius: 6, tolerance: 1))
        // Drawing right-to-left over the same stretch must give the same line.
        #expect(backward.points.count == forward.points.count)
        for (a, b) in zip(backward.points, forward.points) {
            #expect(simd_distance(a, b) < 0.001, "\(a) vs \(b)")
        }
        // And x must stay monotonic — a folded splice would double back.
        let xs = backward.points.map(\.x)
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 + 0.001 },
                "the reshaped line doubles back on itself")
    }

    @Test func aStrokeThatTouchesNothingChangesNothing() {
        let path = jaggedLine()
        // Far above the line.
        let pen = stride(from: 0.0, through: 200, by: 5).map { SIMD2($0, 500) }
        #expect(PenReshape.reshaped(path, pen: pen, radius: 6, tolerance: 1) == nil)
    }

    @Test func aTapIsNotAStroke() {
        let path = jaggedLine()
        #expect(PenReshape.reshaped(path, pen: [SIMD2(100, 0)], radius: 6, tolerance: 1) == nil)
    }

    @Test func theStrokeClaimsTheLineItFollowsNotTheOneItCrosses() throws {
        let followed = jaggedLine()
        // A vertical line crossing the horizontal one near x=100.
        let crossed = Polyline(
            points: (0...20).map { SIMD2(100, Double($0) * 10 - 100) }, isClosed: false)

        let index = try #require(
            PenReshape.targetIndex(
                in: [crossed, followed], pen: straightPen(fromX: 60, toX: 140), radius: 6))
        #expect(index == 1, "the pen should claim the line it ran along")
    }

    @Test func aClosedLoopStaysClosed() throws {
        let loop = Polyline(
            points: (0..<24).map { i in
                let a = Double(i) / 24 * 2 * .pi
                return SIMD2(100 + 50 * cos(a), 100 + 50 * sin(a))
            },
            isClosed: true
        )
        // A chord across the right-hand arc.
        let pen = stride(from: -0.4, through: 0.4, by: 0.05).map { (a: Double) in
            SIMD2(100 + 50 * cos(a), 100 + 50 * sin(a))
        }
        let result = try #require(
            PenReshape.reshaped(loop, pen: pen, radius: 8, tolerance: 1))
        #expect(result.isClosed, "a cut loop must not be opened by the pen")
    }
}
