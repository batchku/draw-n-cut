import CoreGraphics
import Foundation
import Testing
import simd
@testable import DrawNCut

/// Reported from the device: the subject selection is perfect, the red cut
/// outline traces the whole creature, and then the blue engrave lines are
/// "only a little box of lines inside" — every eye, nose, mane texture and
/// leg hatching missing. Moving Threshold to either end changes nothing.
///
/// The fixture is the shape that provokes it: a page-filling creature whose
/// body, mane and legs are all one connected run of thick marker, carrying
/// interior detail spread right across it.
@MainActor
struct EngraveCoverageTests {

    static let canvas = 800

    /// A child's sun/lion: round body, radiating mane, legs, face, and
    /// hatching over the whole interior. Everything touches everything, so it
    /// binarizes into one enormous connected component — which is exactly
    /// what the real drawing does.
    /// - Parameter onTable: draw the page as a lit rectangle on a darker
    ///   table, the way a handheld photo actually looks. A clean white canvas
    ///   never engages the paper-region heuristic, so it cannot reproduce
    ///   what a photograph does.
    static func creature(onTable: Bool = true) -> CGImage {
        TestCanvas.image(size: canvas) { ctx in
            let c = Double(canvas) / 2
            ctx.setLineCap(.round)
            if onTable {
                ctx.setFillColor(gray: 0.30, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 45, y: 45, width: canvas - 90, height: canvas - 90))
                ctx.setStrokeColor(gray: 0, alpha: 1)
                ctx.setFillColor(gray: 0, alpha: 1)
            }

            // Body.
            ctx.setLineWidth(9)
            ctx.strokeEllipse(in: CGRect(x: c - 210, y: c - 210, width: 420, height: 420))

            // Mane: spikes radiating off the body, so the outline is spiky.
            for i in 0..<18 {
                let a = Double(i) / 18 * 2 * .pi
                ctx.move(to: CGPoint(x: c + 205 * cos(a), y: c + 205 * sin(a)))
                ctx.addLine(to: CGPoint(x: c + 310 * cos(a), y: c + 310 * sin(a)))
            }
            ctx.strokePath()

            // Legs, with hatching across each one — detail far from centre.
            ctx.setLineWidth(7)
            for i in 0..<4 {
                let a = .pi * 0.25 + Double(i) / 4 * 2 * .pi
                let hip = CGPoint(x: c + 180 * cos(a), y: c + 180 * sin(a))
                let foot = CGPoint(x: c + 330 * cos(a), y: c + 330 * sin(a))
                ctx.move(to: hip)
                ctx.addLine(to: foot)
                for step in 1...4 {
                    let t = Double(step) / 5
                    let p = CGPoint(
                        x: hip.x + (foot.x - hip.x) * t, y: hip.y + (foot.y - hip.y) * t)
                    let n = CGPoint(x: -sin(a), y: cos(a))
                    ctx.move(to: CGPoint(x: p.x - 22 * n.x, y: p.y - 22 * n.y))
                    ctx.addLine(to: CGPoint(x: p.x + 22 * n.x, y: p.y + 22 * n.y))
                }
            }
            ctx.strokePath()

            // Face.
            ctx.setLineWidth(8)
            ctx.strokeEllipse(in: CGRect(x: c - 95, y: c + 40, width: 55, height: 55))
            ctx.strokeEllipse(in: CGRect(x: c + 40, y: c + 40, width: 55, height: 55))
            ctx.move(to: CGPoint(x: c, y: c + 30))
            ctx.addLine(to: CGPoint(x: c, y: c - 20))
            ctx.move(to: CGPoint(x: c - 60, y: c - 70))
            ctx.addLine(to: CGPoint(x: c, y: c - 100))
            ctx.addLine(to: CGPoint(x: c + 60, y: c - 70))
            ctx.strokePath()

            // Hatching over the body interior, well away from the centre.
            ctx.setLineWidth(6)
            for i in 0..<10 {
                let a = Double(i) / 10 * 2 * .pi
                let r0 = 120.0, r1 = 185.0
                ctx.move(to: CGPoint(x: c + r0 * cos(a), y: c + r0 * sin(a)))
                ctx.addLine(to: CGPoint(x: c + r1 * cos(a), y: c + r1 * sin(a)))
            }
            ctx.strokePath()
        }
    }

    /// The selection the user actually gets: a solid silhouette hugging the
    /// drawing's own outer strokes. This is the part that matters — a loose
    /// disc around the drawing behaves completely differently, because the
    /// cut outline then runs through blank paper instead of along the marker
    /// lines themselves.
    static func silhouette(of image: CGImage, width w: Int, height h: Int) -> BinaryBitmap {
        // Ink, generously closed and hole-filled: what SAM returns for a
        // drawing like this.
        guard let ink = BinaryBitmap(cgImage: image, maxDimension: max(w, h)) else {
            return BinaryBitmap(width: w, height: h)
        }
        var mask = ink.closed(radius: 12)
        // Fill the interior so the silhouette is solid, not a set of strokes.
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) {
            guard i >= 0, i < w * h, !outside[i], !mask.pixels[i] else { return }
            outside[i] = true
            stack.append(i)
        }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        for i in 0..<(w * h) where !outside[i] { mask.pixels[i] = true }
        return mask
    }

    static func loadedSession() async throws -> (TraceSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "Engrave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let project = try store.create(title: "Creature")
        let image = creature()
        try TestImageFile.writeJPEG(image, to: store.originalImageURL(for: project))

        let traceSpace = BinaryBitmap.traceSize(for: image)
        let mask = silhouette(
            of: image, width: Int(traceSpace.width), height: Int(traceSpace.height))
        try MaskPNG.write(
            SegmentationMask(width: mask.width, height: mask.height, pixels: mask.pixels),
            to: store.maskURL(for: project))

        let session = TraceSession(project: project, store: store)
        await session.load()
        try await session.settle()
        return (session, root)
    }

    /// How many cells of a 3x3 grid over the drawing contain engrave points.
    /// A creature covered in detail must light up nearly all of them; "a
    /// little box of lines inside" lights up one.
    static func occupiedCells(_ session: TraceSession) -> (occupied: Int, map: String) {
        let points = session.visible.flatMap(\.polyline.points)
        guard let size = session.result?.imageSize, !points.isEmpty else { return (0, "empty") }
        var grid = Array(repeating: false, count: 9)
        for point in points {
            let col = min(2, max(0, Int(point.x / size.width * 3)))
            let row = min(2, max(0, Int(point.y / size.height * 3)))
            grid[row * 3 + col] = true
        }
        let map = (0..<3).map { row in
            (0..<3).map { grid[row * 3 + $0] ? "#" : "." }.joined()
        }.joined(separator: "/")
        return (grid.count { $0 }, map)
    }

    @Test func engraveLinesCoverTheWholeMaskedDrawing() async throws {
        let (session, root) = try await Self.loadedSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let cut = session.cutOutlines.count
        let engrave = session.visible.count
        let cells = Self.occupiedCells(session)
        let report = "cut=\(cut) engrave=\(engrave) cells=\(cells.occupied) \(cells.map)"

        #expect(cut > 0, "the cut outline is missing too — \(report)")
        // Before the fix this was 20: the tracer found ~90 lines and the
        // outline de-duplication hid ~70 of them, interior detail included.
        #expect(engrave >= 50, "far too few engrave lines — \(report)")
        #expect(cells.occupied >= 8,
                "engrave detail is confined to part of the drawing — \(report)")
    }

    @Test func theThresholdSliderChangesTheEngraveLines() async throws {
        let (session, root) = try await Self.loadedSession()
        defer { try? FileManager.default.removeItem(at: root) }

        func snapshot(_ label: String) -> Int {
            let traced = session.result?.elements.reduce(0) { $0 + $1.polylines.count } ?? 0
            print("ENGRAVE \(label): traced=\(traced) visible=\(session.visible.count)"
                  + " hiddenAsOutline=\(session.outlineTargetCountForDiagnostics)"
                  + " cutLoops=\(session.cutOutlines.count)")
            return session.visible.count
        }

        session.threshold = 0.0
        try await session.settle()
        let low = snapshot("low")

        session.threshold = 0.5
        try await session.settle()
        let middle = snapshot("middle")

        session.threshold = 1.0
        try await session.settle()
        let high = snapshot("high")

        let report = "low=\(low) middle=\(middle) high=\(high)"
        #expect(low != high, "Threshold does nothing to the engrave lines — \(report)")
        #expect(high >= middle, "raising Threshold lost detail — \(report)")
    }
}
