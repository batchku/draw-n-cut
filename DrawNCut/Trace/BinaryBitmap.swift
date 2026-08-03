import CoreGraphics
import Foundation

/// What binarization decided for one frame, so callers can explain results
/// ("Nothing to Trace" because the paper mask fired vs. because the page is
/// blank) instead of guessing. `paperCoverage` is the fraction of the frame
/// the applied mask kept, 0 while the mask is inactive; the two contrast
/// figures are the statistics the mask gating read, in gray levels.
struct BinarizationReport: Sendable {
    var inkPixelCount: Int
    var paperMaskActive: Bool
    var paperCoverage: Double
    var otsuClassSeparation: Double
    var paperSurroundContrast: Double
}

/// A 1-bit ink bitmap: `true` means ink. The raster substrate for tracing —
/// built from a photo by grayscale conversion + local adaptive thresholding,
/// then carved into connected components that become traced elements.
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

    /// The pixel size tracing will use for an image: downscaled so the long
    /// edge is at most `maxDimension`. Anything mapping external coordinates
    /// (Vision rects, taps) into trace space must use this.
    static func traceSize(for cgImage: CGImage, maxDimension: Int = 2000) -> CGSize {
        let scale = min(1.0, Double(maxDimension) / Double(max(cgImage.width, cgImage.height)))
        return CGSize(
            width: max(1, Int(Double(cgImage.width) * scale)),
            height: max(1, Int(Double(cgImage.height) * scale))
        )
    }

    /// Binarizes a photo/scan: grayscale render, then a local adaptive
    /// threshold — a pixel is ink when it is dark relative to its own
    /// window's statistics. Pen marks are locally dark; tables, shadows, and
    /// lighting gradients change too gradually to qualify. (A global
    /// threshold fails on handheld photos: paper on a dark table splits
    /// paper-vs-table and the whole table becomes "ink".)
    /// Downscales so the long edge is at most `maxDimension` — trace quality
    /// doesn't improve past that, and every later stage is O(pixels).
    init?(cgImage: CGImage, maxDimension: Int = 2000) {
        var report: BinarizationReport? = nil
        self.init(cgImage: cgImage, maxDimension: maxDimension, report: &report)
    }

    /// Same as `init?(cgImage:maxDimension:)`, but also fills `report` with
    /// the decisions made (nil only when the image itself fails to render).
    init?(cgImage: CGImage, maxDimension: Int = 2000, report: inout BinarizationReport?) {
        let size = Self.traceSize(for: cgImage, maxDimension: maxDimension)
        let w = Int(size.width)
        let h = Int(size.height)

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

        self.width = w
        self.height = h

        // Window ≈ 1/14 of the long edge: wider than any pen stroke (so a
        // stroke never fills its own window), narrower than lighting changes.
        // The contrast gate is the minimum darkness a mark needs against its
        // surroundings; 25 gray levels keeps soft pencil while rejecting
        // sensor noise and shadow gradients.
        let window = max(15, max(w, h) / 14)
        var ink = Self.locallyDarkMask(gray: gray, width: w, height: h, window: window, minContrast: 25)

        // A handheld photo has content only on the paper; whatever the local
        // threshold picked up around it (the paper's own contrast edge, table
        // texture) is garbage.
        var diagnostics = BinarizationReport(
            inkPixelCount: 0, paperMaskActive: false, paperCoverage: 0,
            otsuClassSeparation: 0, paperSurroundContrast: 0
        )
        if let paper = Self.paperRegion(gray: gray, width: w, height: h, margin: window / 2, report: &diagnostics) {
            for i in ink.indices where !paper[i] { ink[i] = false }
        }

        Self.fillDarkHoles(ink: &ink, gray: gray, width: w, height: h)
        // Faint strokes (screen photos, light pencil) perforate under the
        // local threshold; a radius-1 closing re-bridges those pinholes
        // before the ink is carved into components.
        let bridged = BinaryBitmap(width: w, height: h, pixels: ink).closed(radius: 1)
        diagnostics.inkPixelCount = bridged.pixels.reduce(into: 0) { if $1 { $0 += 1 } }
        self.pixels = bridged.pixels
        report = diagnostics
    }

    /// Pixels darker than a cut 60% of the way from the local window mean
    /// (≈ the background, since marks are thin) down to the darkest value in
    /// the window (≈ the pen). That cut approximates what a global Otsu
    /// picks on a clean scan — the window minimum sits below the ink class
    /// mean, so a plain 50% midpoint runs stricter than Otsu and perforates
    /// faint stroke segments. Computing it per-window instead of globally is
    /// what survives arbitrary backgrounds. Windows whose mean-to-minimum
    /// contrast stays under `minContrast` hold no mark at all and yield
    /// nothing.
    /// The mean comes from a summed-area table and the minimum from a
    /// separable sliding-window pass, so the whole mask is O(pixels).
    /// Accumulators are Int64: full-resolution gray sums overflow Int32.
    private static func locallyDarkMask(
        gray: [UInt8], width w: Int, height h: Int, window: Int, minContrast: Int64
    ) -> [Bool] {
        var integral = [Int64](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum: Int64 = 0
            let row = (y + 1) * (w + 1)
            let previousRow = y * (w + 1)
            for x in 0..<w {
                rowSum += Int64(gray[y * w + x])
                integral[row + x + 1] = integral[previousRow + x + 1] + rowSum
            }
        }

        let radius = window / 2
        let minimum = slidingMinimum(gray, width: w, height: h, radius: radius)

        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius), y1 = min(h - 1, y + radius)
            let top = y0 * (w + 1), bottom = (y1 + 1) * (w + 1)
            for x in 0..<w {
                let x0 = max(0, x - radius), x1 = min(w - 1, x + radius)
                let count = Int64((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = integral[bottom + x1 + 1] - integral[top + x1 + 1]
                    - integral[bottom + x0] + integral[top + x0]
                let darkest = Int64(minimum[y * w + x])
                guard sum - darkest * count >= minContrast * count else { continue }
                if 10 * (Int64(gray[y * w + x]) - darkest) * count < 6 * (sum - darkest * count) {
                    ink[y * w + x] = true
                }
            }
        }
        return ink
    }

    /// Windowed minimum, one dimension at a time with a monotonic deque —
    /// O(pixels) regardless of the window size.
    private static func slidingMinimum(
        _ values: [UInt8], width w: Int, height h: Int, radius: Int
    ) -> [UInt8] {
        func pass(_ input: [UInt8], length: Int, lines: Int, stride: Int, lineStride: Int) -> [UInt8] {
            var output = input
            var deque = [Int](repeating: 0, count: length)
            for line in 0..<lines {
                let base = line * lineStride
                var head = 0, tail = 0
                for i in 0..<(length + radius) {
                    if i < length {
                        let value = input[base + i * stride]
                        while tail > head && input[base + deque[tail - 1] * stride] >= value {
                            tail -= 1
                        }
                        deque[tail] = i
                        tail += 1
                    }
                    let out = i - radius
                    if out >= 0 {
                        while deque[head] < out - radius { head += 1 }
                        output[base + out * stride] = input[base + deque[head] * stride]
                    }
                }
            }
            return output
        }
        let rows = pass(values, length: w, lines: h, stride: 1, lineStride: w)
        return pass(rows, length: h, lines: w, stride: w, lineStride: 1)
    }

    /// The single dominant bright region — the paper in a handheld photo —
    /// eroded inward by `margin`, or nil when the frame lacks genuine
    /// paper-on-darker-surround evidence. Otsu always produces *a* split, so
    /// activation is gated on what the split actually separated (values
    /// measured on the fixtures):
    /// - Class separation: lighting bands across one surface sit close
    ///   together; paper against a dark table separates by 150+ levels
    ///   (composites: 177). Below 55 there is only one surface — don't mask.
    /// - Surround darkness: a page filling the frame puts paper at the
    ///   border, so the border median lands within a shadow's depth of the
    ///   paper median (fish-photo: 13 apart, despite a separation of 79
    ///   because Otsu split its lit band from its shadowed band); a real
    ///   table sits far below (composites: 191 apart). Under 50 apart the
    ///   "surround" is the paper itself — don't mask.
    /// When masking is justified, the region is rebuilt at a threshold
    /// relaxed toward the border brightness rather than the hard Otsu cut,
    /// so shadow bands on the paper — brighter than any table that passed
    /// the gate — stay inside the region and keep the marks under them.
    /// The scan guard remains: a frame that is (nearly) all paper, as on a
    /// flatbed, never masks, so scans keep their exact behavior.
    /// The erosion matters: within half a window of the paper's edge the
    /// step to the table dominates local statistics, so the paper's own
    /// anti-aliased boundary and edge shadows read as "locally dark" there.
    private static func paperRegion(
        gray: [UInt8], width w: Int, height h: Int, margin: Int, report: inout BinarizationReport
    ) -> [Bool]? {
        let total = w * h
        var histogram = [Int](repeating: 0, count: 256)
        for value in gray { histogram[Int(value)] += 1 }
        let split = otsuThreshold(histogram: histogram, total: total)

        var darkSum = 0.0, darkWeight = 0.0, brightSum = 0.0, brightWeight = 0.0
        for value in 0..<256 {
            let weight = Double(histogram[value])
            if value < split {
                darkSum += Double(value) * weight
                darkWeight += weight
            } else {
                brightSum += Double(value) * weight
                brightWeight += weight
            }
        }
        guard darkWeight > 0, brightWeight > 0 else { return nil }
        let separation = brightSum / brightWeight - darkSum / darkWeight
        report.otsuClassSeparation = separation

        func median(of histogram: [Int]) -> Int {
            let count = histogram.reduce(0, +)
            var seen = 0
            for value in 0..<256 {
                seen += histogram[value]
                if seen * 2 >= count { return value }
            }
            return 255
        }
        // The border band is thin so that a paper edge cropped by the frame
        // (one side of the border being paper) can't drag the median up.
        let band = max(2, margin / 4)
        var borderHistogram = [Int](repeating: 0, count: 256)
        for y in 0..<h {
            let edgeRow = y < band || y >= h - band
            for x in 0..<w where edgeRow || x < band || x >= w - band {
                borderHistogram[Int(gray[y * w + x])] += 1
            }
        }
        let borderMedian = median(of: borderHistogram)
        var brightHistogram = histogram
        for value in 0..<split { brightHistogram[value] = 0 }
        let paperMedian = median(of: brightHistogram)
        report.paperSurroundContrast = Double(paperMedian - borderMedian)

        if separation < 55 { return nil }
        if paperMedian - borderMedian < 50 { return nil }

        // Rebuilding at the relaxed cut keeps shadowed paper bright enough
        // to stay "paper" while everything table-dark stays out.
        let relaxed = min(split, borderMedian + max(25, (paperMedian - borderMedian) / 3))

        // Largest 4-connected bright region.
        var labels = [Int32](repeating: 0, count: total)
        var nextLabel: Int32 = 1
        var bestLabel: Int32 = 0
        var bestCount = 0
        var stack: [Int] = []
        for start in 0..<total where Int(gray[start]) >= relaxed && labels[start] == 0 {
            var count = 0
            labels[start] = nextLabel
            stack.append(start)
            func visit(_ neighbor: Int) {
                if Int(gray[neighbor]) >= relaxed && labels[neighbor] == 0 {
                    labels[neighbor] = nextLabel
                    stack.append(neighbor)
                }
            }
            while let index = stack.popLast() {
                count += 1
                let x = index % w, y = index / w
                if x > 0 { visit(index - 1) }
                if x < w - 1 { visit(index + 1) }
                if y > 0 { visit(index - w) }
                if y < h - 1 { visit(index + w) }
            }
            if count > bestCount {
                bestCount = count
                bestLabel = nextLabel
            }
            nextLabel += 1
        }
        guard bestCount > 0 else { return nil }

        // Everything reachable from the frame border without entering that
        // region is off-paper; unreachable pockets (ink strokes, drawings)
        // stay part of the paper.
        var outside = [Bool](repeating: false, count: total)
        var outsideCount = 0
        func seed(_ index: Int) {
            if labels[index] != bestLabel && !outside[index] {
                outside[index] = true
                stack.append(index)
            }
        }
        for x in 0..<w {
            seed(x)
            seed((h - 1) * w + x)
        }
        for y in 0..<h {
            seed(y * w)
            seed(y * w + w - 1)
        }
        while let index = stack.popLast() {
            outsideCount += 1
            let x = index % w, y = index / w
            if x > 0 { seed(index - 1) }
            if x < w - 1 { seed(index + 1) }
            if y > 0 { seed(index - w) }
            if y < h - 1 { seed(index + w) }
        }

        let paperCount = total - outsideCount
        // Nearly all paper: a scan — restriction would only cost content.
        if paperCount * 10 >= total * 9 { return nil }
        // No dominant paper either: don't guess, let the trace guards cope.
        if paperCount * 5 < total { return nil }

        // Erode by Chebyshev distance-to-outside (two-pass chamfer, O(pixels)).
        // The world beyond the frame counts as outside too: where the paper
        // is cropped by the frame, the frame edge *is* the paper edge and
        // carries the same seam artifacts, so the margin must erode there
        // just like along a visible paper boundary.
        let far = w + h
        var distance = [Int](repeating: far, count: total)
        for index in 0..<total where outside[index] { distance[index] = 0 }
        for x in 0..<w {
            distance[x] = min(distance[x], 1)
            distance[(h - 1) * w + x] = min(distance[(h - 1) * w + x], 1)
        }
        for y in 0..<h {
            distance[y * w] = min(distance[y * w], 1)
            distance[y * w + w - 1] = min(distance[y * w + w - 1], 1)
        }
        for y in 0..<h {
            for x in 0..<w {
                let index = y * w + x
                var d = distance[index]
                if x > 0 { d = min(d, distance[index - 1] + 1) }
                if y > 0 {
                    d = min(d, distance[index - w] + 1)
                    if x > 0 { d = min(d, distance[index - w - 1] + 1) }
                    if x < w - 1 { d = min(d, distance[index - w + 1] + 1) }
                }
                distance[index] = d
            }
        }
        for y in (0..<h).reversed() {
            for x in (0..<w).reversed() {
                let index = y * w + x
                var d = distance[index]
                if x < w - 1 { d = min(d, distance[index + 1] + 1) }
                if y < h - 1 {
                    d = min(d, distance[index + w] + 1)
                    if x < w - 1 { d = min(d, distance[index + w + 1] + 1) }
                    if x > 0 { d = min(d, distance[index + w - 1] + 1) }
                }
                distance[index] = d
            }
        }
        var mask = [Bool](repeating: false, count: total)
        var covered = 0
        for index in 0..<total where distance[index] > margin {
            mask[index] = true
            covered += 1
        }
        report.paperMaskActive = true
        report.paperCoverage = Double(covered) / Double(total)
        return mask
    }

    /// The adaptive window saturates inside solid fills larger than itself
    /// (the local mean becomes the ink), hollowing them out. Refill enclosed
    /// background pockets that are as dark as the ink around them — the pen
    /// really covered those. Bright pockets are paper (the inside of a drawn
    /// loop) and stay background. 4-connected background can't leak through
    /// 8-connected strokes, so "enclosed" is exact.
    private static func fillDarkHoles(ink: inout [Bool], gray: [UInt8], width w: Int, height h: Int) {
        let total = w * h
        var reached = [Bool](repeating: false, count: total)
        var stack: [Int] = []
        func seed(_ index: Int) {
            if !ink[index] && !reached[index] {
                reached[index] = true
                stack.append(index)
            }
        }
        for x in 0..<w {
            seed(x)
            seed((h - 1) * w + x)
        }
        for y in 0..<h {
            seed(y * w)
            seed(y * w + w - 1)
        }
        while let index = stack.popLast() {
            let x = index % w, y = index / w
            if x > 0 { seed(index - 1) }
            if x < w - 1 { seed(index + 1) }
            if y > 0 { seed(index - w) }
            if y < h - 1 { seed(index + w) }
        }

        var hole: [Int] = []
        for start in 0..<total where !ink[start] && !reached[start] {
            hole.removeAll(keepingCapacity: true)
            var holeSum = 0
            var boundarySum = 0
            var boundaryCount = 0
            reached[start] = true
            stack.append(start)
            func visit(_ neighbor: Int) {
                if ink[neighbor] {
                    boundarySum += Int(gray[neighbor])
                    boundaryCount += 1
                } else if !reached[neighbor] {
                    reached[neighbor] = true
                    stack.append(neighbor)
                }
            }
            while let index = stack.popLast() {
                hole.append(index)
                holeSum += Int(gray[index])
                let x = index % w, y = index / w
                if x > 0 { visit(index - 1) }
                if x < w - 1 { visit(index + 1) }
                if y > 0 { visit(index - w) }
                if y < h - 1 { visit(index + w) }
            }
            let holeMean = holeSum / hole.count
            let boundaryMean = boundaryCount > 0 ? boundarySum / boundaryCount : 0
            if holeMean <= boundaryMean + 40 {
                for index in hole { ink[index] = true }
            }
        }
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

    /// Erosion via the dilation of the inverse. Outside the frame counts as
    /// background, so border-touching ink shrinks — acceptable for closing.
    func eroded(radius: Int) -> BinaryBitmap {
        guard radius > 0 else { return self }
        var inverted = self
        for i in inverted.pixels.indices { inverted.pixels[i].toggle() }
        var result = inverted.dilated(radius: radius)
        for i in result.pixels.indices { result.pixels[i].toggle() }
        return result
    }

    /// Morphological closing: bridges sub-pixel-scale stroke perforations
    /// (threshold flicker along a faint pen line) without thickening strokes.
    func closed(radius: Int) -> BinaryBitmap {
        dilated(radius: radius).eroded(radius: radius)
    }

    mutating func intersect(_ mask: BinaryBitmap) {
        precondition(mask.width == width && mask.height == height)
        for i in pixels.indices { pixels[i] = pixels[i] && mask.pixels[i] }
    }

    /// Clears every pixel that is set in `mask`.
    mutating func subtract(_ mask: BinaryBitmap) {
        precondition(mask.width == width && mask.height == height)
        for i in pixels.indices where mask.pixels[i] { pixels[i] = false }
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
