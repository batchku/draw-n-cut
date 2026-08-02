import CoreGraphics
import Foundation
import simd

/// Everything the Detail slider controls, derived from one 0...1 value.
/// All lengths are relative to the image diagonal so behavior is
/// resolution-independent.
struct TraceParameters: Equatable {
    /// Ink blobs smaller than this are dropped as noise (px²).
    var speckleMinArea: Int
    /// Traced curves shorter than this are dropped (px).
    var minPolylineLength: Double
    /// Douglas-Peucker tolerance (px).
    var simplifyTolerance: Double
    /// Chaikin smoothing passes.
    var smoothingPasses: Int

    /// - Parameters:
    ///   - detail: 1 keeps everything the pen did; 0 keeps only the boldest
    ///     marks, aggressively simplified.
    ///   - imageDiagonal: diagonal of the traced image in pixels.
    static func from(detail: Double, imageDiagonal: Double) -> TraceParameters {
        let d = max(0, min(1, detail))
        func lerp(_ coarse: Double, _ fine: Double) -> Double {
            coarse + (fine - coarse) * d
        }
        let unit = imageDiagonal / 1000.0   // ≈1px at 1000px diagonal
        let speckleSide = lerp(12, 2) * unit
        return TraceParameters(
            speckleMinArea: max(2, Int(speckleSide * speckleSide)),
            minPolylineLength: lerp(30, 3) * unit,
            simplifyTolerance: lerp(3.0, 0.6) * unit,
            smoothingPasses: d < 0.5 ? 2 : 1
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
}

/// Photo (or masked photo) in, centerline vector elements out.
enum TraceEngine {
    /// - Parameters:
    ///   - image: the rectified drawing.
    ///   - mask: optional subject mask (same dimensions as the binarized
    ///     image); ink outside the mask is ignored.
    ///   - detail: the single user-facing slider, 0...1.
    static func trace(image: CGImage, mask: BinaryBitmap? = nil, detail: Double) -> TraceResult? {
        guard var bitmap = BinaryBitmap(cgImage: image) else { return nil }
        if let mask {
            bitmap.intersect(mask)
        }
        let w = Double(bitmap.width)
        let h = Double(bitmap.height)
        let diagonal = (w * w + h * h).squareRoot()
        let parameters = TraceParameters.from(detail: detail, imageDiagonal: diagonal)
        let elements = trace(bitmap: bitmap, parameters: parameters)
        return TraceResult(
            elements: elements,
            imageSize: CGSize(width: bitmap.width, height: bitmap.height),
            parameters: parameters
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
        let repaired = Skeletonizer.mergedChains(despurred, tolerance: 2.5)

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
            let bbox = component.boundingBox
            let center = SIMD2(Double(bbox.midX), Double(bbox.midY))
            let radius = max(1.0, (Double(component.area) / Double.pi).squareRoot())
            let dot = (0..<8).map { i -> SIMD2<Double> in
                let angle = Double(i) / 8 * 2 * Double.pi
                return center + radius * SIMD2(cos(angle), sin(angle))
            }
            processed = [Polyline(points: dot, isClosed: true)]
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
