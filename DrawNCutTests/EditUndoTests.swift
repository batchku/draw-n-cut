import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// The frozen-geometry undo stack: one gesture (a marker stroke from
/// finger-down to finger-up, one point drag, one join) is one undo entry;
/// a gesture that changes nothing records nothing; a re-trace clears the
/// stack so undo can never resurrect stale geometry.
struct EditUndoTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "EditUndoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One full marker stroke (gesture-bounded) swept along the densest
    /// frozen path — dense traced lines always simplify, so it must mutate.
    @MainActor
    private func performMutatingBrushStroke(on session: TraceSession) throws {
        let paths = try #require(session.editedPaths)
        let dense = try #require(paths.max(by: { $0.polyline.points.count < $1.polyline.points.count }))
        try #require(dense.polyline.points.count >= 6, "need a dense path to brush")
        let points = dense.polyline.points
        let quarter = points.count / 4
        session.beginEditGesture()
        session.brushSmooth(from: nil, to: points[quarter], radius: 20)
        session.brushSmooth(from: points[quarter], to: points[2 * quarter], radius: 20)
        session.brushSmooth(from: points[2 * quarter], to: points[3 * quarter], radius: 20)
        session.endEditGesture()
    }

    // REQ-2: one smoothing-marker stroke = exactly one undo entry.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func brushStrokeCoalescesIntoOneUndoEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await MaskedTraceTests.fishSession(root: root)

        session.beginPointEditing()
        let before = try #require(session.editedPaths)

        try performMutatingBrushStroke(on: session)
        #expect(session.editedPaths != before, "the stroke must have smoothed something")
        #expect(session.editUndoStack.count == 1, "per-sample brushSmooth calls must coalesce")

        session.undo()
        #expect(session.editedPaths == before, "one undo restores the exact pre-stroke geometry")
        #expect(session.editUndoStack.isEmpty)
    }

    // REQ-2: a stroke that touches no path records no undo entry, so a later
    // undo cannot pop the first stroke twice.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func emptyStrokeRecordsNoUndoEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await MaskedTraceTests.fishSession(root: root)

        session.beginPointEditing()
        let before = try #require(session.editedPaths)

        try performMutatingBrushStroke(on: session)
        #expect(session.editUndoStack.count == 1)

        // A stroke swept far away from every path: no mutation, no entry.
        let far = SIMD2(-500.0, -500.0)
        session.beginEditGesture()
        session.brushSmooth(from: nil, to: far, radius: 20)
        session.brushSmooth(from: far, to: far + SIMD2(50, 0), radius: 20)
        session.brushSmooth(from: far + SIMD2(50, 0), to: far + SIMD2(100, 0), radius: 20)
        session.endEditGesture()
        #expect(session.editUndoStack.count == 1,
                "undo count must match MUTATING-stroke count")

        session.undo()
        #expect(session.editedPaths == before)
        #expect(session.editUndoStack.isEmpty)
        // Nothing left to pop: with no erasures either, this is a safe no-op.
        session.undo()
        #expect(session.editedPaths == before, "an extra undo must not pop the first stroke twice")
    }

    // REQ-3: one point drag = one entry; a join is part of its gesture and
    // undoes whole; an empty-stack undo is a safe no-op.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func pointDragAndJoinAreOneUndoEntryEach() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await MaskedTraceTests.fishSession(root: root)

        session.beginPointEditing()
        let original = try #require(session.editedPaths)

        // Gesture 1: drag path-0 point-0 by (25,25) through three samples.
        let ref = TraceSession.PointRef(path: 0, point: 0)
        let start = try #require(session.position(of: ref))
        session.beginEditGesture()
        session.movePoint(ref, to: start + SIMD2(8, 8))
        session.movePoint(ref, to: start + SIMD2(16, 16))
        session.movePoint(ref, to: start + SIMD2(25, 25))
        session.endPointDrag(ref, snappedTo: nil)
        session.endEditGesture()
        #expect(session.editUndoStack.count == 1, "three move samples are ONE gesture")
        let afterDrag = try #require(session.editedPaths)
        #expect(afterDrag != original)

        // Gesture 2: drag one open path's endpoint onto another's — a join.
        let openIndices = afterDrag.indices.filter {
            !afterDrag[$0].polyline.isClosed && afterDrag[$0].polyline.points.count >= 2
        }
        try #require(openIndices.count >= 2, "the fixture must trace at least two open paths")
        let dragged = TraceSession.PointRef(
            path: openIndices[0], point: afterDrag[openIndices[0]].polyline.points.count - 1)
        let target = TraceSession.PointRef(path: openIndices[1], point: 0)
        let magnet = try #require(session.position(of: target))
        session.beginEditGesture()
        session.movePoint(dragged, to: magnet)
        session.endPointDrag(dragged, snappedTo: target)
        session.endEditGesture()
        let afterJoin = try #require(session.editedPaths)
        #expect(afterJoin.count == afterDrag.count - 1, "the join must merge two paths")
        #expect(session.editUndoStack.count == 2)

        // Undo the join: both pre-join paths return — counts, closure flags,
        // roles, geometry — exactly the post-gesture-1 state.
        session.undo()
        #expect(session.editedPaths == afterDrag, "undoing a join restores both pre-join paths")
        #expect(session.editedPaths?.count == afterDrag.count)

        // Undo the drag: back to the original frozen geometry.
        session.undo()
        #expect(session.editedPaths == original)

        // Empty stack (and no erasures): safe no-op.
        session.undo()
        #expect(session.editedPaths == original)
    }

    // REQ-3: a drag that grabs no point records nothing.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func dragThatGrabsNothingRecordsNoEntry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await MaskedTraceTests.fishSession(root: root)

        session.beginPointEditing()
        session.beginEditGesture()
        // The view only calls movePoint when editablePoint returned a grab;
        // far from everything, it returns nil and the gesture stays empty.
        #expect(session.editablePoint(near: SIMD2(-500, -500), radius: 10) == nil)
        session.endEditGesture()
        #expect(session.editUndoStack.isEmpty)
    }

    // REQ-4: the unified undo the button invokes reaches edit gestures even
    // with zero erasures, and reports availability for the button state.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func unifiedUndoWorksWithZeroErasures() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await MaskedTraceTests.fishSession(root: root)
        try #require(session.eraseShapes.isEmpty)
        #expect(!session.canUndo, "nothing to undo yet — the button starts disabled")

        session.beginPointEditing()
        let before = try #require(session.editedPaths)
        try performMutatingBrushStroke(on: session)
        #expect(session.canUndo, "an edit gesture alone must enable the undo button")

        session.undo()   // the same entry point the button and two-finger tap call
        #expect(session.editedPaths == before)
        #expect(!session.canUndo)
    }

    // REQ-5: a re-trace scopes out the stack — undo can never resurrect
    // stale pre-retrace geometry.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func retraceClearsTheEditUndoStack() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await MaskedTraceTests.fishSession(root: root)

        session.beginPointEditing()
        try performMutatingBrushStroke(on: session)
        #expect(session.editUndoStack.count == 1)

        session.smoothness = min(1, session.smoothness + 0.3)
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.editedPaths == nil, "a re-trace resets frozen geometry")
        #expect(session.editUndoStack.isEmpty, "…and the undo stack with it")

        session.undo()
        #expect(session.editedPaths == nil, "undo after a re-trace must not restore frozen geometry")
    }
}
