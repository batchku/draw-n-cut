import CoreGraphics
import Foundation
import simd

/// Everything the trace sliders control, derived from two 0...1 values:
/// Detail decides *which* marks survive, Smoothness decides *how* the
/// surviving curves are drawn. All lengths are relative to the image
/// diagonal so behavior is resolution-independent.
struct TraceParameters: Equatable {
    /// Ink blobs smaller than this are dropped as noise (px²).
    var speckleMinArea: Int
    /// Traced curves shorter than this are dropped (px).
    var minPolylineLength: Double
    /// Douglas-Peucker tolerance (px).
    var simplifyTolerance: Double
    /// Chaikin smoothing passes.
    var smoothingPasses: Int

    /// The Smoothness default: tolerance 1.5px and one Chaikin pass at a
    /// 1000px diagonal — the values the single Detail slider produced at its
    /// own default before the axes were split.
    static let defaultSmoothness = 0.4

    /// - Parameters:
    ///   - detail: 1 keeps everything the pen did; 0 keeps only the boldest
    ///     marks.
    ///   - smoothness: 0 follows the raster faithfully — jagged, every
    ///     corner kept; 1 simplifies hard and rounds every corner.
    ///   - imageDiagonal: diagonal of the traced image in pixels.
    static func from(
        detail: Double, smoothness: Double = defaultSmoothness, imageDiagonal: Double
    ) -> TraceParameters {
        let d = max(0, min(1, detail))
        let s = max(0, min(1, smoothness))
        // Piecewise-linear through the long-standing look at detail 0.7:
        // the middle of the range stays familiar while the extremes spread
        // much further — full-left now culls aggressively, full-right keeps
        // nearly everything.
        func wide(_ coarse: Double, _ anchor: Double, _ fine: Double) -> Double {
            d <= 0.7 ? coarse + (anchor - coarse) * (d / 0.7)
                     : anchor + (fine - anchor) * ((d - 0.7) / 0.3)
        }
        let unit = imageDiagonal / 1000.0   // ≈1px at 1000px diagonal
        let speckleSide = wide(20, 5, 1.5) * unit
        return TraceParameters(
            speckleMinArea: max(2, Int(speckleSide * speckleSide)),
            minPolylineLength: wide(60, 11, 2) * unit,
            // Quadratic through the default (0.4 → 1.5): the top end now
            // simplifies twice as hard as before so "all the way up" reads
            // unmistakably smooth.
            simplifyTolerance: (0.4 + 0.85 * s + 4.75 * s * s) * unit,
            smoothingPasses: s < 0.2 ? 0 : s < 0.6 ? 1 : s < 0.85 ? 2 : 3
        )
    }
}

/// One connected piece of ink, traced to centerline polylines with the
/// metrics classification needs. Coordinates are pixels in the traced image.
struct TracedElement: Identifiable {
    let id: UUID
    var polylines: [Polyline]
    var boundingBox: CGRect
    /// Ink pixels in the source component.
    var inkArea: Int
    /// Sum of centerline lengths (px).
    var totalLength: Double
    /// Ink area per centerline length ≈ pen stroke width (px).
    var estimatedStrokeWidth: Double

    var centroid: SIMD2<Double> {
        SIMD2(boundingBox.midX, boundingBox.midY)
    }
}

struct TraceResult {
    var elements: [TracedElement]
    var imageSize: CGSize
    var parameters: TraceParameters
    /// What binarization decided; nil when the result was built from an
    /// already-binarized bitmap rather than an image.
    var binarization: BinarizationReport? = nil
}

/// Photo (or masked photo) in, centerline vector elements out.
enum TraceEngine {
    /// - Parameters:
    ///   - image: the rectified drawing.
    ///   - mask: optional subject mask (same dimensions as the binarized
    ///     image); ink outside the mask is ignored.
    ///   - eraseMask: optional erase mask (same dimensions); ink inside it
    ///     is dropped before analysis, so erased marks cannot re-trace.
    ///   - detail: the single user-facing slider, 0...1.
    static func trace(
        image: CGImage, mask: BinaryBitmap? = nil, eraseMask: BinaryBitmap? = nil,
        detail: Double, smoothness: Double = TraceParameters.defaultSmoothness
    ) -> TraceResult? {
        var report: BinarizationReport?
        guard var bitmap = BinaryBitmap(cgImage: image, report: &report) else { return nil }
        if let mask {
            bitmap.intersect(mask)
        }
        if let eraseMask {
            bitmap.subtract(eraseMask)
        }
        let w = Double(bitmap.width)
        let h = Double(bitmap.height)
        let diagonal = (w * w + h * h).squareRoot()
        let parameters = TraceParameters.from(
            detail: detail, smoothness: smoothness, imageDiagonal: diagonal)
        let elements = trace(bitmap: bitmap, parameters: parameters)
        return TraceResult(
            elements: elements,
            imageSize: CGSize(width: bitmap.width, height: bitmap.height),
            parameters: parameters,
            binarization: report
        )
    }

