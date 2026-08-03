import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

/// Re-renders a flatbed scan the way a handheld iPhone photo sees it: paper
/// on a dark tabletop with a lighting gradient falling across the page.
/// Global thresholding turns the entire table into "ink" on frames like
/// these; the trace pipeline has to survive them.
enum PhotoComposite {
    struct Photo {
        let image: CGImage
        /// The paper rectangle mapped into traced-bitmap coordinates (y-down).
        let paperInTraceSpace: CGRect
    }

    static func photo(
        of scan: CGImage,
        paper: CGRect = CGRect(x: 500, y: 200, width: 1400, height: 1400)
    ) -> Photo {
        let width = 2400, height = 1800
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        // Dark wooden table.
        context.setFillColor(gray: 0.25, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Paper, slightly gray.
        context.setFillColor(gray: 0.82, alpha: 1)
        context.fill(paper)
        // Lighting falls off diagonally across the page.
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.35)] as CFArray,
            locations: [0, 1]
        )!
        context.saveGState()
        context.clip(to: paper)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: paper.minX, y: paper.minY),
            end: CGPoint(x: paper.maxX, y: paper.maxY),
            options: []
        )
        context.restoreGState()
        // The drawing itself.
        context.draw(scan, in: paper.insetBy(dx: 60, dy: 60))
        let image = context.makeImage()!

        // CG rects are y-up; the traced bitmap is y-down and downscaled.
        let traceSize = BinaryBitmap.traceSize(for: image)
        let scale = traceSize.width / CGFloat(width)
        let paperInTrace = CGRect(
            x: paper.minX * scale,
            y: (CGFloat(height) - paper.maxY) * scale,
            width: paper.width * scale,
            height: paper.height * scale
        )
        return Photo(image: image, paperInTraceSpace: paperInTrace)
    }
}

