import Foundation
import simd

/// The pen tool: draw over a stretch of a line and that stretch becomes the
/// line you drew.
///
/// This is the deliberate counterpart to the smoothing brush. The brush nudges
/// existing points towards their neighbours, so it can only ever soften what
/// the trace already produced — a badly wandering stretch stays badly
/// wandering, just rounder. The pen replaces the stretch outright with the
/// hand-drawn stroke, which is what "simplify by drawing over it" means: the
/// wandering points do not move, they are gone, and the pen's own line stands
/// in for them.
enum PenReshape {
    /// A pen stroke has to cover at least this many of a path's points before
    /// it counts as tracing that path. One point is a touch, not a stroke.
    static let minimumCoveredPoints = 2

    /// The path a pen stroke was aimed at: the one it covers most. Drawing
    /// across a junction otherwise mangles every line that happens to pass
    /// under the stroke, when the user was plainly following one of them.
    static func targetIndex(
        in paths: [Polyline], pen: [SIMD2<Double>], radius: Double
    ) -> Int? {
        var best: (index: Int, covered: Int)?
        for (index, path) in paths.enumerated() {
            let covered = coveredIndices(of: path, pen: pen, radius: radius).count
            guard covered >= minimumCoveredPoints else { continue }
            if covered > (best?.covered ?? 0) { best = (index, covered) }
        }
        return best?.index
    }

    /// Replaces the covered stretch of `path` with the pen's own line.
    /// Returns nil when the stroke did not cover enough to act on.
    ///
    /// - Parameters:
    ///   - pen: the stroke in the same coordinate space as the path.
    ///   - radius: how near a point must be to count as covered.
    ///   - tolerance: Douglas-Peucker tolerance applied to the pen stroke. A
    ///     raw finger stroke carries hundreds of jittery samples; dropped in
    ///     unsimplified it would replace a messy stretch with a messier one.
    static func reshaped(
        _ path: Polyline, pen: [SIMD2<Double>], radius: Double, tolerance: Double
    ) -> Polyline? {
        let covered = coveredIndices(of: path, pen: pen, radius: radius)
        guard covered.count >= minimumCoveredPoints,
              let first = covered.first, let last = covered.last else { return nil }

        var replacement = PathGeometry.simplified(
            Polyline(points: pen, isClosed: false), tolerance: tolerance
        ).points
        guard replacement.count >= 2 else { return nil }

        let head = Array(path.points[..<first])
        let tail = Array(path.points[(last + 1)...])

        // The stroke may have been drawn against the path's direction, which
        // would splice in a line that doubles back on itself. Orient it by
        // whichever end sits nearer the piece of path it has to join.
        if shouldReverse(replacement, head: head, tail: tail) {
            replacement.reverse()
        }

        let points = head + replacement + tail
        guard points.count >= 2 else { return nil }
        return Polyline(points: points, isClosed: path.isClosed)
    }

    /// Indices of `path`'s points lying within `radius` of the pen stroke.
    private static func coveredIndices(
        of path: Polyline, pen: [SIMD2<Double>], radius: Double
    ) -> [Int] {
        guard pen.count >= 2 else { return [] }
        var indices: [Int] = []
        for (index, point) in path.points.enumerated() {
            for i in 0..<(pen.count - 1)
            where PathGeometry.distanceToSegment(point, pen[i], pen[i + 1]) <= radius {
                indices.append(index)
                break
            }
        }
        return indices
    }

    /// True when the replacement joins up better reversed. Measured against
    /// whichever neighbour exists: a stroke over the middle of a path has
    /// both, one over an end has only the other side.
    private static func shouldReverse(
        _ replacement: [SIMD2<Double>], head: [SIMD2<Double>], tail: [SIMD2<Double>]
    ) -> Bool {
        guard let start = replacement.first, let end = replacement.last else { return false }
        if let anchor = head.last {
            return simd_distance(anchor, start) > simd_distance(anchor, end)
        }
        if let anchor = tail.first {
            return simd_distance(anchor, end) > simd_distance(anchor, start)
        }
        return false
    }
}
