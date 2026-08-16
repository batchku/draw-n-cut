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

    /// Builds a session over the fish-photo fixture and waits out its first
    /// trace.
    @MainActor
    static func fishSession(root: URL) async throws -> TraceSession {
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Fish")
        let fixtureURL = try #require(Bundle(for: MaskedTraceBundleToken.self)
            .url(forResource: "fish-photo", withExtension: "jpg"))
        try FileManager.default.copyItem(at: fixtureURL, to: store.originalImageURL(for: project))
        let session = TraceSession(project: project, store: store)
        await session.load()
        for _ in 0..<600 where session.result == nil || session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        return session
    }

    /// The tap-to-cut toggle under the frozen-promotion model: tapping a
    /// traced line freezes a red copy into `promotedCuts` and hides the
    /// source; tapping the frozen copy demotes it; the frozen geometry is
    /// bitwise-immune to the Engrave sliders; and a promoted line exports on
    /// the CUT layer (and carries into frozen point-editing as isCut).
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func tapTogglesEngraveLineToCutAndSurvivesRetrace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MaskedTraceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await Self.fishSession(root: root)
        let item = try #require(session.visible.first(where: { $0.polyline.points.count > 1 }))
        let mid = item.polyline.points[item.polyline.points.count / 2]

        // Role counts of the unpromoted export, for comparison below.
        let before = DXFExportBuilder.vectorPaths(
            from: session.visible.map(\.polyline),
            cutOutlines: session.cutOutlines + session.promotedCuts, widthMM: 100)

        session.toggleCut(at: mid)
        #expect(session.promotedCuts.count == 1)
        #expect(session.promotedCuts.first == item.polyline, "promotion freezes the tapped geometry")
        #expect(!session.visible.contains { $0.key == item.key },
                "the promoted source must hide from the engrave set")
        session.toggleCut(at: mid)
        #expect(session.promotedCuts.isEmpty, "second tap must demote back to engrave")
        #expect(session.visible.contains { $0.key == item.key },
                "demotion must bring the source line back")
        session.toggleCut(at: mid)
        #expect(session.promotedCuts.count == 1, "promote-demote-promote nets to one promotion")

        // Every promoted line lands on CUT exactly once, its source leaves
        // ENGRAVE.
        let after = DXFExportBuilder.vectorPaths(
            from: session.visible.map(\.polyline),
            cutOutlines: session.cutOutlines + session.promotedCuts, widthMM: 100)
        #expect(after.count(where: { $0.role == .cut })
                == before.count(where: { $0.role == .cut }) + 1)
        #expect(after.count(where: { $0.role == .engrave })
                == before.count(where: { $0.role == .engrave }) - 1)

        // The RED world is frozen: Engrave sliders re-trace the blues but may
        // not reshape, add, or drop any red polyline.
        let recordedPromotions = session.promotedCuts
        let recordedOutlines = session.cutOutlines
        session.smoothness = 0.9
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.promotedCuts == recordedPromotions, "smoothness must not touch promotions")
        #expect(session.cutOutlines == recordedOutlines, "smoothness must not touch the outline")
        session.detail = 0.4
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.promotedCuts == recordedPromotions, "detail must not touch promotions")
        #expect(session.cutOutlines == recordedOutlines, "detail must not touch the outline")

        // No mask → no cut outline, so any CUT-layer entity is the promoted
        // line ("8" is DXF's layer group code on each entity; the writer
        // emits CRLF line endings).
        let url = try session.exportDXF(widthMM: 100)
        let dxf = try String(contentsOf: url, encoding: .utf8)
        #expect(dxf.contains("8\r\nCUT"), "promoted line missing from the CUT layer")

        // Freezing for point editing carries the promotion as a cut path.
        session.beginPointEditing()
        let frozen = try #require(session.editedPaths)
        #expect(frozen.contains { $0.isCut && $0.polyline == recordedPromotions[0] },
                "the frozen set must carry the promotion as isCut geometry")
    }

    /// The Cut sliders own the red outline ONLY: sweeping them must never
    /// change which blue lines are visible, their geometry, or which traced
    /// lines the outline hides — while the outline itself does change.
    @MainActor
    @Test(.timeLimit(.minutes(3)))
    func cutSlidersNeverTouchBlueLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MaskedTraceTests-\(UUID().uuidString)")
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

        let recordedKeys = session.visible.map(\.key)
        let recordedGeometry = session.visible.map(\.polyline)
        let recordedHidden = session.outlineTargets
        var outlinesPerStep: [[Polyline]] = [session.cutOutlines]

        func sweep(_ apply: @MainActor () -> Void) async throws {
            let previous = session.cutOutlines
            apply()
            // The refresh debounces ~150ms; poll until the outline actually
            // changed or the budget passes (a step may leave it unchanged).
            for _ in 0..<30 where session.cutOutlines == previous {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(session.visible.map(\.key) == recordedKeys,
                    "a Cut slider changed which blue lines are visible")
            #expect(session.visible.map(\.polyline) == recordedGeometry,
                    "a Cut slider reshaped a blue line")
            #expect(session.outlineTargets == recordedHidden,
                    "a Cut slider changed the coincident-line hiding")
            outlinesPerStep.append(session.cutOutlines)
        }

        try await sweep { session.outlineDetail = 0.1 }
        try await sweep { session.outlineDetail = 1.0 }
        try await sweep { session.outlineSmoothness = 0.0 }
        try await sweep { session.outlineSmoothness = 1.0 }

        // The red outline itself did respond to its sliders.
        #expect(outlinesPerStep[1] != outlinesPerStep[2],
                "outlineDetail 0.1 vs 1.0 must reshape the cut outline")
    }

    /// Promotions persist as frozen geometry: save → mutate → restore
    /// reproduces the exact red polylines, without tap replay.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func promotionsSurviveSaveAndRestoreAsFrozenGeometry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MaskedTraceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await Self.fishSession(root: root)
        let item = try #require(session.visible.first(where: { $0.polyline.points.count > 1 }))
        let mid = item.polyline.points[item.polyline.points.count / 2]

        session.toggleCut(at: mid)
        let recorded = session.promotedCuts
        try #require(recorded.count == 1)
        try session.saveVersion()

        // Demote and wander the engrave slider — the restore must bring the
        // exact frozen geometry back regardless.
        session.toggleCut(at: mid)
        #expect(session.promotedCuts.isEmpty)
        session.smoothness = 0.9
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }

        let version = try #require(session.project.traceVersions.last)
        session.restore(version)
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.promotedCuts == recorded, "restore must reproduce the frozen promotion exactly")
    }

    /// Legacy saved versions carried cut TAPS, not geometry: restoring one
    /// converts each surviving tap into a frozen promotion against the
    /// restored trace, once.
    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func legacyCutTapSnapshotConvertsToFrozenPromotionOnRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MaskedTraceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await Self.fishSession(root: root)
        let item = try #require(session.visible.first(where: { $0.polyline.points.count > 1 }))
        let mid = item.polyline.points[item.polyline.points.count / 2]

        // Hand-crafted legacy snapshot: detail + a cut tap at a known line's
        // midpoint (eraseTaps was non-optional in the legacy schema too).
        let legacyJSON = """
        {"detail": \(session.detail), "eraseTaps": [], "cutTaps": [[\(mid.x), \(mid.y)]]}
        """
        let store = ProjectStore(rootURL: root)
        let version = try store.addTraceVersion(
            to: session.project, detail: session.detail,
            pathsData: Data(legacyJSON.utf8))

        #expect(session.promotedCuts.isEmpty)
        session.restore(version)
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.promotedCuts.count == 1,
                "a legacy cut tap must materialize as one frozen promotion")
        #expect(session.promotedCuts.first == item.polyline)

        // One-time conversion, not replay: another re-trace keeps the
        // promotion frozen, untouched.
        let recorded = session.promotedCuts
        session.smoothness = 0.9
        for _ in 0..<600 where session.isTracing {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.promotedCuts == recorded)
    }
}
