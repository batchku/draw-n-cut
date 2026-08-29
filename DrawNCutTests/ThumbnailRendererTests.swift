import CoreGraphics
import ImageIO
import Foundation
import Testing
import simd
@testable import DrawNCut

/// The library thumbnail is the photo with the traced lines over it, kept
/// translucent so the drawing underneath still reads. Both halves matter:
/// lines alone are too sparse to recognise a drawing by, and the photo alone
/// does not show what was traced.
struct ThumbnailRendererTests {

    /// A mid-grey photo, so a drawn line is unambiguously distinguishable
    /// from the background and from an opaque overlay.
    private func greyPhoto(size: Int = 200) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func pixels(of image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &data, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func horizontalLine(y: Double) -> Polyline {
        Polyline(points: (0...20).map { SIMD2(Double($0) * 10, y) }, isClosed: false)
    }

    @Test func theThumbnailFitsInsideItsLongestEdge() throws {
        let image = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [],
            imageSize: CGSize(width: 2000, height: 1000)))
        #expect(max(image.width, image.height) == Int(ThumbnailRenderer.maxSide))
        // Aspect ratio survives, so drawings are not squashed in the list.
        #expect(abs(Double(image.width) / Double(image.height) - 2) < 0.02)
    }

    @Test func theTracedLinesAreActuallyDrawn() throws {
        let size = CGSize(width: 200, height: 200)
        let bare = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [], imageSize: size))
        let lined = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [horizontalLine(y: 100)], cuts: [], imageSize: size))
        #expect(pixels(of: bare) != pixels(of: lined), "the engrave line was not drawn")
    }

    /// The specific ask: the lines must not hide the photograph.
    @Test func linesAreTranslucentSoThePhotoShowsThrough() throws {
        let size = CGSize(width: 200, height: 200)
        let lined = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [horizontalLine(y: 100)], cuts: [], imageSize: size))
        let data = pixels(of: lined)

        // The bluest pixel in the image is the middle of the engrave line.
        var strongest: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
        var bestLead = -1
        for i in stride(from: 0, to: data.count, by: 4) {
            let lead = Int(data[i + 2]) - Int(data[i])
            if lead > bestLead {
                bestLead = lead
                strongest = (data[i], data[i + 1], data[i + 2])
            }
        }
        #expect(bestLead > 10, "no blue line found in the thumbnail at all")
        // Pure line colour would be near (38, 89, 242). Composited at ~55%
        // over mid-grey it must land visibly short of that.
        #expect(strongest.b < 220, "the line is drawn opaque: blue \(strongest.b)")
        #expect(strongest.r > 40,
                "the photo is fully hidden under the line: red \(strongest.r)")
    }

    @Test func cutsAndEngravesAreToldApart() throws {
        let size = CGSize(width: 200, height: 200)
        let asEngrave = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [horizontalLine(y: 100)], cuts: [], imageSize: size))
        let asCut = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [horizontalLine(y: 100)], imageSize: size))
        #expect(pixels(of: asEngrave) != pixels(of: asCut),
                "a cut and an engrave line look identical in the thumbnail")
    }

    @Test func aDrawingWithNoTraceStillProducesAThumbnail() throws {
        let image = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [],
            imageSize: CGSize(width: 200, height: 200)))
        #expect(image.width > 0 && image.height > 0)
    }

    @Test func aDegenerateSizeIsRefusedRatherThanCrashing() {
        #expect(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [], imageSize: .zero) == nil)
    }

    @Test func writingProducesAReadableFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        ThumbnailRenderer.write(
            photo: greyPhoto(), engrave: [horizontalLine(y: 100)], cuts: [],
            imageSize: CGSize(width: 200, height: 200), to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width > 0)
    }
}
