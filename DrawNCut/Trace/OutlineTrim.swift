import Foundation
import simd

/// Removes the stretches of a traced line that run along the cut outline,
/// keeping the rest of the same line.
///
/// The cut is derived from the subject mask and snapped onto the drawing's
/// own strokes, so the tracer inevitably produces engrave lines lying on top
/// of it. Drawing both would double every edge.
///
/// The previous rule hid a *whole* polyline once 80% of its points sat near
/// the outline. That works only while the mask is loose enough for the cut to
/// run through blank paper. With a tight silhouette — which is what a good
/// +/- selection produces — the cut runs along the outer marker strokes
/// themselves, and because a child's drawing is one connected run of ink, the
/// skeleton polylines that follow those strokes also carry the interior
/// branches. Hiding them whole threw the interior away: eyes, hatching and
/// mane texture vanished, leaving only the few marks that happened to form
/// separate components.
///
/// Trimming instead of hiding keeps the same guarantee — no stretch of line
/// is drawn on top of the cut — without discarding the parts that are
/// nowhere near it.
enum OutlineTrim {
    /// A surviving fragment needs at least this many points to be a line.
    static let minimumPoints = 2

    /// - Parameters:
    ///   - polyline: a traced line.
    ///   - edges: the cut outline as point runs.
    ///   - distance: how near counts as "on the outline".
    /// - Returns: the pieces of `polyline` that are clear of the outline.
    ///   Empty when the whole line lay on it.
    static func trimmed(
        _ polyline: Polyline, awayFrom edges: [[SIMD2<Double>]], distance: Double
    ) -> [Polyline] {
        guard !edges.isEmpty else { return [polyline] }
        let points = polyline.points
        guard !points.isEmpty else { return [] }

        let near = points.map { isNear($0, edges: edges, distance: distance) }
        if !near.contains(true) { return [polyline] }
        if !near.contains(false) { return [] }

        // A closed loop is cut open wherever it meets the outline, so the
        // runs are found on the sequence rotated to start at a near point —
        // otherwise a fragment spanning the seam would be split in two.
        var order = Array(points.indices)
        if polyline.isClosed, let firstNear = near.firstIndex(of: true) {
            order = Array(points.indices[firstNear...]) + Array(points.indices[..<firstNear])
        }

        var pieces: [Polyline] = []
        var run: [SIMD2<Double>] = []
        for index in order {
            if near[index] {
                if run.count >= minimumPoints {
                    pieces.append(Polyline(points: run, isClosed: false))
                }
                run = []
            } else {
                run.append(points[index])
            }
        }
        if run.count >= minimumPoints {
            pieces.append(Polyline(points: run, isClosed: false))
        }
        return pieces
    }

    private static func isNear(
        _ point: SIMD2<Double>, edges: [[SIMD2<Double>]], distance: Double
    ) -> Bool {
        for edge in edges {
            guard edge.count > 1 else { continue }
            for i in 0..<(edge.count - 1)
            where PathGeometry.distanceToSegment(point, edge[i], edge[i + 1]) <= distance {
                return true
            }
        }
        return false
    }

    /// The cut outline as point runs, with closed loops carrying their
    /// closing segment.
    static func edges(of outlines: [Polyline]) -> [[SIMD2<Double>]] {
        outlines.compactMap { outline in
            var edge = outline.points
            if outline.isClosed, let first = edge.first { edge.append(first) }
            return edge.count > 1 ? edge : nil
        }
    }
}
