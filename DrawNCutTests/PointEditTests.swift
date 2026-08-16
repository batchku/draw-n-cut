import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

private final class PointEditBundleToken {}

/// The point-edit surface: freezing the trace into editable paths, dragging
/// control points, magnetic endpoint snapping, and the joins that closing a
/// cut shape depends on.
struct PointEditTests {
    private func open(_ points: [SIMD2<Double>], isCut: Bool = false) -> EditablePath {
        EditablePath(polyline: Polyline(points: points, isClosed: false), isCut: isCut)
    }

    // MARK: - Pure join/snap logic

    @Test func snapReachesEveryPointExceptOwnNeighbors() {
        let paths = [
            open([SIMD2(0, 0), SIMD2(100, 0)]),
            open([SIMD2(110, 2), SIMD2(200, 0), SIMD2(300, 5)]),
        ]
        let dragged = TraceSession.PointRef(path: 0, point: 1)
        // Nearest foreign endpoint within radius.
        #expect(TraceSession.snapTarget(in: paths, for: dragged, near: SIMD2(104, 0), radius: 12)
                == TraceSession.PointRef(path: 1, point: 0))
        // Foreign INTERIOR points are magnetic too.
        #expect(TraceSession.snapTarget(in: paths, for: dragged, near: SIMD2(199, 1), radius: 12)
                == TraceSession.PointRef(path: 1, point: 1))
        // Out of radius: nothing.
        #expect(TraceSession.snapTarget(in: paths, for: dragged, near: SIMD2(150, 40), radius: 12) == nil)
        // A dragged interior point snaps to other paths' points…
        let interior = TraceSession.PointRef(path: 1, point: 1)
        #expect(TraceSession.snapTarget(in: paths, for: interior, near: SIMD2(2, 1), radius: 12)
                == TraceSession.PointRef(path: 0, point: 0))
        // …but never to its own immediate neighbors.
        #expect(TraceSession.snapTarget(in: paths, for: interior, near: SIMD2(298, 5), radius: 12) == nil)
    }

    @Test func snapOntoAnInteriorPointNeverJoins() {
        let a = open([SIMD2(0, 0), SIMD2(100, 0)])
        let b = open([SIMD2(100, 10), SIMD2(200, 10), SIMD2(300, 10)])
        let joined = TraceSession.joining(
            [a, b],
            dragged: TraceSession.PointRef(path: 0, point: 1),
            target: TraceSession.PointRef(path: 1, point: 1)   // mid-line
        )
        #expect(joined.count == 2, "landing on a mid-line point must not merge paths")
        #expect(joined[0].polyline.points == a.polyline.points)
        #expect(joined[1].polyline.points == b.polyline.points)
    }

    @Test func snapToOwnOtherEndClosesTheShape() {
        let square = open([SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 100), SIMD2(0, 100), SIMD2(2, 3)])
        let dragged = TraceSession.PointRef(path: 0, point: 4)
        let target = TraceSession.snapTarget(in: [square], for: dragged, near: SIMD2(1, 2), radius: 12)
        #expect(target == TraceSession.PointRef(path: 0, point: 0))

        let joined = TraceSession.joining([square], dragged: dragged, target: target!)
        #expect(joined.count == 1)
        #expect(joined[0].polyline.isClosed, "snapping an end onto its own start must close the path")
        // The dragged duplicate is dropped; the closure supplies the segment.
        #expect(joined[0].polyline.points.count == 4)
    }

    @Test func joiningTwoPathsMergesThemEndToEnd() {
        let a = open([SIMD2(0, 0), SIMD2(100, 0)], isCut: false)
        let b = open([SIMD2(100, 0), SIMD2(100, 100), SIMD2(0, 100)], isCut: true)
        // Drag a's END onto b's START.
        let merged = TraceSession.joining(
            [a, b],
            dragged: TraceSession.PointRef(path: 0, point: 1),
            target: TraceSession.PointRef(path: 1, point: 0)
        )
        #expect(merged.count == 1)
        #expect(merged[0].polyline.points.count == 4, "shared endpoint must not duplicate")
        #expect(merged[0].polyline.points.first == SIMD2(0, 0))
        #expect(merged[0].polyline.points.last == SIMD2(0, 100))
        #expect(merged[0].isCut, "cut wins over engrave when merging")
        #expect(!merged[0].polyline.isClosed)
    }

    @Test func joiningReversesOrientationsAsNeeded() {
        // Drag a's START onto b's END: both need reorienting.
        let a = open([SIMD2(100, 0), SIMD2(0, 0)])
        let b = open([SIMD2(0, 100), SIMD2(100, 100), SIMD2(100, 1)])
        let merged = TraceSession.joining(
            [a, b],
            dragged: TraceSession.PointRef(path: 0, point: 0),
            target: TraceSession.PointRef(path: 1, point: 2)
        )
        #expect(merged.count == 1)
        let points = merged[0].polyline.points
        #expect(points.count == 4)
        #expect(points.first == SIMD2(0, 0), "a reversed so its dragged end leads into the join")
        #expect(points.last == SIMD2(0, 100), "b reversed so its snapped end receives the join")
    }

    // MARK: - Smoothing marker

    @Test func brushStraightensOnlyWhatItTouches() {
        // A zigzag along y=0: ±6 jags every 5px from x=0 to x=100.
        var zigzag: [SIMD2<Double>] = []
        for i in 0...20 {
            var y: Double = 0
            if i % 2 != 0 { y = i % 4 == 1 ? 6 : -6 }
            zigzag.append(SIMD2(Double(i) * 5, y))
        }
        let paths = [open(zigzag)]
        // Sweep the marker along the middle (x 35...65) at radius 12.
        let stroke = [SIMD2(35.0, 0.0), SIMD2(65.0, 0.0)]
        let brushed = TraceSession.brushSmoothed(paths, stroke: stroke, radius: 12)

        #expect(brushed.count == 1)
        let points = brushed[0].polyline.points
        #expect(points.first == zigzag.first, "path endpoints must not move")
        #expect(points.last == zigzag.last)
        // Untouched head keeps its jags exactly.
        #expect(points[1] == zigzag[1])
        // The brushed middle flattened: nothing in x 40...60 keeps a full jag.
        let middle = points.filter { $0.x > 40 && $0.x < 60 }
        #expect(!middle.isEmpty)
        #expect(middle.allSatisfy { abs($0.y) < 6 }, "brushed jags must shrink, got \(middle)")
    }

    @Test func brushKeepsClosedLoopsClosedAndSparesFarCorners() {
        // A square with a jagged top edge.
        var points: [SIMD2<Double>] = []
        for i in 0...10 { points.append(SIMD2(Double(i) * 10, i % 2 == 0 ? 0.0 : 5.0)) }
        points += [SIMD2(100, 100), SIMD2(0, 100)]
        let loop = EditablePath(polyline: Polyline(points: points, isClosed: true), isCut: true)

        let brushed = TraceSession.brushSmoothed(
            [loop], stroke: [SIMD2(10.0, 2.0), SIMD2(90.0, 2.0)], radius: 10)
        let result = brushed[0].polyline
        #expect(result.isClosed, "brushing must never open a closed loop")
        #expect(brushed[0].isCut)
        #expect(result.points.contains(SIMD2(100, 100)), "far corners stay put")
        #expect(result.points.contains(SIMD2(0, 100)))
        let topJags = result.points.filter { $0.y > 0 && $0.y < 100 && $0.x > 15 && $0.x < 85 }
        #expect(topJags.allSatisfy { $0.y < 5 }, "top jags must shrink, got \(topJags)")
    }

    @Test func brushIgnoresPathsOutOfReach() {
        let far = open([SIMD2(0, 500), SIMD2(100, 500)])
        let brushed = TraceSession.brushSmoothed(
            [far], stroke: [SIMD2(0.0, 0.0), SIMD2(100.0, 0.0)], radius: 12)
        #expect(brushed[0].polyline.points == far.polyline.points)
    }

    // MARK: - Snap tween

    @Test func snapTweenEasesOutMonotonically() {
        #expect(SnapTween.progress(0) == 0)
        #expect(SnapTween.progress(1) == 1)
        #expect(SnapTween.progress(1.5) == 1, "overshoot clamps at the magnet")
        #expect(SnapTween.progress(-0.5) == 0)
        // Strictly increasing, and front-loaded (ease-out): more than half
        // the distance is covered in the first half of the time.
        var last = 0.0
        for step in 1...20 {
            let value = SnapTween.progress(Double(step) / 20)
            #expect(value >= last)
            last = value
        }
        #expect(SnapTween.progress(0.5) > 0.5)
        // The whole glide is meant to be felt: a couple hundred ms.
        #expect(SnapTween.duration >= 0.15 && SnapTween.duration <= 0.4)
    }

    // MARK: - Drag loupe placement

    @Test func loupeSitsTopRightOfTheFinger() {
        let viewport = CGSize(width: 400, height: 800)
        let center = LoupeGeometry.center(finger: CGPoint(x: 200, y: 400), viewport: viewport)
        #expect(center.x > 200 && center.y < 400, "default placement is above-right")
        #expect(center.x + LoupeGeometry.radius <= 400)
        #expect(center.y - LoupeGeometry.radius >= 0)
    }

    @Test func loupeFlipsAwayFromEdges() {
        let viewport = CGSize(width: 400, height: 800)
        // Near the right edge → flips to the finger's left.
        let nearRight = LoupeGeometry.center(finger: CGPoint(x: 390, y: 400), viewport: viewport)
        #expect(nearRight.x < 390)
        #expect(nearRight.x + LoupeGeometry.radius <= 400)
        // Near the top → sits below the finger.
        let nearTop = LoupeGeometry.center(finger: CGPoint(x: 200, y: 40), viewport: viewport)
        #expect(nearTop.y > 40)
        // Top-right corner → both flips at once.
        let corner = LoupeGeometry.center(finger: CGPoint(x: 390, y: 30), viewport: viewport)
        #expect(corner.x < 390 && corner.y > 30)
    }

    @Test func loupeStaysOnScreenEverywhere() {
        let viewport = CGSize(width: 400, height: 800)
        for x in stride(from: 0.0, through: 400, by: 50) {
            for y in stride(from: 0.0, through: 800, by: 100) {
                let center = LoupeGeometry.center(finger: CGPoint(x: x, y: y), viewport: viewport)
                #expect(center.x - LoupeGeometry.radius >= -0.001)
                #expect(center.x + LoupeGeometry.radius <= 400.001)
                #expect(center.y - LoupeGeometry.radius >= -0.001)
                #expect(center.y + LoupeGeometry.radius <= 800.001)
            }
        }
    }

    /// Freezing for editing must absorb the mask-derived cut outline so its
    /// points drag and its jagged spans brush like any other path.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func freezingAbsorbsTheCutOutline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PointEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Fish")
        try FileManager.default.copyItem(
            at: try FixtureTraceTests.fixtureURL("fish-circle-shadow-photo", extension: "jpg"),
            to: store.originalImageURL(for: project))
        try FileManager.default.copyItem(
            at: try FixtureTraceTests.fixtureURL("fish-circle-shadow-mask", extension: "png"),
            to: store.maskURL(for: project))

        let session = TraceSession(project: project, store: store)
        await session.load()
        for _ in 0..<600 where session.result == nil || session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(!session.cutOutlines.isEmpty, "the mask must yield a cut outline")

        session.beginPointEditing()
        let paths = try #require(session.editedPaths)
        let frozenCuts = paths.filter { $0.isCut && $0.polyline.isClosed }
        #expect(!frozenCuts.isEmpty, "the cut outline must join the editable set")

        // And it exports from the frozen set (still on the CUT layer).
        let url = try session.exportDXF(widthMM: 100)
        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.contains("8\r\nCUT"))
    }

    // MARK: - Session integration

    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func editsFreezeExportPersistAndResetOnRetrace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PointEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Fish")
        let fixtureURL = try #require(Bundle(for: PointEditBundleToken.self)
            .url(forResource: "fish-photo", withExtension: "jpg"))
        try FileManager.default.copyItem(at: fixtureURL, to: store.originalImageURL(for: project))

        let session = TraceSession(project: project, store: store)
        await session.load()
        for _ in 0..<600 where session.result == nil || session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }

        session.beginPointEditing()
        let paths = try #require(session.editedPaths)
        try #require(!paths.isEmpty)

        // Drag a point and grab-test it.
        let ref = TraceSession.PointRef(path: 0, point: 0)
        let start = try #require(session.position(of: ref))
        let moved = start + SIMD2(25, 25)
        session.movePoint(ref, to: moved)
        #expect(session.position(of: ref) == moved)
        #expect(session.editablePoint(near: moved + SIMD2(3, 0), radius: 10) == ref)

        // The edited geometry is what exports.
        let url = try session.exportDXF(widthMM: 100)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Edits survive a save/restore round trip.
        try session.saveVersion()
        let version = try #require(session.project.traceVersions.last)
        session.restore(version)
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        let restored = try #require(session.editedPaths)
        #expect(restored[0].polyline.points[0] == moved, "restored edits must keep moved points")

        // A slider change re-traces and supersedes point surgery.
        session.smoothness = min(1, session.smoothness + 0.3)
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.editedPaths == nil, "a re-trace must reset point edits")
    }
}
