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

    /// Square, because the row's slot is square: framing the drawing itself
    /// means the photo's aspect ratio is no longer what decides the shape.
    @Test func theThumbnailIsASquareOfTheExpectedSize() throws {
        let image = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [],
            imageSize: CGSize(width: 2000, height: 1000)))
        #expect(image.width == Int(ThumbnailRenderer.maxSide))
        #expect(image.height == Int(ThumbnailRenderer.maxSide))
    }

    /// A subject mask in the corner of a big frame.
    private func cornerMask(size: Int = 200) -> BinaryBitmap {
        var bitmap = BinaryBitmap(width: size, height: size)
        for y in 20..<70 { for x in 20..<70 { bitmap[x, y] = true } }
        return bitmap
    }

    @Test func theFrameFollowsTheSubjectNotThePhoto() {
        let frame = ThumbnailRenderer.frame(
            imageSize: CGSize(width: 200, height: 200),
            subject: cornerMask(), lines: [])
        // Centred on the mask (45,45), not on the photo (100,100).
        #expect(abs(frame.midX - 45) < 2, "frame centred at \(frame.midX)")
        #expect(abs(frame.midY - 45) < 2)
        #expect(frame.width < 100, "the frame did not tighten onto the subject")
        #expect(frame.width == frame.height, "the frame must be square")
    }

    @Test func withoutAMaskTheFrameFollowsTheTracedLines() {
        let frame = ThumbnailRenderer.frame(
            imageSize: CGSize(width: 400, height: 400),
            subject: nil,
            lines: [Polyline(points: [SIMD2(300, 300), SIMD2(340, 340)], isClosed: false)])
        #expect(abs(frame.midX - 320) < 5, "frame centred at \(frame.midX)")
        #expect(frame.width < 200)
    }

    @Test func aBlankProjectFallsBackToTheWholeFrame() {
        let frame = ThumbnailRenderer.frame(
            imageSize: CGSize(width: 300, height: 200), subject: nil, lines: [])
        #expect(abs(frame.midX - 150) < 1)
        #expect(abs(frame.midY - 100) < 1)
    }

    /// The point of segmenting: everything outside the subject is cut away,
    /// so the row shows a drawing rather than a photo of a page.
    @Test func theBackgroundOutsideTheSubjectIsTransparent() throws {
        let image = try #require(ThumbnailRenderer.render(
            photo: greyPhoto(), engrave: [], cuts: [],
            imageSize: CGSize(width: 200, height: 200), subject: cornerMask()))
        let data = pixels(of: image)

        var opaque = 0
        var clear = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            if data[i + 3] > 200 { opaque += 1 } else if data[i + 3] < 40 { clear += 1 }
        }
        #expect(opaque > 0, "the subject itself was cut away too")
        #expect(clear > 0, "nothing was made transparent — the background is still there")
        // The mask is a square inside a padded square frame, so a good
        // fraction of the thumbnail must be clear.
        #expect(clear > data.count / 4 / 10,
                "only \(clear) transparent pixels — the cut-out barely happened")
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
