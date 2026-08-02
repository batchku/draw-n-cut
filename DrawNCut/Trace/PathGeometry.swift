import Foundation
import simd

/// Pure-geometry helpers shared by the trace pipeline and classifiers.
enum PathGeometry {
    /// Ramer–Douglas–Peucker simplification. Closed polylines are simplified
    /// with the seam pinned (first point kept).
    static func simplified(_ polyline: Polyline, tolerance: Double) -> Polyline {
        guard tolerance > 0, polyline.points.count > 2 else { return polyline }
        var points = polyline.points
        if polyline.isClosed { points.append(points[0]) }
        let kept = douglasPeucker(points, tolerance: tolerance)
        var result = kept
        if polyline.isClosed, result.count > 1 { result.removeLast() }
        return Polyline(points: result, isClosed: polyline.isClosed)
    }

    private static func douglasPeucker(_ points: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var maxDistance = 0.0
            var maxIndex = first
            for i in (first + 1)..<last {
                let d = distanceToSegment(points[i], points[first], points[last])
                if d > maxDistance {
                    maxDistance = d
                    maxIndex = i
                }
            }
            if maxDistance > tolerance {
                keep[maxIndex] = true
                stack.append((first, maxIndex))
                stack.append((maxIndex, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    static func distanceToSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        return simd_length(p - (a + t * ab))
    }

    /// One pass of Chaikin corner cutting. Open polylines keep their endpoints.
    static func smoothed(_ polyline: Polyline, passes: Int) -> Polyline {
        guard passes > 0, polyline.points.count > 2 else { return polyline }
        var points = polyline.points
        for _ in 0..<passes {
            var next: [SIMD2<Double>] = []
            if polyline.isClosed {
                for i in points.indices {
                    let a = points[i], b = points[(i + 1) % points.count]
                    next.append(0.75 * a + 0.25 * b)
                    next.append(0.25 * a + 0.75 * b)
                }
            } else {
                next.append(points[0])
                for i in 0..<(points.count - 1) {
                    let a = points[i], b = points[i + 1]
                    next.append(0.75 * a + 0.25 * b)
                    next.append(0.25 * a + 0.75 * b)
                }
                next.append(points[points.count - 1])
            }
            points = next
        }
        return Polyline(points: points, isClosed: polyline.isClosed)
    }

    /// Signed area via the shoelace formula (positive = counterclockwise in
    /// y-down pixel space it's clockwise; callers use the magnitude).
    static func area(of points: [SIMD2<Double>]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Ray-casting point-in-polygon.
    static func polygon(_ points: [SIMD2<Double>], contains p: SIMD2<Double>) -> Bool {
        guard points.count >= 3 else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func boundingBox(of points: [SIMD2<Double>]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
