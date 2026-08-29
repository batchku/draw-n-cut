import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Tapping a blue engrave line turns it red (a CUT path) and tapping it again
/// turns it back. This regressed once and shipped unnoticed, so the behavior
/// is pinned here at the level the screen actually drives it.
@MainActor
struct CutPromotionTests {

    /// A session over a synthetic two-stroke drawing, traced and ready.
    private func loadedSession() async throws -> (TraceSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CutPromotion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Two Strokes")

        let image = TestCanvas.image(size: 400) { ctx in
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: 60, y: 120))
            ctx.addLine(to: CGPoint(x: 340, y: 120))
            ctx.move(to: CGPoint(x: 60, y: 280))
            ctx.addLine(to: CGPoint(x: 340, y: 280))
            ctx.strokePath()
        }
        try TestImageFile.writeJPEG(image, to: store.originalImageURL(for: project))

        let session = TraceSession(project: project, store: store)
        await session.load()
        try await session.settle()
        try #require(!session.visible.isEmpty, "fixture traced to nothing")
        return (session, root)
    }

    /// A point sitting on the first visible polyline, in image space.
    private func pointOnFirstLine(_ session: TraceSession) throws -> SIMD2<Double> {
        let polyline = try #require(session.visible.first?.polyline)
        return polyline.points[polyline.points.count / 2]
    }

    @Test func tappingALinePromotesItToCut() async throws {
        let (session, root) = try await loadedSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = session.visible.count
        #expect(session.promotedCuts.isEmpty)

        session.toggleCut(at: try pointOnFirstLine(session))

        #expect(session.promotedCuts.count == 1, "the tapped line did not become a cut")
        #expect(session.visible.count == before - 1,
                "the promoted line's blue source must hide so it doesn't double up")
    }

    @Test func tappingAPromotedCutAgainDemotesIt() async throws {
        let (session, root) = try await loadedSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = session.visible.count
        let point = try pointOnFirstLine(session)
        session.toggleCut(at: point)
        try #require(session.promotedCuts.count == 1)

        // Tap the same place: now the nearest thing is the frozen red copy.
        session.toggleCut(at: point)

        #expect(session.promotedCuts.isEmpty, "the cut did not go back to engrave")
        #expect(session.visible.count == before, "the blue source must come back")
    }

    @Test func tappingEmptySpaceChangesNothing() async throws {
        let (session, root) = try await loadedSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = session.visible.count

        // Far from any stroke: between the two lines is still within a
        // forgiving radius, so go to a corner instead.
        session.toggleCut(at: SIMD2(5, 5))

        #expect(session.promotedCuts.isEmpty)
        #expect(session.visible.count == before)
    }

    @Test func promotedCutsSurviveASaveAndRestore() async throws {
        let (session, root) = try await loadedSession()
        defer { try? FileManager.default.removeItem(at: root) }

        session.toggleCut(at: try pointOnFirstLine(session))
        try #require(session.promotedCuts.count == 1)
        let promotedPoints = session.promotedCuts[0].points.count
        try session.saveVersion()

        let version = try #require(session.project.traceVersions.last)
        session.toggleCut(at: session.promotedCuts[0].points[promotedPoints / 2])
        try #require(session.promotedCuts.isEmpty, "precondition: demoted before restoring")

        session.restore(version)
        try await session.settle()
        #expect(session.promotedCuts.count == 1, "a saved cut did not come back")
    }
}

/// Once the brush or point editing has run, the trace is frozen into
/// `editedPaths` and that is what the canvas draws. Tap-to-cut has to keep
/// working there too: it is the same gesture on the same line, and the user
/// has no way to know the app switched representations underneath.
@MainActor
struct CutPromotionAfterEditingTests {

    private func frozenSession() async throws -> (TraceSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CutFrozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Two Strokes")
        let image = TestCanvas.image(size: 400) { ctx in
            ctx.setLineWidth(6)
            ctx.move(to: CGPoint(x: 60, y: 120))
            ctx.addLine(to: CGPoint(x: 340, y: 120))
            ctx.move(to: CGPoint(x: 60, y: 280))
            ctx.addLine(to: CGPoint(x: 340, y: 280))
            ctx.strokePath()
        }
        try TestImageFile.writeJPEG(image, to: store.originalImageURL(for: project))
        let session = TraceSession(project: project, store: store)
        await session.load()
        try await session.settle()
        try #require(!session.visible.isEmpty)
        // What turning on the brush or the Points switch does.
        session.beginPointEditing()
        try #require(session.editedPaths != nil)
        return (session, root)
    }

    @Test func tappingALineAfterEditingStillTurnsItRed() async throws {
        let (session, root) = try await frozenSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try #require(session.editedPaths)
        let engrave = try #require(paths.first { !$0.isCut })
        let point = engrave.polyline.points[engrave.polyline.points.count / 2]
        let cutsBefore = paths.count { $0.isCut }

        session.toggleCut(at: point)

        let after = try #require(session.editedPaths)
        #expect(after.count { $0.isCut } == cutsBefore + 1,
                "tapping a line while frozen geometry is active did not make it a cut")
        #expect(after.count == paths.count, "the path itself must not be duplicated")
    }

    @Test func tappingAFrozenCutAgainReturnsItToEngrave() async throws {
        let (session, root) = try await frozenSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let engrave = try #require(session.editedPaths?.first { !$0.isCut })
        let point = engrave.polyline.points[engrave.polyline.points.count / 2]
        session.toggleCut(at: point)
        let promoted = try #require(session.editedPaths).count { $0.isCut }

        session.toggleCut(at: point)

        #expect(try #require(session.editedPaths).count { $0.isCut } == promoted - 1,
                "tapping a red line did not send it back to engrave")
    }
}
