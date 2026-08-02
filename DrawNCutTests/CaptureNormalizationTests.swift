import CoreGraphics
import Testing
import UIKit
@testable import DrawNCut

struct CaptureNormalizationTests {
    /// A solid-red CGImage to make content loss detectable.
    private func redImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func centerPixelIsRed(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50
    }

    @Test func cameraOrientationIsBakedInWithoutScaleBlowup() {
        // Camera photos arrive rotated (.right) and UIImage carries a scale;
        // normalization must rotate pixels, pin scale to 1, and must NOT
        // multiply pixel dimensions by the screen scale (the 12MP → 110MP
        // black-photo failure).
        let source = UIImage(cgImage: redImage(width: 400, height: 300), scale: 3, orientation: .right)
        let normalized = source.normalizedForTrace()

        #expect(normalized.scale == 1)
        let cg = normalized.cgImage
        #expect(cg != nil)
        // .right rotation swaps dimensions; source pixels were 400×300.
        #expect(cg!.width == 100 && cg!.height == 133)
        #expect(centerPixelIsRed(cg!))
    }

    @Test func oversizedPhotosAreCappedAndContentSurvives() {
        let source = UIImage(cgImage: redImage(width: 4000, height: 3000), scale: 1, orientation: .up)
        let normalized = source.normalizedForTrace(maxDimension: 2600)
        let cg = normalized.cgImage
        #expect(cg != nil)
        #expect(max(cg!.width, cg!.height) == 2600)
        #expect(min(cg!.width, cg!.height) == 1950)
        #expect(centerPixelIsRed(cg!))
    }

    @Test func smallUprightPhotosPassThroughAtFullSize() {
        let source = UIImage(cgImage: redImage(width: 800, height: 600), scale: 1, orientation: .up)
        let normalized = source.normalizedForTrace()
        let cg = normalized.cgImage
        #expect(cg != nil)
        #expect(cg!.width == 800 && cg!.height == 600)
        #expect(centerPixelIsRed(cg!))
    }
}
