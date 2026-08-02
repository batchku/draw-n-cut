import Foundation
import Testing
@testable import DrawNCut

struct DXFWriterTests {
    private let square = VectorPath(
        points: [.init(x: 0, y: 0), .init(x: 100, y: 0), .init(x: 100, y: 100), .init(x: 0, y: 100)],
        isClosed: true,
        role: .cut
    )
    private let zigzag = VectorPath(
        points: [.init(x: 10, y: 10), .init(x: 20, y: 30), .init(x: 30, y: 10)],
        isClosed: false,
        role: .engrave
    )

    /// Parses the flat group-code/value stream back into pairs.
    private func pairs(_ dxf: String) -> [(code: Int, value: String)] {
        let lines = dxf.split(separator: "\r\n").map(String.init)
        return stride(from: 0, to: lines.count - 1, by: 2).map { (Int(lines[$0])!, lines[$0 + 1]) }
    }

    @Test func documentHasValidStructure() {
        let dxf = DXFWriter.dxf(for: [square, zigzag])
        let all = pairs(dxf)

        #expect(all.last! == (0, "EOF"))
        #expect(all.contains { $0 == (1, "AC1009") })
        // Millimeter units declared.
        let insunitsIndex = all.firstIndex { $0 == (9, "$INSUNITS") }
        #expect(insunitsIndex != nil)
        #expect(all[insunitsIndex! + 1] == (70, "4"))
        // Sections are balanced.
        let sections = all.filter { $0 == (0, "SECTION") }.count
        let endsecs = all.filter { $0 == (0, "ENDSEC") }.count
        #expect(sections == 3 && endsecs == 3)
    }

    @Test func declaresCutAndEngraveLayers() {
        let all = pairs(DXFWriter.dxf(for: [square]))
        let layerNames = zip(all, all.dropFirst())
            .filter { $0.0 == (0, "LAYER") }
            .map { $0.1.value }
        #expect(layerNames == ["CUT", "ENGRAVE"])
    }

    @Test func pathsLandOnLayersMatchingTheirRole() {
        let all = pairs(DXFWriter.dxf(for: [square, zigzag]))
        let polylineLayers = zip(all, all.dropFirst())
            .filter { $0.0 == (0, "POLYLINE") }
            .map { $0.1.value }
        #expect(polylineLayers == ["CUT", "ENGRAVE"])
    }

    @Test func closedFlagAndVertexCountsRoundTrip() {
        let all = pairs(DXFWriter.dxf(for: [square, zigzag]))
        let closedFlags = all.enumerated()
            .filter { $0.element == (0, "POLYLINE") }
            .map { index in all[index.offset + 3].value }
        #expect(closedFlags == ["1", "0"])
        let vertexCount = all.filter { $0 == (0, "VERTEX") }.count
        #expect(vertexCount == square.points.count + zigzag.points.count)
    }

    @Test func degeneratePathsAreDropped() {
        let dot = VectorPath(points: [.init(x: 5, y: 5)], isClosed: false, role: .cut)
        let all = pairs(DXFWriter.dxf(for: [dot]))
        #expect(!all.contains { $0 == (0, "POLYLINE") })
        #expect(all.last! == (0, "EOF"))
    }
}
