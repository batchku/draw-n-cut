import Foundation
import simd

/// The eraser lasso: circle a region and the control points inside it are
/// deleted, closing the line up across the gap.
///
/// This is point surgery, not ink erasure. Circling a wobbly bulge on a cut
/// outline should leave a simpler closed curve, which is what deleting its
/// points and letting the neighbours join does. The previous behaviour
/// removed a whole traced line only when a majority of its points fell
/// inside, so lassoing part of a large shape did nothing at all.
enum LassoErase {
    enum Outcome: Equatable {
        /// Nothing of this path was inside the lasso.
        case unchanged
        /// Points were removed; this is what is left.
        case reshaped(Polyline)
        /// So little survived that the path is gone.
        case removed
    }

    /// A path needs this many points to still be a line (or a loop).
    static func minimumPoints(closed: Bool) -> Int { closed ? 3 : 2 }

    static func apply(region: [SIMD2<Double>], to path: Polyline) -> Outcome {
        guard region.count >= 3 else { return .unchanged }
        let kept = path.points.filter { !PathGeometry.polygon(region, contains: $0) }
        if kept.count == path.points.count { return .unchanged }
        guard kept.count >= minimumPoints(closed: path.isClosed) else { return .removed }
        return .reshaped(Polyline(points: kept, isClosed: path.isClosed))
    }
}
