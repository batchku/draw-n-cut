import CoreGraphics
import Foundation
import Testing
@testable import DrawNCut

struct DXFExportBuilderTests {
    @Test func scalesFlipsAndNormalizesToWidth() {
        // A 200×100 px L-shape whose top-left is at (50, 30).
        let polyline = Polyline(
            points: [SIMD2(50, 30), SIMD2(250, 30), SIMD2(250, 130)],
            isClosed: false
        )
        let paths = DXFExportBuilder.vectorPaths(from: [polyline], widthMM: 100)
        #expect(paths.count == 1)
        let points = paths[0].points
        // 200px wide → 100mm: scale 0.5. y flips: image-top (30) → CAD-top.
        #expect(abs(points[0].x - 0) < 0.001 && abs(points[0].y - 50) < 0.001)
        #expect(abs(points[1].x - 100) < 0.001 && abs(points[1].y - 50) < 0.001)
        #expect(abs(points[2].x - 100) < 0.001 && abs(points[2].y - 0) < 0.001)
        #expect(paths[0].role == .engrave)
    }

    @Test func outputSizePreservesAspect() {
        let polyline = Polyline(
            points: [SIMD2(0, 0), SIMD2(400, 0), SIMD2(400, 100)],
            isClosed: false
        )
        let size = DXFExportBuilder.sizeMM(of: [polyline], widthMM: 200)
        #expect(size.width == 200)
        #expect(abs(size.height - 50) < 0.001)
    }

    @Test func emptyInputYieldsValidEmptyDXF() {
        let dxf = DXFExportBuilder.dxf(from: [], widthMM: 100)
        #expect(dxf.contains("EOF"))
    }
}
