import Foundation
import simd

/// A traced curve in pixel space. `isClosed` means the last point connects
/// back to the first (a drawn loop).
struct Polyline: Equatable {
    var points: [SIMD2<Double>]
    var isClosed: Bool

    var length: Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += simd_length(points[i] - points[i - 1])
        }
        if isClosed, let first = points.first, let last = points.last {
            total += simd_length(first - last)
        }
        return total
    }
}

/// Reduces a stroke to its one-pixel-wide centerline, then walks the skeleton
/// graph into polylines. Centerlines are what the laser should engrave: one
/// pass along the pen line instead of an outline around it.
enum Skeletonizer {
    /// Zhang-Suen thinning. Iterates two sub-passes until stable.
    static func skeleton(of bitmap: BinaryBitmap) -> BinaryBitmap {
        var current = bitmap
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var toClear: [Int] = []
                for y in 0..<current.height {
                    for x in 0..<current.width where current[x, y] {
                        // Neighbors p2..p9 clockwise from north.
                        let p2 = current[x, y - 1], p3 = current[x + 1, y - 1]
                        let p4 = current[x + 1, y], p5 = current[x + 1, y + 1]
                        let p6 = current[x, y + 1], p7 = current[x - 1, y + 1]
                        let p8 = current[x - 1, y], p9 = current[x - 1, y - 1]
                        let neighbors = [p2, p3, p4, p5, p6, p7, p8, p9]
                        let inkCount = neighbors.count { $0 }
                        guard (2...6).contains(inkCount) else { continue }
                        // Transitions false→true around the ring.
                        var transitions = 0
                        for i in 0..<8 where !neighbors[i] && neighbors[(i + 1) % 8] {
                            transitions += 1
                        }
                        guard transitions == 1 else { continue }
                        let conditionA = pass == 0 ? !(p2 && p4 && p6) : !(p2 && p4 && p8)
                        let conditionB = pass == 0 ? !(p4 && p6 && p8) : !(p2 && p6 && p8)
                        if conditionA && conditionB {
                            toClear.append(y * current.width + x)
                        }
                    }
                }
                if !toClear.isEmpty {
                    changed = true
                    for index in toClear { current.pixels[index] = false }
                }
            }
        }
        return minimized(current)
    }

    /// Zhang-Suen leaves staircase redundancy (pixels with degree ≥ 3 along a
    /// plain curve), which shreds the later graph walk. A pixel is redundant
    /// when its inked ring neighbors form a single connected run — the curve
    /// stays connected without it. Delete those until stable.
    private static func minimized(_ skeleton: BinaryBitmap) -> BinaryBitmap {
        var current = skeleton
        let ring: [(Int, Int)] = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]
        // adjacency[i][j]: ring cells i and j are themselves grid-adjacent.
        let adjacent: [[Bool]] = ring.map { a in
            ring.map { b in
                a != b && abs(a.0 - b.0) <= 1 && abs(a.1 - b.1) <= 1
            }
        }

        func neighborComponents(_ x: Int, _ y: Int) -> (count: Int, components: Int) {
            var inked: [Int] = []
            for (i, (dx, dy)) in ring.enumerated() where current[x + dx, y + dy] {
                inked.append(i)
            }
            guard !inked.isEmpty else { return (0, 0) }
            var seen = Set<Int>()
            var components = 0
            for start in inked where !seen.contains(start) {
                components += 1
                var stack = [start]
                seen.insert(start)
                while let cell = stack.popLast() {
                    for other in inked where !seen.contains(other) && adjacent[cell][other] {
                        seen.insert(other)
                        stack.append(other)
                    }
                }
            }
            return (inked.count, components)
        }

        var changed = true
        while changed {
            changed = false
            for y in 0..<current.height {
                for x in 0..<current.width where current[x, y] {
                    let (count, components) = neighborComponents(x, y)
                    if count >= 2 && components == 1 {
                        current[x, y] = false
                        changed = true
                    }
                }
            }
        }
        return current
    }

    /// Walks the skeleton as a graph: nodes are endpoints and junctions
    /// (degree ≠ 2), edges become open polylines; leftover degree-2 cycles
    /// become closed polylines.
    static func polylines(from skeleton: BinaryBitmap) -> [Polyline] {
        let w = skeleton.width, h = skeleton.height
        let neighborOffsets: [(Int, Int)] = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

        func neighbors(_ x: Int, _ y: Int) -> [(Int, Int)] {
            neighborOffsets.compactMap { (dx, dy) in
                skeleton[x + dx, y + dy] ? (x + dx, y + dy) : nil
            }
        }

        var degree = [Int8](repeating: -1, count: w * h)
        var nodeIndices: [Int] = []
        for y in 0..<h {
            for x in 0..<w where skeleton[x, y] {
                let d = Int8(neighbors(x, y).count)
                degree[y * w + x] = d
                if d != 2 { nodeIndices.append(y * w + x) }
            }
        }

        var visited = Set<Int>()          // degree-2 interior pixels consumed
        var usedNodeEdges = Set<Int>()    // node-pixel × direction, to not walk an edge twice
        var result: [Polyline] = []

        func point(_ index: Int) -> SIMD2<Double> {
            SIMD2(Double(index % w), Double(index / w))
        }

        // Edges out of nodes.
        for nodeIndex in nodeIndices {
            let nx = nodeIndex % w, ny = nodeIndex / w
            for (direction, (dx, dy)) in neighborOffsets.enumerated() {
                let sx = nx + dx, sy = ny + dy
                guard skeleton[sx, sy] else { continue }
                guard !usedNodeEdges.contains(nodeIndex * 8 + direction) else { continue }
                var path = [point(nodeIndex)]
                var previous = (nx, ny)
                var current = (sx, sy)
                while degree[current.1 * w + current.0] == 2 && !visited.contains(current.1 * w + current.0) {
                    visited.insert(current.1 * w + current.0)
                    path.append(point(current.1 * w + current.0))
                    let next = neighbors(current.0, current.1).first { $0 != previous }
                    guard let next else { break }
                    previous = current
                    current = next
                }
                let currentIndex = current.1 * w + current.0
                if degree[currentIndex] != 2 {
                    // Arrived at another node (or back at a node): close out the edge.
                    path.append(point(currentIndex))
                    usedNodeEdges.insert(nodeIndex * 8 + direction)
                    // Mark the reverse direction from the far node.
                    let backDx = previous.0 - current.0, backDy = previous.1 - current.1
                    if let back = neighborOffsets.firstIndex(where: { $0 == (backDx, backDy) }) {
                        usedNodeEdges.insert(currentIndex * 8 + back)
                    }
                } else if !path.isEmpty {
                    path.append(point(currentIndex))
                }
                if path.count >= 2 {
                    result.append(Polyline(points: path, isClosed: false))
                }
            }
        }

        // Pure cycles: degree-2 pixels never reached from a node.
        for y in 0..<h {
            for x in 0..<w {
                let index = y * w + x
                guard degree[index] == 2, !visited.contains(index) else { continue }
                var path = [point(index)]
                visited.insert(index)
                var previous = (x, y)
                var current = neighbors(x, y)[0]
                while current != (x, y) {
                    let ci = current.1 * w + current.0
                    if visited.contains(ci) { break }
                    visited.insert(ci)
                    path.append(point(ci))
                    let next = neighbors(current.0, current.1).first { $0 != previous }
                    guard let next else { break }
                    previous = current
                    current = next
                }
                if path.count >= 3 {
                    result.append(Polyline(points: path, isClosed: true))
                }
            }
        }

        return result
    }

    /// Repairs skeleton artifacts: joins open polylines whose ends meet (a
    /// drawn loop gets split into arcs wherever a spur created a junction),
    /// then closes any polyline that returns to its start.
    ///
    /// Ends are only joined where exactly two polyline-ends meet — three or
    /// more meeting means a genuine junction, which must stay separate curves.
    static func mergedChains(_ polylines: [Polyline], tolerance: Double) -> [Polyline] {
        var closed = polylines.filter(\.isClosed)
        var open = polylines.filter { !$0.isClosed }

        func endpoints(of list: [Polyline]) -> [(index: Int, isStart: Bool, point: SIMD2<Double>)] {
            list.enumerated().flatMap { index, polyline in
                [(index, true, polyline.points.first!), (index, false, polyline.points.last!)]
            }
        }

        var merged = true
        while merged {
            merged = false
            let ends = endpoints(of: open)
            outer: for i in ends.indices {
                for j in (i + 1)..<ends.count {
                    let a = ends[i], b = ends[j]
                    guard a.index != b.index else { continue }
                    guard simd_length(a.point - b.point) <= tolerance else { continue }
                    // Only a clean two-way meeting point may merge.
                    let meetingCount = ends.count { simd_length($0.point - a.point) <= tolerance }
                    guard meetingCount == 2 else { continue }

                    var first = open[a.index].points
                    var second = open[b.index].points
                    if a.isStart { first.reverse() }        // ... -> a.point
                    if !b.isStart { second.reverse() }      // b.point -> ...
                    open[a.index] = Polyline(points: first + second.dropFirst(), isClosed: false)
                    open.remove(at: b.index)
                    merged = true
                    break outer
                }
            }
        }

        // Close anything that came back to its start.
        for i in open.indices.reversed() {
            var polyline = open[i]
            guard polyline.points.count >= 4,
                  let first = polyline.points.first, let last = polyline.points.last,
                  simd_length(first - last) <= tolerance else { continue }
            polyline.points.removeLast()
            polyline.isClosed = true
            closed.append(polyline)
            open.remove(at: i)
        }

        return closed + open
    }
}
