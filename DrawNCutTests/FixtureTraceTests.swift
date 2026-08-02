import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DrawNCut

/// Runs the real scanned kid drawings (Fixtures/) through the trace engine.
/// Also writes SVG renderings of the traces to /tmp/drawncut-traces for
/// visual inspection.
struct FixtureTraceTests {
    static func fixtureImage(_ name: String) throws -> CGImage {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "png"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test(arguments: ["animals-page-1", "animals-page-2"])
    func pagesTraceIntoPlausibleElements(page: String) throws {
        let image = try Self.fixtureImage(page)
        let result = try #require(TraceEngine.trace(image: image, detail: 0.7))

        // Each page holds 6 drawings + 6 enclosing circles + 6 labels; even
        // with connected components merging, well over a dozen elements.
        #expect(result.elements.count >= 12, "got \(result.elements.count) elements")

        // Sanity: some closed loops (the circles) and plenty of open strokes.
        let closedLoops = result.elements.flatMap(\.polylines).filter(\.isClosed)
        #expect(closedLoops.count >= 3, "got \(closedLoops.count) closed loops")

        // Nothing traced should exceed the page bounds.
        for element in result.elements {
            #expect(CGRect(origin: .zero, size: result.imageSize).contains(element.boundingBox))
        }

        try SVGDump.write(result: result, name: "\(page)-detail-0.7")
    }

    @Test func detailSliderSweepIsMonotonicOnRealScan() throws {
        let image = try Self.fixtureImage("animals-page-1")
        var counts: [Int] = []
        for detail in [0.0, 0.5, 1.0] {
            let result = try #require(TraceEngine.trace(image: image, detail: detail))
            counts.append(result.elements.flatMap(\.polylines).count)
            try SVGDump.write(result: result, name: "animals-page-1-detail-\(detail)")
        }
        // More detail must never yield fewer traced curves.
        #expect(counts[0] <= counts[1] && counts[1] <= counts[2], "\(counts)")
        #expect(counts[2] > counts[0], "slider should change output: \(counts)")
    }
}

private final class BundleToken {}

/// Writes trace results as SVG for human eyes; not part of the app.
enum SVGDump {
    static func write(result: TraceResult, name: String) throws {
        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(result.imageSize.width)) \(Int(result.imageSize.height))">
        <rect width="100%" height="100%" fill="white"/>
        """
        for element in result.elements {
            for polyline in element.polylines {
                let coords = polyline.points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
                let tag = polyline.isClosed ? "polygon" : "polyline"
                svg += "\n<\(tag) points=\"\(coords)\" fill=\"none\" stroke=\"black\" stroke-width=\"1.5\"/>"
            }
        }
        svg += "\n</svg>\n"
        let dir = URL(filePath: "/tmp/drawncut-traces")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try svg.write(to: dir.appending(path: "\(name).svg"), atomically: true, encoding: .utf8)
    }
}
