import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// What the laser is actually given. A cut path that crosses itself encloses
/// extra regions, and every enclosed region gets cut — so the part comes off
/// the bed in pieces. This is the end-to-end guarantee, through a real
/// session with a tight subject mask, which is where the crossings came from:
/// snapping drags stretches of the contour onto the drawing's strokes and two
/// stretches get pulled past each other.
@MainActor
struct CutOutlineQualityTests {

    private func session() async throws -> (TraceSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CutQuality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Creature")
        let image = EngraveCoverageTests.creature()
        try TestImageFile.writeJPEG(image, to: store.originalImageURL(for: project))

        let space = BinaryBitmap.traceSize(for: image)
        let mask = EngraveCoverageTests.silhouette(
            of: image, width: Int(space.width), height: Int(space.height))
        try MaskPNG.write(
            SegmentationMask(width: mask.width, height: mask.height, pixels: mask.pixels),
            to: store.maskURL(for: project))

        let session = TraceSession(project: project, store: store)
        await session.load()
        try await session.settle()
        return (session, root)
    }

    @Test func theCutOutlineNeverCrossesItself() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        try #require(!session.cutOutlines.isEmpty, "no cut outline was produced")
        for (index, outline) in session.cutOutlines.enumerated() {
            #expect(OutlineCleanup.isSimple(outline),
                    "cut loop \(index) crosses itself — it would cut the part into scraps")
        }
    }

    /// At every Cut slider setting, not just the default. The user reported
    /// the crossings surviving with Detail at the bottom and Smoothing at the
    /// top, so those extremes are covered explicitly.
    @Test func theCutStaysSimpleAcrossTheCutSliders() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        for (detail, smoothing) in [(0.0, 1.0), (0.0, 0.0), (1.0, 1.0), (0.7, 0.4)] {
            session.outlineDetail = detail
            session.outlineSmoothness = smoothing
            // The outline refresh is debounced and detached.
            try await Task.sleep(for: .milliseconds(700))
            for outline in session.cutOutlines {
                #expect(OutlineCleanup.isSimple(outline),
                        "detail \(detail) / smoothing \(smoothing) produced a self-crossing cut")
            }
        }
    }

    /// Cleaning must not eat the shape it is cleaning.
    @Test func theCutStillEnclosesTheDrawing() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        let outline = try #require(session.cutOutlines.max { $0.length < $1.length })
        let box = PathGeometry.boundingBox(of: outline.points)
        let size = try #require(session.result?.imageSize)
        // The creature fills most of the frame; the cut must still wrap it.
        #expect(box.width > size.width * 0.4, "the cut shrank to \(box.width) wide")
        #expect(box.height > size.height * 0.4, "the cut shrank to \(box.height) tall")
    }
}
