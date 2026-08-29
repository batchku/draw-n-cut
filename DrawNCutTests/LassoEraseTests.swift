import Foundation
import Testing
import simd
@testable import DrawNCut

/// Circling part of a shape must delete the control points inside and leave a
/// simpler curve. Reported from the device: "that doesn't do anything" —
/// lassoing part of a large shape removed nothing, because the old rule only
/// dropped a whole line when most of it was enclosed.
struct LassoEraseTests {

    /// A 24-point circle centred at (100,100), radius 50.
    private func loop() -> Polyline {
        Polyline(
            points: (0..<24).map { i in
                let a = Double(i) / 24 * 2 * .pi
                return SIMD2(100 + 50 * cos(a), 100 + 50 * sin(a))
            },
            isClosed: true
        )
    }

    /// A box enclosing the loop's right-hand side.
    private func rightSideRegion() -> [SIMD2<Double>] {
        [SIMD2(130, 40), SIMD2(200, 40), SIMD2(200, 160), SIMD2(130, 160)]
    }

    @Test func pointsInsideTheLassoAreDeleted() throws {
        let path = loop()
        guard case let .reshaped(result) = LassoErase.apply(
            region: rightSideRegion(), to: path) else {
            Issue.record("the lasso did nothing to a shape it partly enclosed")
            return
        }
        #expect(result.points.count < path.points.count, "no points were removed")
        for point in result.points {
            #expect(!PathGeometry.polygon(rightSideRegion(), contains: point),
                    "point \(point) survived inside the lasso")
        }
    }

    @Test func theCurveStaysClosed() throws {
        guard case let .reshaped(result) = LassoErase.apply(
            region: rightSideRegion(), to: loop()) else {
            Issue.record("expected a reshaped loop")
            return
        }
        #expect(result.isClosed, "a cut loop must stay closed after lassoing part of it")
    }

    @Test func aLassoAroundTheWholeShapeRemovesIt() {
        let everything = [
            SIMD2(-500.0, -500.0), SIMD2(500.0, -500.0),
            SIMD2(500.0, 500.0), SIMD2(-500.0, 500.0),
        ]
        #expect(LassoErase.apply(region: everything, to: loop()) == .removed)
    }

    @Test func aLassoAroundNothingLeavesThePathAlone() {
        let elsewhere = [
            SIMD2(900.0, 900.0), SIMD2(950.0, 900.0),
            SIMD2(950.0, 950.0), SIMD2(900.0, 950.0),
        ]
        #expect(LassoErase.apply(region: elsewhere, to: loop()) == .unchanged)
    }

    /// Taking a loop below three points leaves something that cannot be a
    /// closed curve, so it goes rather than becoming a degenerate sliver.
    @Test func aLoopReducedTooFarIsRemovedRatherThanLeftDegenerate() {
        let triangle = Polyline(
            points: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(5, 10)], isClosed: true)
        let overOnePoint = [
            SIMD2(-1.0, -1.0), SIMD2(3.0, -1.0), SIMD2(3.0, 3.0), SIMD2(-1.0, 3.0),
        ]
        #expect(LassoErase.apply(region: overOnePoint, to: triangle) == .removed)
    }

    @Test func aStrayTapIsNotALasso() {
        #expect(LassoErase.apply(region: [SIMD2(100, 100)], to: loop()) == .unchanged)
    }
}
