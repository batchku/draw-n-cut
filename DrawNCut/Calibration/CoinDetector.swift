import CoreGraphics
import Foundation
import Vision
import simd

/// What was found in a photo, and how sure we are.
struct CoinCandidate: Equatable {
    var ellipse: FittedEllipse
    /// Contour deviation from the fitted ellipse, as a fraction of the
    /// semi-major axis. Lower is rounder.
    var residual: Double
    /// 0...1, for the UI to say how confident this is.
    var confidence: Double
}

/// Finds the coin the user laid on the drawing.
///
/// Two stages, on purpose. **Candidates** come from Vision's contour
/// detector, which is Apple's own edge extraction rather than a threshold of
/// ours. **Selection** is geometric: each candidate contour is fitted with an
/// ellipse and scored by how well it actually fits, plus how plausible its
/// size and tilt are. A drawn circle is not rejected by being a circle — it
/// is rejected by the size band and by preferring the roundest, most
/// coin-sized candidate, and ultimately by the user confirming.
///
/// The candidate stage is the part a trained detector should replace: swap
/// `candidates(in:)` for a Core ML detector's boxes, keep the ellipse fit and
/// the scoring exactly as they are. The fit is what gives sub-pixel accuracy,
/// and a bounding box would throw that away, so it stays whatever finds the
/// coin.
enum CoinDetector {
    /// A coin on a photographed page: not a speck, not the whole frame.
    /// Fractions of the frame's short side.
    static let minimumSizeFraction = 0.02
    static let maximumSizeFraction = 0.30

    /// Contour deviation beyond which the shape simply is not an ellipse.
    static let maximumResidual = 0.06

    /// Best candidate, or nil when nothing in the photo looks like a coin.
    static func detect(in image: CGImage) -> CoinCandidate? {
        scored(in: image).first
    }

    /// Every plausible coin, best first. Exposed so the UI can offer the
    /// runner-up when the top pick is wrong.
    static func scored(in image: CGImage) -> [CoinCandidate] {
        let shortSide = Double(min(image.width, image.height))
        let minSemi = minimumSizeFraction * shortSide / 2
        let maxSemi = maximumSizeFraction * shortSide / 2

        return candidates(in: image).compactMap { polygon -> CoinCandidate? in
            guard let ellipse = EllipseFit.fit(polygon: polygon) else { return nil }
            guard ellipse.semiMajor >= minSemi, ellipse.semiMajor <= maxSemi else { return nil }
            guard ellipse.tilt <= CoinRectifier.maximumTilt else { return nil }
            let residual = EllipseFit.residual(of: polygon, to: ellipse)
            guard residual <= maximumResidual else { return nil }
            return CoinCandidate(
                ellipse: ellipse,
                residual: residual,
                confidence: confidence(residual: residual, ellipse: ellipse, shortSide: shortSide)
            )
        }
        .sorted { $0.confidence > $1.confidence }
    }

    /// Roundness of fit dominates; a coin filling a sensible part of the
    /// frame and not absurdly tilted is worth a little more.
    static func confidence(
        residual: Double, ellipse: FittedEllipse, shortSide: Double
    ) -> Double {
        let fit = max(0, 1 - residual / maximumResidual)
        let size = ellipse.semiMajor * 2 / shortSide
        // Best around a tenth of the frame, tapering either side.
        let sizeScore = max(0, 1 - abs(size - 0.10) / 0.20)
        let tiltScore = max(0, 1 - ellipse.tilt / CoinRectifier.maximumTilt)
        return 0.65 * fit + 0.2 * sizeScore + 0.15 * tiltScore
    }

    /// Closed contours from Vision, in image pixels with y down.
    private static func candidates(in image: CGImage) -> [[SIMD2<Double>]] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return [] }

        let w = Double(image.width), h = Double(image.height)
        var polygons: [[SIMD2<Double>]] = []
        for contour in observation.topLevelContours {
            collect(contour, into: &polygons, width: w, height: h)
        }
        return polygons
    }

    /// A coin's edge can come back as a child contour (the rim inside the
    /// page's own outline), so the whole tree is walked rather than just the
    /// top level.
    private static func collect(
        _ contour: VNContour, into polygons: inout [[SIMD2<Double>]],
        width: Double, height: Double
    ) {
        // Simplifying first drops sampling noise that would otherwise inflate
        // the fit residual of a perfectly good circle.
        let simplified = (try? contour.polygonApproximation(epsilon: 0.002)) ?? contour
        if simplified.pointCount >= 8 {
            polygons.append(simplified.normalizedPoints.map { point in
                // Vision is normalized with the origin bottom-left.
                SIMD2(Double(point.x) * width, (1 - Double(point.y)) * height)
            })
        }
        for child in contour.childContours {
            collect(child, into: &polygons, width: width, height: height)
        }
    }
}
