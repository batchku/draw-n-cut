import CoreGraphics
import Foundation

/// A 1-bit ink bitmap: `true` means ink. The raster substrate for tracing —
/// built from a photo by grayscale conversion + Otsu thresholding, then carved
/// into connected components that become traced elements.
struct BinaryBitmap {
    let width: Int
    let height: Int
    var pixels: [Bool]

    init(width: Int, height: Int, pixels: [Bool]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? Array(repeating: false, count: width * height)
        precondition(self.pixels.count == width * height)
    }

    /// Out-of-bounds reads are `false`, which lets neighborhood scans skip
    /// explicit border checks.
    subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return pixels[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            pixels[y * width + x] = newValue
        }
    }

    // MARK: - From image

    /// Binarizes a photo/scan: grayscale render, then global Otsu threshold.
    /// Downscales so the long edge is at most `maxDimension` — trace quality
    /// doesn't improve past that, and every later stage is O(pixels).
    init?(cgImage: CGImage, maxDimension: Int = 2000) {
        let scale = min(1.0, Double(maxDimension) / Double(max(cgImage.width, cgImage.height)))
        let w = max(1, Int(Double(cgImage.width) * scale))
        let h = max(1, Int(Double(cgImage.height) * scale))

        var gray = [UInt8](repeating: 0, count: w * h)
        guard let context = CGContext(
            data: &gray,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var histogram = [Int](repeating: 0, count: 256)
        for value in gray { histogram[Int(value)] += 1 }
        let threshold = Self.otsuThreshold(histogram: histogram, total: w * h)

        self.width = w
        self.height = h
        // Ink is darker than the threshold (dark marks on light paper).
        self.pixels = gray.map { Int($0) < threshold }
    }

    /// Classic Otsu: pick the threshold maximizing between-class variance.
    static func otsuThreshold(histogram: [Int], total: Int) -> Int {
        guard total > 0 else { return 128 }
        var sumAll = 0.0
        for t in 0..<256 { sumAll += Double(t) * Double(histogram[t]) }

        var sumBackground = 0.0
        var weightBackground = 0.0
        var bestVariance = -1.0
        var bestThreshold = 128

        for t in 0..<256 {
            weightBackground += Double(histogram[t])
            guard weightBackground > 0 else { continue }
            let weightForeground = Double(total) - weightBackground
            guard weightForeground > 0 else { break }
            sumBackground += Double(t) * Double(histogram[t])
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sumAll - sumBackground) / weightForeground
            let variance = weightBackground * weightForeground * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = t
            }
        }
        return bestThreshold
    }

    // MARK: - Morphology

    /// Square-kernel dilation; enough for mask growth and gap closing.
    func dilated(radius: Int) -> BinaryBitmap {
        guard radius > 0 else { return self }
        var result = BinaryBitmap(width: width, height: height)
        // Two-pass separable dilation: horizontal then vertical.
        var horizontal = BinaryBitmap(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] {
                for dx in -radius...radius { horizontal[x + dx, y] = true }
            }
        }
        for y in 0..<height {
            for x in 0..<width where horizontal.pixels[y * width + x] {
                for dy in -radius...radius { result[x, y + dy] = true }
            }
        }
        return result
    }

    mutating func intersect(_ mask: BinaryBitmap) {
        precondition(mask.width == width && mask.height == height)
        for i in pixels.indices { pixels[i] = pixels[i] && mask.pixels[i] }
    }

    // MARK: - Connected components

    /// 8-connected ink components, smallest speckles already dropped.
    func inkComponents(minArea: Int) -> [InkComponent] {
        var labels = [Int32](repeating: 0, count: pixels.count)
        var components: [InkComponent] = []
        var nextLabel: Int32 = 1
        var stack: [Int] = []

        for start in pixels.indices where pixels[start] && labels[start] == 0 {
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            var member: [Int] = []
            stack.append(start)
            labels[start] = nextLabel
            while let index = stack.popLast() {
                member.append(index)
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let ni = ny * width + nx
                        if pixels[ni] && labels[ni] == 0 {
                            labels[ni] = nextLabel
                            stack.append(ni)
                        }
                    }
                }
            }
            nextLabel += 1
            guard member.count >= minArea else { continue }
            components.append(InkComponent(
                origin: (minX, minY),
                size: (maxX - minX + 1, maxY - minY + 1),
                area: member.count,
                pixelIndices: member,
                imageWidth: width
            ))
        }
        return components
    }
}

/// One connected blob of ink, stored as a bbox-local bitmap.
struct InkComponent {
    let origin: (x: Int, y: Int)
    let size: (width: Int, height: Int)
    let area: Int
    private let localPixels: [Bool]

    init(origin: (x: Int, y: Int), size: (width: Int, height: Int), area: Int, pixelIndices: [Int], imageWidth: Int) {
        self.origin = origin
        self.size = size
        self.area = area
        var local = [Bool](repeating: false, count: size.width * size.height)
        for index in pixelIndices {
            let x = index % imageWidth - origin.x
            let y = index / imageWidth - origin.y
            local[y * size.width + x] = true
        }
        self.localPixels = local
    }

    /// The component as a standalone bitmap in local (bbox) coordinates.
    func localBitmap() -> BinaryBitmap {
        BinaryBitmap(width: size.width, height: size.height, pixels: localPixels)
    }

    var boundingBox: CGRect {
        CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }
}
