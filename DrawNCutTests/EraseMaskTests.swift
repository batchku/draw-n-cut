import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Erase-mask semantics: an erased region is blanked out of the ink before
/// analysis, so it can never re-trace — at any Detail setting.
struct EraseMaskTests {

    /// White page with black blobs, given in image space (y-down).
    private func page(width: Int = 400, height: Int = 400, blobs: [CGRect]) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        for blob in blobs {
            // CG fills y-up; flip so callers think in image space.
            context.fill(CGRect(
                x: blob.minX, y: Double(height) - blob.maxY,
                width: blob.width, height: blob.height
            ))
        }
        return try #require(context.makeImage())
    }

    private func elements(of result: TraceResult, intersecting rect: CGRect) -> Int {
        result.elements.count { $0.boundingBox.intersects(rect) }
    }

    @Test func lassoRasterizesInsideOnly() throws {
        let loop: [SIMD2<Double>] = [
            SIMD2(10, 10), SIMD2(50, 12), SIMD2(48, 52), SIMD2(12, 50),
        ]
        let mask = try #require(EraseMask.bitmap(from: [.lasso(points: loop)], width: 100, height: 100))
        #expect(mask[30, 30], "centroid of the loop must be erased")
        #expect(!mask[70, 70], "outside the loop must be untouched")
        #expect(!mask[5, 30], "left of the loop must be untouched")
    }

    @Test func brushStampsCapsuleAlongStroke() throws {
        let mask = try #require(EraseMask.bitmap(
            from: [.brush(points: [SIMD2(20, 50), SIMD2(80, 50)], radius: 6)],
            width: 100, height: 100
        ))
        #expect(mask[50, 50], "midpoint of the stroke must be erased")
        #expect(mask[50, 53], "within radius of the stroke must be erased")
        #expect(!mask[50, 70], "far from the stroke must be untouched")
    }

    /// The user's invariant: erase something, then move the Detail slider —
    /// the erased mark must not come back at any setting.
    @Test(arguments: [0.3, 0.7, 1.0])
    func erasedBlobNeverRetraces(detail: Double) throws {
        let blobA = CGRect(x: 60, y: 60, width: 60, height: 60)
        let blobB = CGRect(x: 260, y: 280, width: 60, height: 60)
        let image = try page(blobs: [blobA, blobB])

        // Both blobs trace without an erase mask.
        let plain = try #require(TraceEngine.trace(image: image, detail: detail))
        #expect(elements(of: plain, intersecting: blobA.insetBy(dx: -4, dy: -4)) > 0)
        #expect(elements(of: plain, intersecting: blobB.insetBy(dx: -4, dy: -4)) > 0)

        // Lasso around blob A: it must vanish, and blob B must survive.
        let loop: [SIMD2<Double>] = [
            SIMD2(40, 40), SIMD2(140, 40), SIMD2(140, 140), SIMD2(40, 140),
        ]
        let mask = try #require(EraseMask.bitmap(from: [.lasso(points: loop)], width: 400, height: 400))
        let erased = try #require(TraceEngine.trace(image: image, eraseMask: mask, detail: detail))
        #expect(elements(of: erased, intersecting: blobA.insetBy(dx: -4, dy: -4)) == 0,
                "erased blob re-traced at detail \(detail)")
        #expect(elements(of: erased, intersecting: blobB.insetBy(dx: -4, dy: -4)) > 0,
                "unerased blob lost at detail \(detail)")
    }

    /// The fallback CUT outline construction (stamped centerlines → dilate →
    /// contour) is closed and encloses the strokes it grew from, even for an
    /// open scribble that could never close itself.
    @Test func stampedOutlineIsClosedAroundOpenStrokes() throws {
        var bitmap = BinaryBitmap(width: 400, height: 400)
        let stroke: [SIMD2<Double>] = [
            SIMD2(100, 100), SIMD2(300, 120), SIMD2(180, 260), SIMD2(120, 300),
        ]
        EraseMask.stampStroke(stroke, radius: 2, into: &bitmap)
        let outline = try #require(MaskGeometry.stickerOutline(around: bitmap, offsetPixels: 17))
        #expect(outline.isClosed)
        for point in stroke {
            #expect(PathGeometry.polygon(outline.points, contains: point),
                    "stroke point \(point) escaped the outline")
        }
    }
}
