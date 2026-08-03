import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

struct MaskGeometryTests {

    // MARK: - Synthetic masks

    private static func disc(width: Int, height: Int, center: SIMD2<Double>, radius: Double) -> BinaryBitmap {
        var bitmap = BinaryBitmap(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width
            where simd_length(SIMD2(Double(x), Double(y)) - center) <= radius {
                bitmap[x, y] = true
            }
        }
        return bitmap
    }

    private static func rect(_ box: CGRect, in bitmap: inout BinaryBitmap) {
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                bitmap[x, y] = true
            }
        }
    }

    // MARK: - Outer contour

    @Test func discContourIsClosedAndTight() throws {
        let bitmap = Self.disc(width: 100, height: 100, center: SIMD2(50, 50), radius: 30)
        let contour = try #require(MaskGeometry.outerContour(of: bitmap))
        #expect(contour.isClosed)
        #expect(contour.points.count > 20)

        // Contour bbox matches the disc bbox (pixel centers → within 1px).
        let box = PathGeometry.boundingBox(of: contour.points)
        #expect(abs(box.minX - 20) <= 1 && abs(box.maxX - 80) <= 1)
        #expect(abs(box.minY - 20) <= 1 && abs(box.maxY - 80) <= 1)

        // Every interior mask pixel lies inside the contour polygon (boundary
        // pixels sit ON the contour, so test strictly interior ones).
        for y in 0..<100 {
            for x in 0..<100 {
                let p = SIMD2(Double(x), Double(y))
                if simd_length(p - SIMD2(50, 50)) <= 28 {
                    #expect(PathGeometry.polygon(contour.points, contains: p), "(\(x), \(y)) escaped")
                }
            }
        }
    }

    @Test func lShapeContourFollowsConcaveCorner() throws {
        var bitmap = BinaryBitmap(width: 100, height: 100)
        Self.rect(CGRect(x: 20, y: 20, width: 20, height: 60), in: &bitmap)   // vertical bar
        Self.rect(CGRect(x: 20, y: 60, width: 60, height: 20), in: &bitmap)   // horizontal foot
        let contour = try #require(MaskGeometry.outerContour(of: bitmap))
        #expect(contour.isClosed)

        let box = PathGeometry.boundingBox(of: contour.points)
        #expect(abs(box.minX - 20) <= 1 && abs(box.maxX - 79) <= 1)
        #expect(abs(box.minY - 20) <= 1 && abs(box.maxY - 79) <= 1)

        // Interior points of both arms are inside…
        #expect(PathGeometry.polygon(contour.points, contains: SIMD2(30, 40)))
        #expect(PathGeometry.polygon(contour.points, contains: SIMD2(70, 70)))
        // …and the concave notch (top-right of the L) is outside.
        #expect(!PathGeometry.polygon(contour.points, contains: SIMD2(70, 40)))
    }

    @Test func donutYieldsOuterContourOnly() throws {
        var bitmap = Self.disc(width: 100, height: 100, center: SIMD2(50, 50), radius: 30)
        // Punch the hole.
        for y in 0..<100 {
            for x in 0..<100
            where simd_length(SIMD2(Double(x), Double(y)) - SIMD2(50, 50)) <= 12 {
                bitmap[x, y] = false
            }
        }
        let contour = try #require(MaskGeometry.outerContour(of: bitmap))
        #expect(contour.isClosed)

        // Outer boundary, not the hole's: bbox spans the outer disc…
        let box = PathGeometry.boundingBox(of: contour.points)
        #expect(box.width >= 58 && box.height >= 58)
        // …and both the hole center and a ring point are enclosed.
        #expect(PathGeometry.polygon(contour.points, contains: SIMD2(50, 50)))
        #expect(PathGeometry.polygon(contour.points, contains: SIMD2(50, 29)))
    }

    @Test func largestRegionWins() throws {
        var bitmap = Self.disc(width: 200, height: 100, center: SIMD2(60, 50), radius: 30)
        Self.rect(CGRect(x: 150, y: 40, width: 8, height: 8), in: &bitmap)   // speckle
        let contour = try #require(MaskGeometry.outerContour(of: bitmap))
        let box = PathGeometry.boundingBox(of: contour.points)
        #expect(box.maxX < 100, "contour should trace the disc, not the speckle")
    }

    @Test func emptyMaskHasNoContour() {
        #expect(MaskGeometry.outerContour(of: BinaryBitmap(width: 50, height: 50)) == nil)
    }

    // MARK: - Sticker offset

    @Test func stickerOffsetGrowsBBoxByTwiceOffsetAndContainsMask() throws {
        let radius = 20.0
        let offset = 15
        let bitmap = Self.disc(width: 120, height: 120, center: SIMD2(60, 60), radius: radius)
        let outline = try #require(MaskGeometry.stickerOutline(around: bitmap, offsetPixels: offset))
        #expect(outline.isClosed)

        // bbox grows by ~2×offset (chamfer is exact along the axes; simplify
        // + smoothing may pull extremes in by a couple of pixels).
        let box = PathGeometry.boundingBox(of: outline.points)
        let expected = 2 * (radius + Double(offset))
        #expect(abs(Double(box.width) - expected) <= 6, "width \(box.width) vs \(expected)")
        #expect(abs(Double(box.height) - expected) <= 6, "height \(box.height) vs \(expected)")

        // Every mask pixel is strictly inside the offset outline.
        for y in 0..<120 {
            for x in 0..<120 where bitmap[x, y] {
                #expect(PathGeometry.polygon(outline.points, contains: SIMD2(Double(x), Double(y))), "(\(x), \(y)) escaped")
            }
        }
    }

    @Test func stickerOffsetBridgesNarrowConcavities() throws {
        // Two blobs joined by a thin neck: an offset > the gap must produce
        // one closed outline (this is the case where offsetting the polygon
        // directly would self-intersect).
        var bitmap = BinaryBitmap(width: 200, height: 100)
        Self.rect(CGRect(x: 20, y: 30, width: 60, height: 40), in: &bitmap)
        Self.rect(CGRect(x: 120, y: 30, width: 60, height: 40), in: &bitmap)
        let outline = try #require(MaskGeometry.stickerOutline(around: bitmap, offsetPixels: 25))
        #expect(outline.isClosed)
        // The gap midpoint is swallowed by the offset.
        #expect(PathGeometry.polygon(outline.points, contains: SIMD2(100, 50)))
    }

    // MARK: - SegmentationMask bridge

    @Test func bridgeScalesNearestNeighbor() {
        // Left half of a 40×20 mask is subject.
        var pixels = [Bool](repeating: false, count: 40 * 20)
        for y in 0..<20 {
            for x in 0..<20 { pixels[y * 40 + x] = true }
        }
        let mask = SegmentationMask(width: 40, height: 20, pixels: pixels)

        let same = MaskGeometry.bitmap(from: mask)
        #expect(same.width == 40 && same.height == 20)
        #expect(same[10, 10] && !same[30, 10])

        let scaled = MaskGeometry.bitmap(from: mask, scaledTo: CGSize(width: 80, height: 40))
        #expect(scaled.width == 80 && scaled.height == 40)
        #expect(scaled[10, 20] && !scaled[70, 20])
        let fraction = Double(scaled.pixels.count(where: { $0 })) / Double(scaled.pixels.count)
        #expect(abs(fraction - 0.5) < 0.05)
    }

    // MARK: - mask.png round trip

    @Test func maskPNGRoundTripsAndRescales() throws {
        var pixels = [Bool](repeating: false, count: 64 * 48)
        for y in 12..<36 {
            for x in 16..<48 { pixels[y * 64 + x] = true }
        }
        let mask = SegmentationMask(width: 64, height: 48, pixels: pixels)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mask-roundtrip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try MaskPNG.write(mask, to: url)
        let restored = try #require(MaskPNG.readBitmap(from: url))
        #expect(restored.width == 64 && restored.height == 48)
        #expect(restored.pixels == pixels)

        let doubled = try #require(MaskPNG.readBitmap(from: url, scaledTo: CGSize(width: 128, height: 96)))
        #expect(doubled.width == 128 && doubled.height == 96)
        #expect(doubled[64, 48] && !doubled[8, 8])
    }
}
