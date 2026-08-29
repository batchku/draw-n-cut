import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The library's per-drawing thumbnail: the segmented drawing on a clear
/// background, centred, with its traced lines over it.
///
/// A raw crop of the photograph does not work at this size — the page, the
/// table and the lighting fill the square and every drawing looks the same.
/// What identifies a drawing is the drawing: cut out by its own subject mask,
/// framed to its own bounds, with the cut and engrave lines laid over the top
/// so the thumbnail also says what was traced.
enum ThumbnailRenderer {
    /// Side of the written square. Generous enough for a Retina list row
    /// without making the library slow to load.
    static let maxSide = 320.0

    /// How much of the photo shows through the traced lines.
    static let lineOpacity = 0.55

    /// Breathing room around the drawing, as a fraction of its longest side.
    static let padding = 0.06

    /// - Parameters:
    ///   - photo: the project's original photograph.
    ///   - engrave: blue lines, in `imageSize` coordinates.
    ///   - cuts: red lines, same space.
    ///   - imageSize: the trace-space size those coordinates belong to.
    ///   - subject: the subject mask, when the drawing has been segmented.
    ///     Without one the background cannot be removed, and the thumbnail
    ///     falls back to framing the traced lines' own extent.
    static func render(
        photo: CGImage, engrave: [Polyline], cuts: [Polyline], imageSize: CGSize,
        subject: BinaryBitmap? = nil
    ) -> CGImage? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let crop = frame(imageSize: imageSize, subject: subject, lines: engrave + cuts)
        guard crop.width > 0 else { return nil }

        let side = Int(maxSide)
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // Transparent, not white: the row shows the drawing, not a page.
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))

        let scale = maxSide / crop.width
        // Image space is y-down, CGContext is y-up.
        func toCanvas(_ point: SIMD2<Double>) -> CGPoint {
            CGPoint(
                x: (point.x - crop.minX) * scale,
                y: maxSide - (point.y - crop.minY) * scale
            )
        }
        let photoRect = CGRect(
            x: -crop.minX * scale,
            y: maxSide - (imageSize.height - crop.minY) * scale,
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        if let subject, let cutout = maskImage(from: subject) {
            context.saveGState()
            context.clip(to: photoRect, mask: cutout)
            context.draw(photo, in: photoRect)
            context.restoreGState()
        } else {
            context.draw(photo, in: photoRect)
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(1.2)
        draw(engrave, in: context, toCanvas: toCanvas, red: 0.15, green: 0.35, blue: 0.95)
        context.setLineWidth(1.8)
        draw(cuts, in: context, toCanvas: toCanvas, red: 0.90, green: 0.15, blue: 0.15)

        return context.makeImage()
    }

    /// The square of image space the thumbnail shows: the drawing's own
    /// bounds, padded, expanded to a square about its centre. The square is
    /// deliberately not clamped to the photo — a drawing near an edge stays
    /// centred, with transparency beside it, rather than being shoved
    /// off-centre to keep the frame full.
    static func frame(
        imageSize: CGSize, subject: BinaryBitmap?, lines: [Polyline]
    ) -> CGRect {
        var bounds = subject.flatMap(inkBounds) ?? lineBounds(lines)
            ?? CGRect(origin: .zero, size: imageSize)
        if bounds.width <= 0 || bounds.height <= 0 {
            bounds = CGRect(origin: .zero, size: imageSize)
        }
        let pad = max(bounds.width, bounds.height) * padding
        bounds = bounds.insetBy(dx: -pad, dy: -pad)
        let side = max(bounds.width, bounds.height)
        return CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side, height: side
        )
    }

    private static func inkBounds(_ bitmap: BinaryBitmap) -> CGRect? {
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap[x, y] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func lineBounds(_ lines: [Polyline]) -> CGRect? {
        let points = lines.flatMap(\.points)
        guard !points.isEmpty else { return nil }
        return PathGeometry.boundingBox(of: points)
    }

    /// A grayscale image where the subject is white — what `clip(to:mask:)`
    /// paints through.
    private static func maskImage(from bitmap: BinaryBitmap) -> CGImage? {
        var gray = [UInt8](repeating: 0, count: bitmap.width * bitmap.height)
        for i in bitmap.pixels.indices where bitmap.pixels[i] { gray[i] = 255 }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bitmap.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func draw(
        _ polylines: [Polyline], in context: CGContext,
        toCanvas: (SIMD2<Double>) -> CGPoint,
        red: Double, green: Double, blue: Double
    ) {
        context.setStrokeColor(red: red, green: green, blue: blue, alpha: lineOpacity)
        for polyline in polylines {
            guard let first = polyline.points.first else { continue }
            context.move(to: toCanvas(first))
            for point in polyline.points.dropFirst() { context.addLine(to: toCanvas(point)) }
            if polyline.isClosed { context.closePath() }
            context.strokePath()
        }
    }

    static func write(
        photo: CGImage, engrave: [Polyline], cuts: [Polyline],
        imageSize: CGSize, subject: BinaryBitmap? = nil, to url: URL
    ) {
        guard let image = render(
            photo: photo, engrave: engrave, cuts: cuts,
            imageSize: imageSize, subject: subject) else { return }
        // PNG, not JPEG: the cut-out background has to stay transparent.
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
