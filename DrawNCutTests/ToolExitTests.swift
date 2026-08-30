import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Getting back out of a tool. Reported from the device: after using the pen,
/// "I actually couldn't get back to the drawing anymore because all of the
/// sliders became deactivated... I don't know how to get out."
@MainActor
struct ToolExitTests {

    private func session() async throws -> (TraceSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ToolExit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Strokes")
        try TestImageFile.writeJPEG(
            TestCanvas.image(size: 400, draw: EditingIntegrationTests.zigzagStrokes),
            to: store.originalImageURL(for: project))
        let session = TraceSession(project: project, store: store)
        await session.load()
        try await session.settle()
        try #require(!session.visible.isEmpty)
        return (session, root)
    }

    /// Poking a tool and backing out must leave no trace. Otherwise the
    /// frozen copy lingers and the next slider move silently discards it —
    /// destructive for a tool the user never actually used.
    @Test func pokingAToolAndLeavingRestoresTheSliders() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        #expect(session.editedPaths != nil, "the tool did not freeze the trace")

        session.endPointEditingIfUntouched()

        #expect(session.editedPaths == nil,
                "an unused tool left frozen geometry behind")
    }

    /// Real work must survive leaving the tool — the escape hatch is not an
    /// undo.
    @Test func leavingAToolKeepsWorkThatWasActuallyDone() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        let point = try EditingIntegrationTests.midpointOfLongest(
            try #require(session.editedPaths))
        session.beginEditGesture()
        session.brushSmooth(from: nil, to: point, radius: 40)
        session.brushSmooth(from: point, to: point + SIMD2(12, 0), radius: 40)
        session.endEditGesture()
        let edited = try #require(session.editedPaths)

        session.endPointEditingIfUntouched()

        #expect(session.editedPaths == edited, "leaving the tool threw the edits away")
    }

    /// Mid-gesture is not "untouched": a stroke in flight must not be
    /// discarded by an exit arriving before the finger lifts.
    @Test func aGestureInFlightIsNotTreatedAsUntouched() async throws {
        let (session, root) = try await session()
        defer { try? FileManager.default.removeItem(at: root) }

        session.beginPointEditing()
        session.beginEditGesture()
        session.endPointEditingIfUntouched()

        #expect(session.editedPaths != nil, "an in-flight gesture was thrown away")
    }
}
