import CoreGraphics
import Foundation
import simd

/// Mask-space geometry: bridges SAM segmentation masks into the trace
/// pipeline and turns a subject mask into the sticker-style CUT outline.
/// All coordinates are y-down pixel space.
enum MaskGeometry {

    // MARK: - SegmentationMask → BinaryBitmap

    /// Nearest-neighbor resample. The mask's resolution comes from the photo
    /// the segmenter saw; trace space comes from `BinaryBitmap.traceSize` —
    /// they only coincide by luck, so the bridge always offers scaling.
    static func bitmap(from mask: SegmentationMask, scaledTo size: CGSize? = nil) -> BinaryBitmap {
        let targetWidth = size.map { max(1, Int($0.width)) } ?? mask.width
        let targetHeight = size.map { max(1, Int($0.height)) } ?? mask.height
        if targetWidth == mask.width, targetHeight == mask.height {
            return BinaryBitmap(width: mask.width, height: mask.height, pixels: mask.pixels)
        }
        var result = BinaryBitmap(width: targetWidth, height: targetHeight)
        for y in 0..<targetHeight {
            // Sample centers so scaling is symmetric rather than edge-biased.
            let sy = min(mask.height - 1, ((2 * y + 1) * mask.height) / (2 * targetHeight))
            for x in 0..<targetWidth {
                let sx = min(mask.width - 1, ((2 * x + 1) * mask.width) / (2 * targetWidth))
                result.pixels[y * targetWidth + x] = mask.pixels[sy * mask.width + sx]
            }
        }
        return result
    }

    // MARK: - Boundary extraction

    /// Outer contour of the largest 8-connected region as a closed polyline
    /// through boundary pixel centers, clockwise on screen. Interior holes
    /// are ignored: a donut yields only its outside boundary.
    static func outerContour(of bitmap: BinaryBitmap) -> Polyline? {
        guard let component = bitmap.inkComponents(minArea: 1)
            .max(by: { $0.area < $1.area }) else { return nil }
        let points = mooreContour(of: component.localBitmap())
        guard !points.isEmpty else { return nil }
        let offset = SIMD2(Double(component.origin.x), Double(component.origin.y))
        return Polyline(points: points.map { $0 + offset }, isClosed: true)
    }

    /// Sticker-style outline: grow the mask by `offsetPixels` (round kernel),
    /// then take the outer contour of the grown region, simplified and
    /// smoothed. Dilating before contouring is what keeps the offset robust —
    /// offsetting the contour polygon directly self-intersects at concavities
    /// narrower than the offset; a dilated raster cannot.
    static func stickerOutline(
        around bitmap: BinaryBitmap,
        offsetPixels: Int,
        simplifyTolerance: Double = 1.5,
        smoothingPasses: Int = 1
    ) -> Polyline? {
        let grown = offsetPixels > 0 ? dilatedRound(bitmap, radius: offsetPixels) : bitmap
        guard let contour = outerContour(of: grown), contour.points.count >= 3 else { return nil }
        let simplified = PathGeometry.simplified(contour, tolerance: simplifyTolerance)
        return PathGeometry.smoothed(simplified, passes: smoothingPasses)
    }

    /// Approximately Euclidean dilation via a two-pass 3-4 chamfer distance
    /// transform: grows the region by `radius` with rounded corners, where
    /// `BinaryBitmap.dilated`'s square kernel would overshoot corners by √2.
    /// O(pixels) regardless of radius. Growth clips at the frame edge.
    static func dilatedRound(_ bitmap: BinaryBitmap, radius: Int) -> BinaryBitmap {
        guard radius > 0 else { return bitmap }
        let w = bitmap.width, h = bitmap.height, total = w * h
        let far = 3 * (w + h) + 4
        var distance = [Int](repeating: far, count: total)
        for i in 0..<total where bitmap.pixels[i] { distance[i] = 0 }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var d = distance[i]
                if x > 0 { d = min(d, distance[i - 1] + 3) }
                if y > 0 {
                    d = min(d, distance[i - w] + 3)
                    if x > 0 { d = min(d, distance[i - w - 1] + 4) }
                    if x < w - 1 { d = min(d, distance[i - w + 1] + 4) }
                }
                distance[i] = d
            }
        }
        for y in (0..<h).reversed() {
            for x in (0..<w).reversed() {
                let i = y * w + x
                var d = distance[i]
                if x < w - 1 { d = min(d, distance[i + 1] + 3) }
                if y < h - 1 {
                    d = min(d, distance[i + w] + 3)
                    if x < w - 1 { d = min(d, distance[i + w + 1] + 4) }
                    if x > 0 { d = min(d, distance[i + w - 1] + 4) }
                }
                distance[i] = d
            }
        }
        var result = BinaryBitmap(width: w, height: h)
        let cut = 3 * radius
        for i in 0..<total where distance[i] <= cut { result.pixels[i] = true }
        return result
    }

    /// Moore-neighbor boundary following with Jacob's stopping criterion
    /// (stop on re-entering the start pixel in the starting state — a state
    /// repeat proves the loop closed, where "reached start again" alone can
    /// fire early on width-1 spurs that the boundary crosses twice).
    private static func mooreContour(of bitmap: BinaryBitmap) -> [SIMD2<Double>] {
        guard let startIndex = bitmap.pixels.firstIndex(of: true) else { return [] }
        let start = (x: startIndex % bitmap.width, y: startIndex / bitmap.width)

        // 8-neighborhood, clockwise on screen (y-down), starting west. The
        // row-major start pixel has background to its west and north, so a
        // west backtrack is always valid.
        let dirs: [(x: Int, y: Int)] = [
            (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1),
        ]

        var contour: [SIMD2<Double>] = [SIMD2(Double(start.x), Double(start.y))]
        var p = start
        var backtrack = 0   // direction from p toward the background pixel we scanned last
        let initialBacktrack = backtrack
        // Every boundary pixel is visited at most 4 times (once per compass
        // approach), so anything past this is a logic error, not a region.
        let cap = 4 * bitmap.pixels.count + 8

        for _ in 0..<cap {
            var advanced = false
            for k in 1...8 {
                let d = (backtrack + k) % 8
                let candidate = (x: p.x + dirs[d].x, y: p.y + dirs[d].y)
                guard bitmap[candidate.x, candidate.y] else { continue }
                // The neighbor scanned just before is background; consecutive
                // ring positions are 8-adjacent, so it neighbors `candidate`
                // too and becomes the next backtrack.
                let previous = (d + 7) % 8
                let background = (x: p.x + dirs[previous].x, y: p.y + dirs[previous].y)
                backtrack = directionIndex(
                    dx: background.x - candidate.x, dy: background.y - candidate.y, dirs: dirs)
                p = candidate
                advanced = true
                break
            }
            if !advanced { return contour }   // isolated single pixel
            if p == start && backtrack == initialBacktrack { return contour }
            contour.append(SIMD2(Double(p.x), Double(p.y)))
        }
        return contour
    }

    private static func directionIndex(dx: Int, dy: Int, dirs: [(x: Int, y: Int)]) -> Int {
        for (index, dir) in dirs.enumerated() where dir.x == dx && dir.y == dy {
            return index
        }
        preconditionFailure("(\(dx), \(dy)) is not an 8-neighborhood step")
    }
}
