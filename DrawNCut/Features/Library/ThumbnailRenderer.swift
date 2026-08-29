import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The library's per-drawing thumbnail: the photograph with the traced lines
/// laid over it. Neither alone identifies a drawing at this size — the photo
/// is too busy and the vectors are too sparse — so the thumbnail is the
/// combination, with the lines kept translucent so the drawing underneath
/// still reads.
enum ThumbnailRenderer {
    /// Longest edge of the written image. Generous enough for a Retina list
    /// row without making the library slow to load.
    static let maxSide = 320.0

    /// How much of the photo shows through the traced lines.
    static let lineOpacity = 0.55

    /// - Parameters:
    ///   - photo: the project's original photograph.
    ///   - engrave: blue lines, in `imageSize` coordinates.
    ///   - cuts: red lines, same space.
    ///   - imageSize: the trace-space size those coordinates belong to.
    static func render(
        photo: CGImage, engrave: [Polyline], cuts: [Polyline], imageSize: CGSize
    ) -> CGImage? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = maxSide / max(imageSize.width, imageSize.height)
        let w = max(1, Int(imageSize.width * scale))
        let h = max(1, Int(imageSize.height * scale))
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Line width is in thumbnail points, not scaled down with the image:
        // scaled, every stroke would land under a pixel and vanish.
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        draw(engrave, in: context, height: h, scale: scale,
             red: 0.15, green: 0.35, blue: 0.95)
        context.setLineWidth(1.8)
        draw(cuts, in: context, height: h, scale: scale,
             red: 0.90, green: 0.15, blue: 0.15)

        return context.makeImage()
    }

    private static func draw(
        _ polylines: [Polyline], in context: CGContext, height h: Int, scale: Double,
        red: Double, green: Double, blue: Double
    ) {
        context.setStrokeColor(red: red, green: green, blue: blue, alpha: lineOpacity)
        for polyline in polylines {
            guard let first = polyline.points.first else { continue }
            // Flip y: trace space is y-down, CGContext is y-up.
            context.move(to: CGPoint(x: first.x * scale, y: Double(h) - first.y * scale))
            for point in polyline.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * scale, y: Double(h) - point.y * scale))
            }
            if polyline.isClosed { context.closePath() }
            context.strokePath()
        }
    }

    static func write(
        photo: CGImage, engrave: [Polyline], cuts: [Polyline],
        imageSize: CGSize, to url: URL
    ) {
        guard let image = render(
            photo: photo, engrave: engrave, cuts: cuts, imageSize: imageSize) else { return }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
