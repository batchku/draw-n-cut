import CoreGraphics
import Foundation
import simd

/// One erase gesture in trace-space pixels. Shapes rasterize into a mask
/// that is subtracted from the binarized ink before every trace, so an
/// erased mark stays gone at every Detail setting — the analysis never
/// sees its pixels again.
enum EraseShape: Codable, Equatable {
    /// Closed loop; everything inside is erased.
    case lasso(points: [SIMD2<Double>])
    /// Stroked path; everything within `radius` of it is erased.
    case brush(points: [SIMD2<Double>], radius: Double)
}

enum EraseMask {
    /// Rasterizes all shapes into one trace-space mask; nil when there is
    /// nothing to erase.
    static func bitmap(from shapes: [EraseShape], width: Int, height: Int) -> BinaryBitmap? {
        guard !shapes.isEmpty, width > 0, height > 0 else { return nil }
        var bitmap = BinaryBitmap(width: width, height: height)
        for shape in shapes {
            switch shape {
            case .lasso(let points):
                fillPolygon(points, into: &bitmap)
            case .brush(let points, let radius):
                stampStroke(points, radius: radius, into: &bitmap)
            }
        }
        return bitmap
    }

    /// Scanline even-odd fill through pixel centers.
    private static func fillPolygon(_ points: [SIMD2<Double>], into bitmap: inout BinaryBitmap) {
        guard points.count >= 3,
              let rawMinY = points.map(\.y).min(),
              let rawMaxY = points.map(\.y).max() else { return }
        let minY = max(0, Int(rawMinY.rounded(.down)))
        let maxY = min(bitmap.height - 1, Int(rawMaxY.rounded(.up)))
        guard minY <= maxY else { return }
        for y in minY...maxY {
            let scanY = Double(y) + 0.5
            var crossings: [Double] = []
            for i in points.indices {
                let a = points[i]
                let b = points[(i + 1) % points.count]
                // Half-open rule so a vertex exactly on the scanline is
                // counted once, not twice.
                if (a.y <= scanY && b.y > scanY) || (b.y <= scanY && a.y > scanY) {
                    let t = (scanY - a.y) / (b.y - a.y)
                    crossings.append(a.x + t * (b.x - a.x))
                }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let startX = max(0, Int(crossings[i].rounded()))
                let endX = min(bitmap.width - 1, Int(crossings[i + 1].rounded()))
                if startX <= endX {
                    for x in startX...endX { bitmap[x, y] = true }
                }
                i += 2
            }
        }
    }

    /// Stamps discs along the path densely enough that they overlap into a
    /// solid capsule per segment.
    static func stampStroke(_ points: [SIMD2<Double>], radius: Double, into bitmap: inout BinaryBitmap) {
        guard let first = points.first else { return }
        let r = max(1.0, radius)
        stampDisc(at: first, radius: r, into: &bitmap)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let steps = max(1, Int(simd_length(b - a) / (r * 0.5)))
            for s in 1...steps {
                stampDisc(at: a + (b - a) * (Double(s) / Double(steps)), radius: r, into: &bitmap)
            }
        }
    }

    private static func stampDisc(at center: SIMD2<Double>, radius: Double, into bitmap: inout BinaryBitmap) {
        let minX = max(0, Int((center.x - radius).rounded(.down)))
        let maxX = min(bitmap.width - 1, Int((center.x + radius).rounded(.up)))
        let minY = max(0, Int((center.y - radius).rounded(.down)))
        let maxY = min(bitmap.height - 1, Int((center.y + radius).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let r2 = radius * radius
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - center.x
                let dy = Double(y) + 0.5 - center.y
                if dx * dx + dy * dy <= r2 { bitmap[x, y] = true }
            }
        }
    }
}
