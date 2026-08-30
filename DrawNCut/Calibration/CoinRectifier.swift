import CoreGraphics
import Foundation
import simd

/// Turns a coin's ellipse into a correction for the photo, plus the scale
/// that comes free with it.
///
/// A circle photographed off-axis foreshortens along exactly one direction —
/// the ellipse's minor axis — by the cosine of the tilt. Stretching that
/// direction back out by the axis ratio makes the coin round again, and makes
/// the page it sits on square again with it. Because the correction is a pure
/// stretch (a symmetric matrix, no rotation term), the drawing keeps the
/// orientation it was photographed in; nothing spins.
///
/// **What this does not do.** A single circle fixes foreshortening, not full
/// perspective: it cannot recover the vanishing line without the camera's
/// focal length, so lines that converge across a page still converge a
/// little. Shooting from further back, more square on, makes the residual
/// smaller. Recovering the rest needs intrinsics and resolving a two-fold
/// pose ambiguity, and the coin's own face to fix rotation.
struct CoinRectifier: Equatable {
    /// Maps photo pixels to corrected pixels, about the coin's centre.
    var transform: CGAffineTransform
    /// Real-world size of one pixel in the corrected image.
    var millimetersPerPixel: Double
    /// The tilt that was corrected, radians — for telling the user how far
    /// off square the shot was.
    var tilt: Double

    /// A tilt beyond this means the coin is so foreshortened that its minor
    /// axis is only a few pixels, and the correction amplifies that error
    /// across the whole page. About 70 degrees.
    static let maximumTilt = 1.22

    /// - Parameters:
    ///   - ellipse: the coin as it appears in the photo.
    ///   - diameterMM: the coin's real diameter.
    init?(ellipse: FittedEllipse, diameterMM: Double = ScaleInfo.quarterDiameterMM) {
        guard ellipse.semiMajor > 0, ellipse.semiMinor > 0, diameterMM > 0 else { return nil }
        let tilt = ellipse.tilt
        guard tilt <= Self.maximumTilt else { return nil }

        // Rotate the minor axis onto y, stretch y by 1/axisRatio, rotate back.
        // The result is symmetric: a stretch, with no rotation of its own.
        let stretch = ellipse.semiMajor / ellipse.semiMinor
        let toAxes = CGAffineTransform(rotationAngle: -ellipse.angle)
        let expand = CGAffineTransform(scaleX: 1, y: stretch)
        let fromAxes = CGAffineTransform(rotationAngle: ellipse.angle)
        let about = CGPoint(x: ellipse.center.x, y: ellipse.center.y)

        self.transform = CGAffineTransform(translationX: -about.x, y: -about.y)
            .concatenating(toAxes)
            .concatenating(expand)
            .concatenating(fromAxes)
            .concatenating(CGAffineTransform(translationX: about.x, y: about.y))
        // After correction the coin is a circle of the major axis's radius,
        // so that radius is the known diameter.
        self.millimetersPerPixel = diameterMM / (2 * ellipse.semiMajor)
        self.tilt = tilt
    }

    /// Renders the corrected photo. The output grows to hold the stretched
    /// frame rather than cropping, so nothing of the drawing is lost, and is
    /// capped so a steep correction cannot produce an enormous image.
    func rectified(_ image: CGImage, maxDimension: Int = 3000) -> CGImage? {
        let source = CGSize(width: image.width, height: image.height)
        let bounds = correctedBounds(of: source)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let fit = min(1, Double(maxDimension) / max(bounds.width, bounds.height))
        let outputWidth = max(1, Int(bounds.width * fit))
        let outputHeight = max(1, Int(bounds.height * fit))

        guard let context = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // Paper white, so the corners the stretch exposes read as page rather
        // than as black bars the tracer would then have to reject.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        // Work in the same y-down space the transform is written in.
        context.translateBy(x: 0, y: CGFloat(outputHeight))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: CGFloat(fit), y: CGFloat(fit))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(transform)
        // CGContext draws images bottom-up; flip locally so the photo lands
        // upright in a y-down frame.
        context.translateBy(x: 0, y: source.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: source))

        return context.makeImage()
    }

    /// The corrected position of a point in the photo.
    func apply(to point: SIMD2<Double>) -> SIMD2<Double> {
        let mapped = CGPoint(x: point.x, y: point.y).applying(transform)
        return SIMD2(mapped.x, mapped.y)
    }

    /// The bounds a whole photo occupies once corrected — the stretch pushes
    /// content outside the original frame, so the output has to grow to hold
    /// it rather than cropping the drawing away.
    func correctedBounds(of size: CGSize) -> CGRect {
        let corners = [
            SIMD2(0.0, 0.0), SIMD2(Double(size.width), 0),
            SIMD2(Double(size.width), Double(size.height)), SIMD2(0, Double(size.height)),
        ].map(apply)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(
            x: xs.min()!, y: ys.min()!,
            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!
        )
    }
}
