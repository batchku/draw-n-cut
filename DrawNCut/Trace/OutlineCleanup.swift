import CoreGraphics
import Foundation
import simd

/// Removes the curls and knots a traced cut outline picks up, so the cut is a
/// single simple loop.
///
/// This is a cutting requirement, not a cosmetic one. Every place the outline
/// crosses itself encloses an extra region, and the laser cuts every closed
/// region it is given — so a curl that a drawing tool would render as a
/// harmless flourish becomes a small piece of material that falls out of the
/// finished part.
///
/// Smoothing and simplification cannot fix these. Douglas-Peucker keeps a
/// point when it is far from the chord between its neighbours, and the two
/// ends of a tight curl are far apart along the path even though they are
/// close in space, so the curl is exactly the kind of feature simplification
/// is designed to preserve. Turning Detail down and Smoothing up rounds the
/// knot off without removing it. It has to be excised as a topological
/// feature instead.
enum OutlineCleanup {
    /// A self-crossing that cuts off no more than this share of the outline's
    /// length is a curl to be removed. Above it, the crossing separates two
    /// comparable halves — a genuine figure-eight — and cutting either away
    /// would destroy the shape rather than clean it.
    static let maximumCurlFraction = 0.25

    /// How many excisions to attempt before giving up. Each pass removes one
    /// curl, and a pathological outline must not spin here forever.
    static let maximumPasses = 40

    /// Returns the outline with its curls excised.
    static func withoutCurls(
        _ polyline: Polyline, maximumCurlFraction: Double = maximumCurlFraction
    ) -> Polyline {
        var result = polyline
        for _ in 0..<maximumPasses {
            guard let next = excisingFirstCurl(result, fraction: maximumCurlFraction) else {
                return result
            }
            result = next
        }
        return result
    }

    /// One pass: find the first self-crossing that cuts off a small enough
    /// span and remove that span, joining the path through the crossing
    /// point. Returns nil when the outline is already simple.
    static func excisingFirstCurl(_ polyline: Polyline, fraction: Double) -> Polyline? {
        let points = polyline.points
        let n = points.count
        guard n >= 4 else { return nil }

        // Cumulative length, so a span's length is a subtraction.
        var cumulative = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            let next = points[(i + 1) % n]
            cumulative[i + 1] = cumulative[i] + simd_distance(points[i], next)
        }
        let total = polyline.isClosed ? cumulative[n] : cumulative[n - 1]
        guard total > 0 else { return nil }

        let lastSegment = polyline.isClosed ? n - 1 : n - 2
        guard lastSegment >= 1 else { return nil }

        for i in 0...lastSegment {
            let a0 = points[i], a1 = points[(i + 1) % n]
            // Skip the neighbouring segment: consecutive segments share a
            // point and always "intersect" there.
            for j in (i + 2)...max(i + 2, lastSegment) where j <= lastSegment {
                // For a closed path the first and last segments are also
                // neighbours.
                if polyline.isClosed, i == 0, j == lastSegment { continue }
                let b0 = points[j], b1 = points[(j + 1) % n]
                guard let crossing = intersection(a0, a1, b0, b1) else { continue }

                // The span between the two segments, and what it costs to
                // remove it.
                let inner = cumulative[j + 1] - cumulative[i + 1]
                if inner <= fraction * total {
                    var kept = Array(points[0...i])
                    kept.append(crossing)
                    if j + 1 < n { kept.append(contentsOf: points[(j + 1)...]) }
                    return cleaned(kept, isClosed: polyline.isClosed)
                }
                // Otherwise the *other* side is the small one.
                let outer = total - inner
                if outer <= fraction * total {
                    var kept = [crossing]
                    kept.append(contentsOf: points[(i + 1)...j])
                    return cleaned(kept, isClosed: polyline.isClosed)
                }
            }
        }
        return nil
    }

    /// Drops points that coincide after an excision, which would otherwise
    /// leave zero-length segments for later stages to trip over.
    private static func cleaned(_ points: [SIMD2<Double>], isClosed: Bool) -> Polyline? {
        var kept: [SIMD2<Double>] = []
        for point in points where kept.last.map({ simd_distance($0, point) > 1e-6 }) ?? true {
            kept.append(point)
        }
        if isClosed, kept.count > 1, let first = kept.first, let last = kept.last,
           simd_distance(first, last) <= 1e-6 {
            kept.removeLast()
        }
        guard kept.count >= (isClosed ? 3 : 2) else { return nil }
        return Polyline(points: kept, isClosed: isClosed)
    }

    /// Where two segments properly cross, or nil. Shared endpoints and
    /// collinear overlaps do not count: neither encloses a region, and
    /// treating them as crossings would eat away at an ordinary corner.
    static func intersection(
        _ a0: SIMD2<Double>, _ a1: SIMD2<Double>,
        _ b0: SIMD2<Double>, _ b1: SIMD2<Double>
    ) -> SIMD2<Double>? {
        let r = a1 - a0
        let s = b1 - b0
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let d = b0 - a0
        let t = (d.x * s.y - d.y * s.x) / denominator
        let u = (d.x * r.y - d.y * r.x) / denominator
        // Strictly inside both segments, so touching at a shared vertex is
        // not a crossing.
        guard t > 1e-9, t < 1 - 1e-9, u > 1e-9, u < 1 - 1e-9 else { return nil }
        return a0 + t * r
    }

    /// True when no two non-adjacent segments cross — what a cut path has to
    /// be before it goes to the laser.
    static func isSimple(_ polyline: Polyline) -> Bool {
        excisingFirstCurl(polyline, fraction: 1.0) == nil
    }
}