struct PhotoTraceTests {
    /// The time limit is part of the contract: before adaptive thresholding
    /// this frame spent minutes skeletonizing the table blob.
    @Test(.timeLimit(.minutes(1)))
    func photoOfPage1TracesOnlyMarksOnThePaper() throws {
        let scan = try FixtureTraceTests.fixtureImage("animals-page-1")
        let photo = PhotoComposite.photo(of: scan)
        let result = try #require(TraceEngine.trace(image: photo.image, detail: 0.7))

        #expect(result.elements.count >= 12, "got \(result.elements.count) elements")

        let imagePixels = Int(result.imageSize.width) * Int(result.imageSize.height)
        // Anti-aliasing at the trace scale can nudge a bbox a pixel or two.
        let paper = photo.paperInTraceSpace.insetBy(dx: -4, dy: -4)
        for element in result.elements {
            #expect(element.inkArea <= imagePixels * 8 / 100, "inkArea \(element.inkArea)")
            let coversFrame = element.boundingBox.width > 0.8 * result.imageSize.width
                && element.boundingBox.height > 0.8 * result.imageSize.height
            #expect(!coversFrame, "frame-sized bbox \(element.boundingBox)")
            #expect(paper.contains(element.boundingBox),
                    "bbox \(element.boundingBox) lies outside the paper \(paper)")
        }
        try SVGDump.write(result: result, name: "photo-composite-page-1")
    }

    /// A handheld shot often crops the paper at the frame; the frame edge is
    /// then the paper edge and carries the same seam artifacts, which must
    /// erode away just like along a visible paper boundary. (Regression: a
    /// 51×1051px solid bar with a ~50px "pen width" once survived along the
    /// cropped side because erosion only measured distance to visible
    /// off-paper pixels.)
    @Test(.timeLimit(.minutes(1)))
    func paperCroppedByFrameEdgeLeavesNoSeamBar() throws {
        let scan = try FixtureTraceTests.fixtureImage("animals-page-1")
        let photo = PhotoComposite.photo(of: scan, paper: CGRect(x: 0, y: 150, width: 1400, height: 1500))
        let result = try #require(TraceEngine.trace(image: photo.image, detail: 0.7))

        #expect(result.elements.count >= 12, "got \(result.elements.count) elements")

        // Pen strokes on these pages trace at ~2-7px width; a seam bar is an
        // order of magnitude fatter.
        let frame = CGRect(origin: .zero, size: result.imageSize).insetBy(dx: 2, dy: 2)
        for element in result.elements where !frame.contains(element.boundingBox) {
            #expect(element.estimatedStrokeWidth <= 15,
                    "frame-hugging element \(element.boundingBox) with stroke width \(element.estimatedStrokeWidth)")
        }
    }

    /// A real handheld photo where the page fills the entire frame, with
    /// soft lighting bands falling across it. (Regression: Otsu split the
    /// lit band from the shadowed band, the "largest bright region" became
    /// one lighting band, and the paper mask deleted the whole drawing —
    /// the user saw "Nothing to Trace".)
    @Test(.timeLimit(.minutes(1)))
    func fullFramePagePhotoKeepsItsDrawing() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let result = try #require(TraceEngine.trace(image: image, detail: 0.7))

        #expect(result.elements.count >= 6, "got \(result.elements.count) elements")
        let totalInk = result.elements.reduce(0) { $0 + $1.inkArea }
        #expect(totalInk >= 20_000, "total ink \(totalInk)")

        let imagePixels = Int(result.imageSize.width) * Int(result.imageSize.height)
        for element in result.elements {
            #expect(element.inkArea <= imagePixels * 8 / 100, "inkArea \(element.inkArea)")
            let coversFrame = element.boundingBox.width > 0.8 * result.imageSize.width
                && element.boundingBox.height > 0.8 * result.imageSize.height
            #expect(!coversFrame, "frame-sized bbox \(element.boundingBox)")
        }

        // The drawing (fish + enclosing circle + label) sits mid-frame; the
        // union of the traced elements must cover it.
        var union = CGRect.null
        for element in result.elements { union = union.union(element.boundingBox) }
        let drawingArea = CGRect(
            x: 0.30 * result.imageSize.width, y: 0.35 * result.imageSize.height,
            width: 0.35 * result.imageSize.width, height: 0.30 * result.imageSize.height
        )
        #expect(union.contains(drawingArea), "union \(union) misses the drawing at \(drawingArea)")

        // A page filling the frame offers no darker surround: the paper mask
        // must not fire on the page's own lighting bands.
        let report = try #require(result.binarization)
        #expect(!report.paperMaskActive)

        try SVGDump.write(result: result, name: "fish-photo-detail-0.7")
    }

    /// The diagnostics surface: paper on a dark table activates the mask
    /// and the report says so, carrying the statistics the gating read.
    @Test(.timeLimit(.minutes(1)))
    func binarizationReportRecordsMaskDecision() throws {
        let scan = try FixtureTraceTests.fixtureImage("animals-page-1")
        let photo = PhotoComposite.photo(of: scan)
        let result = try #require(TraceEngine.trace(image: photo.image, detail: 0.7))

        let report = try #require(result.binarization)
        #expect(report.paperMaskActive)
        #expect(report.paperCoverage > 0.2 && report.paperCoverage < 0.9,
                "coverage \(report.paperCoverage)")
        #expect(report.otsuClassSeparation > 100, "separation \(report.otsuClassSeparation)")
        #expect(report.paperSurroundContrast > 100, "surround \(report.paperSurroundContrast)")
        #expect(report.inkPixelCount > 0)
    }

    @Test func hugeFilledRegionIsDroppedNotSkeletonized() throws {
        let image = TestCanvas.image(size: 800) { ctx in
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: 60, y: 740))
            ctx.addLine(to: CGPoint(x: 740, y: 740))
            ctx.strokePath()
            // Nearly half the frame's pixels of solid fill.
            ctx.fill(CGRect(x: 100, y: 100, width: 600, height: 500))
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.8))
        // Only the pen stroke survives; the fill is background-sized garbage.
        #expect(result.elements.count == 1, "got \(result.elements.count) elements")
        #expect(result.elements.allSatisfy { $0.polylines.allSatisfy { !$0.isClosed } })
    }

    @Test func solidBlobLoopStaysWithinItsOwnFootprint() throws {
        let image = TestCanvas.image(size: 600) { ctx in
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: 40, y: 560))
            ctx.addLine(to: CGPoint(x: 560, y: 560))
            ctx.strokePath()
            // A solid disk skeletonizes to nothing and takes the loop
            // fallback; the loop must stay inside the disk, never balloon.
            ctx.fillEllipse(in: CGRect(x: 180, y: 150, width: 200, height: 200))
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.8))
        #expect(result.elements.contains { $0.totalLength > 400 }, "the stroke must survive")
        // CG y-up → bitmap y-down: the disk lands at y 250...450.
        let disk = CGRect(x: 180, y: 250, width: 200, height: 200).insetBy(dx: -6, dy: -6)
        for polyline in result.elements.flatMap(\.polylines) where polyline.isClosed {
            for point in polyline.points {
                #expect(disk.contains(CGPoint(x: point.x, y: point.y)),
                        "loop point \(point) escaped the disk \(disk)")
            }
        }
    }

    @Test func sparseScratchNeverSynthesizesAPhantomLoop() throws {
        let image = TestCanvas.image(size: 600) { ctx in
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: 40, y: 560))
            ctx.addLine(to: CGPoint(x: 560, y: 560))
            ctx.strokePath()
            // A spidery scratch: every arm is shorter than the coarse-detail
            // polyline floor, so nothing survives filtering — and the dot
            // fallback must not replace a sparse tangle with a solid loop.
            ctx.setLineWidth(2)
            for i in 0..<8 {
                let angle = Double(i) / 8 * 2 * .pi
                ctx.move(to: CGPoint(x: 300, y: 300))
                ctx.addLine(to: CGPoint(x: 300 + 11 * cos(angle), y: 300 + 11 * sin(angle)))
            }
            ctx.strokePath()
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.0))
        #expect(result.elements.count == 1, "got \(result.elements.count) elements")
        #expect(result.elements.allSatisfy { $0.polylines.allSatisfy { !$0.isClosed } })
    }

    @Test func frameSpanningComponentIsDropped() throws {
        let image = TestCanvas.image(size: 600) { ctx in
            ctx.setLineWidth(8)
            // A border spanning nearly the whole frame in both dimensions —
            // the shape a mis-thresholded background takes.
            ctx.stroke(CGRect(x: 5, y: 5, width: 590, height: 590))
            ctx.strokeEllipse(in: CGRect(x: 200, y: 200, width: 150, height: 150))
        }
        let result = try #require(TraceEngine.trace(image: image, detail: 0.8))
        try #require(result.elements.count == 1, "got \(result.elements.count) elements")
        let bbox = result.elements[0].boundingBox
        #expect(bbox.width < 200 && bbox.height < 200, "survivor should be the circle, got \(bbox)")
    }
}