    static func trace(bitmap: BinaryBitmap, parameters: TraceParameters) -> [TracedElement] {
        let components = bitmap.inkComponents(minArea: parameters.speckleMinArea)
        let imagePixels = bitmap.width * bitmap.height
        let diagonal = (Double(bitmap.width * bitmap.width) + Double(bitmap.height * bitmap.height)).squareRoot()
        return components.compactMap { component in
            // A drawn mark never spans (nearly) the whole frame in both
            // directions at once; a component that does is mis-thresholded
            // background, not pen work.
            if 10 * component.size.width > 8 * bitmap.width,
               10 * component.size.height > 8 * bitmap.height {
                return nil
            }
            // Thinning cost grows with area × thickness — a tenth of the
            // frame's pixels is already far beyond any dense scribble, and
            // skeletonizing a background-sized blob stalls for minutes.
            if 10 * component.area > imagePixels { return nil }
            return element(for: component, parameters: parameters, imageDiagonal: diagonal)
        }
    }

    private static func element(
        for component: InkComponent, parameters: TraceParameters, imageDiagonal: Double
    ) -> TracedElement? {
        let skeleton = Skeletonizer.skeleton(of: component.localBitmap())
        let offset = SIMD2(Double(component.origin.x), Double(component.origin.y))
        let raw = Skeletonizer.polylines(from: skeleton)

        // Thinning artifacts: spurs shorter than the pen width are noise, and
        // dropping them lets loop arcs re-join into proper closed loops.
        let rawLength = raw.reduce(0) { $0 + $1.length }
        let strokeWidth = rawLength > 0 ? Double(component.area) / rawLength : 1
        let despurred = raw.filter { $0.isClosed || $0.length > 1.5 * strokeWidth }
        // Merge tolerance scales with the pen: a fat marker's arcs land
        // farther apart at junctions than a fine liner's.
        let repaired = Skeletonizer.mergedChains(despurred, tolerance: max(2.5, 0.75 * strokeWidth))

        var processed: [Polyline] = repaired
            .filter { $0.length >= parameters.minPolylineLength }
            .map { PathGeometry.simplified($0, tolerance: parameters.simplifyTolerance) }
            .map { PathGeometry.smoothed($0, passes: parameters.smoothingPasses) }
            .map { polyline in
                Polyline(points: polyline.points.map { $0 + offset }, isClosed: polyline.isClosed)
            }

        // A filled dot (an eye, a freckle) or solid blob skeletonizes to
        // almost nothing — represent it as a small closed loop so it still
        // engraves. Only dot-sized marks and genuinely solid fills earn the
        // loop: a big sparse component whose curves all filtered away is
        // thresholding garbage, and synthesizing a loop from its area would
        // invent a mark the pen never made.
        if processed.isEmpty {
            let maxSide = Double(max(component.size.width, component.size.height))
            let density = Double(component.area) / Double(component.size.width * component.size.height)
            let isDot = maxSide <= max(0.02 * imageDiagonal, 12)
            let isSolidFill = density > 0.5 && maxSide <= 0.25 * imageDiagonal
            guard isDot || isSolidFill else { return nil }
            // The loop is the blob's own boundary: a squashed-quadrilateral
            // eye must engrave as one, not as a synthesized circle of equal
            // area (which read as a perfect octagon on screen). The blob is
            // only a few pixels across, so simplification is capped relative
            // to its size or the shape collapses.
            guard let contour = MaskGeometry.outerContour(of: component.localBitmap()) else {
                return nil
            }
            let tolerance = min(parameters.simplifyTolerance, max(0.75, 0.06 * maxSide))
            let shaped = PathGeometry.smoothed(
                PathGeometry.simplified(contour, tolerance: tolerance),
                passes: parameters.smoothingPasses
            )
            processed = [Polyline(points: shaped.points.map { $0 + offset }, isClosed: true)]
        }

        let totalLength = processed.reduce(0) { $0 + $1.length }
        return TracedElement(
            id: UUID(),
            polylines: processed,
            boundingBox: component.boundingBox,
            inkArea: component.area,
            totalLength: totalLength,
            estimatedStrokeWidth: totalLength > 0 ? Double(component.area) / totalLength : Double(component.area)
        )
    }
}
