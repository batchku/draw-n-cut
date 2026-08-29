import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// End-to-end behaviour of the editing tools through a real session, rather
/// than only their geometry in isolation. The tap-to-cut regression lived
/// exactly in this gap: every pure function was right and the feature was
/// still broken.
@MainActor
struct EditingIntegrationTests {

    /// Two jagged strokes. Deliberately not straight lines: a straight line
    /// traces to two points, so there is nothing for the brush to smooth or
    /// the pen to simplify, and a test over one passes or fails for reasons
    /// that have nothing to do with the tool.
    static func zigzagStrokes(_ ctx: CGContext) {
        ctx.setLineWidth(6)
        for (index, baseline) in [120.0, 280.0].enumerated() {
            ctx.move(to: CGPoint(x: 60, y: baseline))
            for step in 1...28 {
                let x = 60.0 + Double(step) * 10
                let wobble = step.isMultiple(of: 2) ? 7.0 : -7.0
                ctx.addLine(to: CGPoint(x: x, y: baseline + wobble))
            }
            _ = index
        }
        ctx.strokePath()
    }

    private func session(
        strokes: (CGContext) -> Void = EditingIntegrationTests.zigzagStrokes
    ) async throws -> (TraceSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Strokes")
        try TestImageFile.writeJPEG(TestCanvas.image(size: 400, draw: strokes),
                                    to: store.originalImageURL(for: project))
        let session = TraceSession(project: project, store: store)
        await session.load()
        try await session.settle()
        try #require(!session.visible.isEmpty)
        return (session, root)
    }

    /// A point in the middle of the path with the most points — the one the
    /// brush and pen can actually act on.
    static func midpointOfLongest(_ paths: [EditablePath]) throws -> SIMD2<Double> {
        let longest = try #require(paths.max { $0.polyline.points.count < $1.polyline.points.count })
        try #require(longest.polyline.points.count >= 8,
                     "fixture gave the tools nothing to work on")
        return longest.polyline.points[longest.polyline.points.count / 2]
    }

    // MARK: - Gesture cancellation

    /// A two-finger zoom necessarily begins as one finger, so the brush gets
    /// a few milliseconds of stroke before the second finger lands. Cancelling
    /// has to put the geometry back exactly, or zooming would smear the
    /// drawing a little every time.
    @Test func cancellingAGestureRestoresTheGeometry() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let before = try #require(session.editedPaths)
        let point = try Self.midpointOfLongest(before)

        session.beginEditGesture()
        session.brushSmooth(from: nil, to: point, radius: 40)
        session.brushSmooth(from: point, to: point + SIMD2(10, 0), radius: 40)
        session.cancelEditGesture()

        #expect(session.editedPaths == before, "cancelling left the drawing changed")
    }

    @Test func cancellingAGestureThatChangedNothingIsHarmless() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let before = try #require(session.editedPaths)
        session.beginEditGesture()
        session.cancelEditGesture()

        #expect(session.editedPaths == before)
        #expect(!session.canUndo, "an abandoned gesture must not leave an undo entry")
    }

    @Test func cancellingDoesNotEatAPreviousStrokesUndo() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let original = try #require(session.editedPaths)
        let point = try Self.midpointOfLongest(original)

        // A real stroke, committed.
        session.beginEditGesture()
        session.brushSmooth(from: nil, to: point, radius: 40)
        session.brushSmooth(from: point, to: point + SIMD2(12, 0), radius: 40)
        session.endEditGesture()
        let afterRealStroke = try #require(session.editedPaths)
        try #require(session.canUndo)

        // Then an aborted one.
        session.beginEditGesture()
        session.brushSmooth(from: nil, to: point, radius: 40)
        session.cancelEditGesture()

        #expect(session.editedPaths == afterRealStroke,
                "the cancel reached back past its own gesture")
        #expect(session.canUndo, "the earlier stroke's undo entry was consumed")
    }

    // MARK: - Pen

    @Test func thePenReplacesTheStretchItIsDrawnOver() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let before = try #require(session.editedPaths)
        let target = try #require(before.max { $0.polyline.points.count < $1.polyline.points.count })
            .polyline
        try #require(target.points.count >= 8, "fixture gave the pen nothing to simplify")
        // A straight stroke along the middle of that wandering line.
        let a = target.points[target.points.count / 4]
        let b = target.points[3 * target.points.count / 4]
        let stroke = (0...20).map { i -> SIMD2<Double> in
            let t = Double(i) / 20
            return a + (b - a) * t
        }

        session.penReshape(points: stroke, radius: 25)

        let after = try #require(session.editedPaths)
        #expect(after.count == before.count, "the pen must not add or drop whole paths")
        #expect(after != before, "the pen stroke did nothing")
        #expect(session.canUndo, "a pen stroke must be undoable")
    }

    @Test func aPenStrokeOverEmptySpaceDoesNothing() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let before = try #require(session.editedPaths)
        // Well clear of both strokes.
        let stroke = (0...10).map { SIMD2(Double($0) * 5, 5.0) }
        session.penReshape(points: stroke, radius: 10)

        #expect(session.editedPaths == before)
        #expect(!session.canUndo)
    }

    @Test func aPenStrokeIsUndoable() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let before = try #require(session.editedPaths)
        let target = try #require(before.max { $0.polyline.points.count < $1.polyline.points.count })
            .polyline
        try #require(target.points.count >= 8)
        let a = target.points[target.points.count / 4]
        let b = target.points[3 * target.points.count / 4]
        let stroke = (0...20).map { a + (b - a) * (Double($0) / 20) }
        session.penReshape(points: stroke, radius: 25)
        try #require(session.editedPaths != before)

        session.undo()

        #expect(session.editedPaths == before, "undo did not restore the pre-pen line")
    }

    // MARK: - Threshold

    /// The Threshold slider has to reach the trace, not just the parameters:
    /// it is the one control that re-runs binarization.
    @Test func movingThresholdChangesWhatIsTraced() async throws {
        // A drawing with one bold stroke and one faint one.
        let (session, root) = try await session(strokes: { ctx in
            ctx.setLineWidth(6)
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.move(to: CGPoint(x: 60, y: 120))
            ctx.addLine(to: CGPoint(x: 340, y: 120))
            ctx.strokePath()
            ctx.setStrokeColor(gray: 0.93, alpha: 1)
            ctx.move(to: CGPoint(x: 60, y: 280))
            ctx.addLine(to: CGPoint(x: 340, y: 280))
            ctx.strokePath()
        })
        defer { try? FileManager.default.removeItem(at: root) }

        let atDefault = session.visible.count
        session.threshold = 1.0
        try await session.settle()
        let atTop = session.visible.count

        #expect(atTop > atDefault,
                "raising Threshold found nothing new (\(atDefault) → \(atTop))")
    }

    @Test func thresholdIsSavedAndRestoredWithAVersion() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.threshold = 0.85
        try await session.settle()
        try session.saveVersion()
        let version = try #require(session.project.traceVersions.last)

        session.threshold = 0.2
        try await session.settle()
        try #require(session.threshold == 0.2)

        session.restore(version)
        try await session.settle()
        #expect(abs(session.threshold - 0.85) < 0.0001,
                "the saved Threshold did not come back")
    }
}
