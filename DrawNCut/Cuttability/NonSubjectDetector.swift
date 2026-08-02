import CoreGraphics
import Foundation
import simd
import Vision

/// Why a piece of the trace probably isn't part of the drawing's subject.
enum RemovalReason: String, Codable {
    /// A thin closed loop drawn *around* the subject (a border circle).
    case enclosingLoop
    /// Overlaps a detected text region (a handwritten label).
    case textLike
    /// Hugs the image border (scanner/photo edge artifact).
    case edgeArtifact
}

/// One suggested removal. Loop suggestions target a single polyline (the
/// circle may share an element with the subject when strokes touch); other
/// reasons target whole elements.
struct RemovalSuggestion: Identifiable {
    let id = UUID()
    var elementID: UUID
    /// Index into the element's polylines for `.enclosingLoop`; nil = whole element.
    var polylineIndex: Int?
    var reason: RemovalReason
}

/// Detection is opportunistic and per-image: these features appear in some
/// drawings and not others, so everything here only *suggests* — nothing is
/// auto-removed, and the removal UI never depends on detector output.
enum NonSubjectDetector {
    static func suggestions(
        for classification: Classification,
        imageSize: CGSize,
        textRegions: [CGRect] = []
    ) -> [RemovalSuggestion] {
        var suggestions: [RemovalSuggestion] = []
        suggestions += enclosingLoops(in: classification, imageSize: imageSize)
        suggestions += textOverlaps(in: classification, textRegions: textRegions)
        suggestions += edgeArtifacts(in: classification, imageSize: imageSize)
        return suggestions
    }

    // MARK: - Enclosing loops

    /// Detects border circles drawn *around* a drawing. Hand-drawn circles
    /// rarely trace as closed polylines — pen overshoots and touch-points
    /// split them into open arcs — so detection is geometric: fit a circle
    /// (least-squares) to each long arc, and when the fit is genuinely round,
    /// collect every arc lying in that ring band. If together they sweep most
    /// of the circle and real drawing sits inside, it's a border ring.
    /// A drawn body (a fish's oval) is rejected by the fit residual: it's not
    /// round enough.
    static func enclosingLoops(in classification: Classification, imageSize: CGSize) -> [RemovalSuggestion] {
        let diagonal = hypot(Double(imageSize.width), Double(imageSize.height))
        let sampleStep = max(3.0, diagonal * 0.004)
        var suggestions: [RemovalSuggestion] = []

        struct Arc {
            var elementID: UUID
            var polylineIndex: Int
            var points: [SIMD2<Double>]
            var length: Double
        }

        for cluster in classification.clusters {
            let members = classification.elements.filter { cluster.elementIDs.contains($0.element.id) }
            var arcs: [Arc] = []
            for member in members {
                for (index, polyline) in member.element.polylines.enumerated() {
                    arcs.append(Arc(
                        elementID: member.element.id,
                        polylineIndex: index,
                        points: resampled(polyline, step: sampleStep),
                        length: polyline.length
                    ))
                }
            }
            let clusterMaxDim = Double(max(cluster.boundingBox.width, cluster.boundingBox.height))
            guard clusterMaxDim > 0 else { continue }

            // Try the longest arcs as ring seeds.
            let seeds = arcs
                .filter { $0.length >= 0.03 * diagonal }
                .sorted { $0.length > $1.length }
                .prefix(8)

            for seed in seeds {
                guard let fit = circleFit(seed.points),
                      fit.rmsResidual <= 0.15 * fit.radius,
                      fit.radius >= 0.18 * clusterMaxDim,
                      fit.radius <= 0.75 * clusterMaxDim,
                      cluster.boundingBox.insetBy(dx: -0.1 * clusterMaxDim, dy: -0.1 * clusterMaxDim)
                          .contains(CGPoint(x: fit.center.x, y: fit.center.y))
                else { continue }

                // Ring members: arcs mostly inside the fitted ring band.
                let ringMembers = arcs.filter { arc in
                    let inBand = arc.points.count { p in
                        abs(simd_length(p - fit.center) - fit.radius) <= 0.18 * fit.radius
                    }
                    return Double(inBand) >= 0.7 * Double(arc.points.count)
                }

                // Together they must sweep most of the circle...
                var coverage = Set<Int>()
                for member in ringMembers {
                    coverage.formUnion(angleBins(of: member.points, around: fit.center))
                }
                guard coverage.count >= 27 else { continue }  // ≥ 270°

                // ...with actual drawing inside the ring.
                let memberKeys = Set(ringMembers.map { "\($0.elementID)-\($0.polylineIndex)" })
                let innerPoints = arcs
                    .filter { !memberKeys.contains("\($0.elementID)-\($0.polylineIndex)") }
                    .flatMap(\.points)
                    .count { simd_length($0 - fit.center) <= 0.6 * fit.radius }
                guard innerPoints >= 8 else { continue }

                for member in ringMembers {
                    suggestions.append(RemovalSuggestion(
                        elementID: member.elementID,
                        polylineIndex: member.polylineIndex,
                        reason: .enclosingLoop
                    ))
                }
                break   // one ring per cluster
            }
        }
        return suggestions
    }

    struct CircleFit {
        var center: SIMD2<Double>
        var radius: Double
        var rmsResidual: Double
    }

