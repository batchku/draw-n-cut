import CoreGraphics
import Foundation
import simd

/// Turns pixel-space trace polylines into a physically sized DXF: normalizes
/// to the drawing's bounding box, scales to the requested width, and flips
/// the y axis (image space is y-down, CAD space is y-up).
enum DXFExportBuilder {
    /// `cutOutlines` are the subject's silhouette loops (piece edges and
    /// holes): they map to the CUT role while `polylines` keep `role`
    /// (engrave by default), and they participate in the bounding box, so
    /// `widthMM` is the physical width of the finished piece.
    static func vectorPaths(
        from polylines: [Polyline],
        cutOutlines: [Polyline] = [],
        widthMM: Double,
        role: PathRole = .engrave
    ) -> [VectorPath] {
        let allPoints = polylines.flatMap(\.points) + cutOutlines.flatMap(\.points)
        guard !allPoints.isEmpty else { return [] }
        let box = PathGeometry.boundingBox(of: allPoints)
        guard box.width > 0 else { return [] }
        let scale = widthMM / Double(box.width)

        func convert(_ polyline: Polyline, role: PathRole) -> VectorPath {
            let points = polyline.points.map { point in
                VectorPath.Point(
                    x: (point.x - Double(box.minX)) * scale,
                    y: (Double(box.maxY) - point.y) * scale
                )
            }
            return VectorPath(points: points, isClosed: polyline.isClosed, role: role)
        }

        return polylines.map { convert($0, role: role) }
            + cutOutlines.map { convert($0, role: .cut) }
    }

    static func dxf(from polylines: [Polyline], cutOutlines: [Polyline] = [], widthMM: Double) -> String {
        DXFWriter.dxf(for: vectorPaths(from: polylines, cutOutlines: cutOutlines, widthMM: widthMM))
    }

    /// Physical output size for a given width, preserving aspect ratio.
    static func sizeMM(of polylines: [Polyline], cutOutlines: [Polyline] = [], widthMM: Double) -> CGSize {
        let allPoints = polylines.flatMap(\.points) + cutOutlines.flatMap(\.points)
        guard !allPoints.isEmpty else { return .zero }
        let box = PathGeometry.boundingBox(of: allPoints)
        guard box.width > 0 else { return .zero }
        return CGSize(width: widthMM, height: widthMM * Double(box.height) / Double(box.width))
    }
}
