import CoreGraphics
import Foundation
import simd

/// Turns pixel-space trace polylines into a physically sized DXF: normalizes
/// to the drawing's bounding box, scales to the requested width, and flips
/// the y axis (image space is y-down, CAD space is y-up).
enum DXFExportBuilder {
    static func vectorPaths(from polylines: [Polyline], widthMM: Double, role: PathRole = .engrave) -> [VectorPath] {
        let allPoints = polylines.flatMap(\.points)
        guard !allPoints.isEmpty else { return [] }
        let box = PathGeometry.boundingBox(of: allPoints)
        guard box.width > 0 else { return [] }
        let scale = widthMM / Double(box.width)

        return polylines.map { polyline in
            let points = polyline.points.map { point in
                VectorPath.Point(
                    x: (point.x - Double(box.minX)) * scale,
                    y: (Double(box.maxY) - point.y) * scale
                )
            }
            return VectorPath(points: points, isClosed: polyline.isClosed, role: role)
        }
    }

    static func dxf(from polylines: [Polyline], widthMM: Double) -> String {
        DXFWriter.dxf(for: vectorPaths(from: polylines, widthMM: widthMM))
    }

    /// Physical output size for a given width, preserving aspect ratio.
    static func sizeMM(of polylines: [Polyline], widthMM: Double) -> CGSize {
        let allPoints = polylines.flatMap(\.points)
        guard !allPoints.isEmpty else { return .zero }
        let box = PathGeometry.boundingBox(of: allPoints)
        guard box.width > 0 else { return .zero }
        return CGSize(width: widthMM, height: widthMM * Double(box.height) / Double(box.width))
    }
}
