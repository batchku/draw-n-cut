import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

private final class MaskedTraceBundleToken {}

/// The core product path: a subject mask confines the trace, and its
/// boundary — offset outward — becomes the closed sticker CUT outline.
struct MaskedTraceTests {

    @Test func maskConfinesTraceAndOutlineEnclosesMask() throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let traceSpace = BinaryBitmap.traceSize(for: image)
        let w = Int(traceSpace.width), h = Int(traceSpace.height)

        // Synthetic centered disc mask, quarter of the short edge in radius.
        let center = SIMD2(Double(w) / 2, Double(h) / 2)
        let radius = Double(min(w, h)) / 4
        var mask = BinaryBitmap(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w
            where simd_length(SIMD2(Double(x), Double(y)) - center) <= radius {
                mask[x, y] = true
            }
        }

        // Trace is confined to the mask.
        let result = try #require(TraceEngine.trace(image: image, mask: mask, detail: 0.7))
        #expect(!result.elements.isEmpty, "the disc covers part of the fish — something must trace")
        let maskBox = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: 2 * radius, height: 2 * radius
        )
        for element in result.elements {
            #expect(
                maskBox.insetBy(dx: -2, dy: -2).contains(element.boundingBox),
                "element \(element.boundingBox) leaked outside the mask"
            )
        }

        // The cut outline exists, is closed, and encloses the mask: every
        // rim point of the disc sits inside it, and its bbox contains the
        // mask bbox with the offset margin on every side. (The bbox *corners*
        // rightly stay outside — a disc's offset outline is a bigger disc,
        // not a rectangle.)
        let diagonal = Double(hypot(traceSpace.width, traceSpace.height))
        let offset = max(1, Int(0.03 * diagonal))
        let outline = try #require(MaskGeometry.stickerOutline(around: mask, offsetPixels: offset))
        #expect(outline.isClosed)
        for step in 0..<36 {
            let angle = Double(step) / 36 * 2 * Double.pi
            let rim = center + radius * SIMD2(cos(angle), sin(angle))
            #expect(PathGeometry.polygon(outline.points, contains: rim), "rim point \(rim) outside outline")
        }
        let outlineBox = PathGeometry.boundingBox(of: outline.points)
        let margin = Double(offset) - 6   // simplify + smoothing slack
        #expect(outlineBox.insetBy(dx: margin, dy: margin).contains(maskBox))
    }

    /// The file-based pipeline: a saved mask.png must confine the session's
    /// trace and surface the cut outline, exactly as the refine screen's
    /// "Use Outline" leaves things for the trace screen.
    @MainActor
    @Test func traceSessionHonorsSavedMaskPNG() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MaskedTraceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Fish")
        let fixtureURL = try #require(Bundle(for: MaskedTraceBundleToken.self)
            .url(forResource: "fish-photo", withExtension: "jpg"))
        try FileManager.default.copyItem(at: fixtureURL, to: store.originalImageURL(for: project))

        // Centered disc mask in trace space (the fixture loads as 1500×2000).
        let w = 1500, h = 2000
        let center = SIMD2(Double(w) / 2, Double(h) / 2)
        let radius = Double(w) / 4
        var pixels = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w
            where simd_length(SIMD2(Double(x), Double(y)) - center) <= radius {
                pixels[y * w + x] = true
            }
        }
        try MaskPNG.write(
            SegmentationMask(width: w, height: h, pixels: pixels),
            to: store.maskURL(for: project))

        let session = TraceSession(project: project, store: store)
        await session.load()
        for _ in 0..<600 where session.result == nil || session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }

        let result = try #require(session.result)
        #expect(!result.elements.isEmpty)
        let maskBox = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: 2 * radius, height: 2 * radius)
        for element in result.elements {
            #expect(maskBox.insetBy(dx: -2, dy: -2).contains(element.boundingBox))
        }
        let outline = try #require(session.cutOutlines.first)
        #expect(session.cutOutlines.allSatisfy { $0.isClosed })
        // The cut runs ON the mask's silhouette (offset 0): a point just
        // inside the rim is enclosed, and the outline's box matches the
        // mask's box within simplify/smoothing slack.
        #expect(PathGeometry.polygon(outline.points, contains: center + SIMD2(radius - 8, 0)))
        let outlineBox = PathGeometry.boundingBox(of: outline.points)
        let maskBounds = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: 2 * radius, height: 2 * radius)
        #expect(abs(outlineBox.minX - maskBounds.minX) < 8)
        #expect(abs(outlineBox.maxX - maskBounds.maxX) < 8)
        #expect(abs(outlineBox.minY - maskBounds.minY) < 8)
        #expect(abs(outlineBox.maxY - maskBounds.maxY) < 8)
    }

    @Test func exportPutsOutlineOnCutLayerAndKeepsEngraveDefault() {
        let engrave = Polyline(points: [SIMD2(10, 10), SIMD2(90, 10), SIMD2(90, 90)], isClosed: false)
        let outline = Polyline(
            points: [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 100), SIMD2(0, 100)], isClosed: true)

        let paths = DXFExportBuilder.vectorPaths(from: [engrave], cutOutlines: [outline], widthMM: 100)
        #expect(paths.count == 2)
        #expect(paths[0].role == .engrave)
        #expect(paths[1].role == .cut)
        #expect(paths[1].isClosed)
        // The outline participates in scaling: 100px box → 100mm.
        #expect(abs(paths[1].points[1].x - 100) < 0.001)

        // No outline → exactly the old behavior.
        let plain = DXFExportBuilder.vectorPaths(from: [engrave], widthMM: 100)
        #expect(plain.count == 1 && plain[0].role == .engrave)

        let dxf = DXFExportBuilder.dxf(from: [engrave], cutOutlines: [outline], widthMM: 100)
        #expect(dxf.contains("CUT") && dxf.contains("ENGRAVE"))
    }
}