    /// Kasa algebraic circle fit: least-squares solution of
    /// x² + y² + Dx + Ey + F = 0. Degenerate (collinear) inputs return nil.
    static func circleFit(_ points: [SIMD2<Double>]) -> CircleFit? {
        guard points.count >= 6 else { return nil }
        // Center coordinates for numeric stability.
        let mean = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        let p = points.map { $0 - mean }

        var sxx = 0.0, sxy = 0.0, syy = 0.0, sx = 0.0, sy = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        for q in p {
            let z = q.x * q.x + q.y * q.y
            sxx += q.x * q.x; sxy += q.x * q.y; syy += q.y * q.y
            sx += q.x; sy += q.y
            sxz += q.x * z; syz += q.y * z; sz += z
        }
        let n = Double(p.count)

        // Normal equations for [D, E, F]:
        let a: [[Double]] = [
            [sxx, sxy, sx],
            [sxy, syy, sy],
            [sx, sy, n],
        ]
        let b: [Double] = [-sxz, -syz, -sz]
        let det = determinant3(a)
        guard abs(det) > 1e-9 * max(1, sxx * syy * n) else { return nil }

        func solve(_ column: Int) -> Double {
            var m = a
            for row in 0..<3 { m[row][column] = b[row] }
            return determinant3(m) / det
        }
        let d = solve(0), e = solve(1), f = solve(2)
        let center = SIMD2(-d / 2, -e / 2)
        let radiusSquared = (d * d + e * e) / 4 - f
        guard radiusSquared > 0 else { return nil }
        let radius = radiusSquared.squareRoot()

        var residualSum = 0.0
        for q in p {
            let deviation = simd_length(q - center) - radius
            residualSum += deviation * deviation
        }
        return CircleFit(
            center: center + mean,
            radius: radius,
            rmsResidual: (residualSum / n).squareRoot()
        )
    }

    private static func determinant3(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    /// 36 ten-degree angular bins touched by these points, seen from `center`.
    private static func angleBins(of points: [SIMD2<Double>], around center: SIMD2<Double>) -> Set<Int> {
        var bins = Set<Int>()
        for p in points {
            let angle = atan2(p.y - center.y, p.x - center.x)
            let bin = Int((angle + .pi) / (2 * .pi) * 36) % 36
            bins.insert(bin)
        }
        return bins
    }

    /// Densifies a polyline so sparse post-simplification vertices don't
    /// leave gaps in radial/angular statistics.
    private static func resampled(_ polyline: Polyline, step: Double) -> [SIMD2<Double>] {
        var points = polyline.points
        if polyline.isClosed, let first = points.first { points.append(first) }
        guard points.count > 1 else { return points }
        var result: [SIMD2<Double>] = []
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let segment = simd_length(b - a)
            let steps = max(1, Int(segment / step))
            for s in 0..<steps {
                result.append(a + (b - a) * (Double(s) / Double(steps)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    // MARK: - Text

    static func textOverlaps(in classification: Classification, textRegions: [CGRect]) -> [RemovalSuggestion] {
        guard !textRegions.isEmpty else { return [] }
        return classification.elements.compactMap { classified in
            let box = classified.element.boundingBox
            let overlapping = textRegions.contains { region in
                let intersection = region.intersection(box)
                guard !intersection.isNull, box.width * box.height > 0 else { return false }
                return intersection.width * intersection.height >= 0.5 * box.width * box.height
            }
            guard overlapping else { return nil }
            return RemovalSuggestion(elementID: classified.element.id, polylineIndex: nil, reason: .textLike)
        }
    }

    // MARK: - Edge artifacts

    /// Long thin elements hugging the image border: scanner bed edges, page
    /// shadows, photo edges.
    static func edgeArtifacts(in classification: Classification, imageSize: CGSize) -> [RemovalSuggestion] {
        let margin = 0.03 * min(imageSize.width, imageSize.height)
        let borderBand = CGRect(origin: .zero, size: imageSize).insetBy(dx: margin, dy: margin)
        return classification.elements.compactMap { classified in
            let box = classified.element.boundingBox
            guard !borderBand.contains(box) else { return nil }
            // Thin and elongated, or it's probably a drawing cropped by the edge.
            let aspect = Double(max(box.width, box.height)) / Double(max(1, min(box.width, box.height)))
            guard aspect >= 8 else { return nil }
            return RemovalSuggestion(elementID: classified.element.id, polylineIndex: nil, reason: .edgeArtifact)
        }
    }
}

/// Finds handwritten-label regions with Vision. Detection only — no need to
/// read the words, just to know where writing is.
enum TextDetector {
    /// - Parameter targetSize: coordinate space for the returned rects —
    ///   pass `TraceResult.imageSize`, which may be a downscale of `image`.
    static func textRegions(in image: CGImage, scaledTo targetSize: CGSize? = nil) async throws -> [CGRect] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        let observations = request.results ?? []
        let w = Double(targetSize?.width ?? CGFloat(image.width))
        let h = Double(targetSize?.height ?? CGFloat(image.height))
        // Vision rects are normalized with a bottom-left origin; traces use
        // top-left pixel coordinates.
        return observations.map { obs in
            let r = obs.boundingBox
            return CGRect(
                x: r.minX * w,
                y: (1 - r.maxY) * h,
                width: r.width * w,
                height: r.height * h
            )
        }
    }
}
