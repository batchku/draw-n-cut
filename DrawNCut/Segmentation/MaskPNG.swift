import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Persistence for the project's `mask.png`: 8-bit grayscale, 255 = subject.
/// PNG keeps it lossless and inspectable from the Files app.
enum MaskPNG {
    enum MaskPNGError: Error {
        case encodeFailed
        case writeFailed
    }

    static func write(_ mask: SegmentationMask, to url: URL) throws {
        var gray = [UInt8](repeating: 0, count: mask.width * mask.height)
        for i in gray.indices where mask.pixels[i] { gray[i] = 255 }
        guard
            let provider = CGDataProvider(data: Data(gray) as CFData),
            let image = CGImage(
                width: mask.width, height: mask.height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MaskPNGError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MaskPNGError.writeFailed }
    }

    /// Reads a mask PNG back as a `BinaryBitmap`, optionally resampled to
    /// `size`. Interpolation stays off — a resampled mask must keep hard
    /// edges, not grow a soft gray fringe that thresholds unpredictably.
    static func readBitmap(from url: URL, scaledTo size: CGSize? = nil) -> BinaryBitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = size.map { max(1, Int($0.width)) } ?? image.width
        let height = size.map { max(1, Int($0.height)) } ?? image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &gray,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bitmap = BinaryBitmap(width: width, height: height)
        for i in gray.indices where gray[i] > 127 { bitmap.pixels[i] = true }
        return bitmap
    }
}
