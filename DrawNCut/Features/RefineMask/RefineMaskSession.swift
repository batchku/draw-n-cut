import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Observation
import simd

/// Drives the refine-mask screen: loads the photo, loads the SAM 2 models,
/// encodes the photo once, then re-decodes a mask whenever the prompt points
/// change. All prompt coordinates are pixels in the decoded image, which is
/// the same bounded decode `TraceSession` uses so the saved mask lines up
/// with trace space without guesswork.
@MainActor
@Observable
final class RefineMaskSession {
    enum Phase: Equatable {
        case loadingModels
        case encoding
        case ready
        case segmenting
        case failed(String)
    }

    /// A mask covering more of the frame than this is a miss on line
    /// drawings — SAM grabbed the paper or its shadow, not the drawing
    /// (INTEGRATION.md: a paper-region miss measured ~48%, real subjects ~5%).
    static let missInkFraction = 0.3

    private let store: ProjectStore
    let project: DrawingProject
    private var segmenter: SAM2Segmenter?
    /// Ignores mask decodes that finish after the prompts changed again.
    private var promptGeneration = 0

    private(set) var phase: Phase = .loadingModels
    private(set) var image: CGImage?
    private(set) var mask: SegmentationMask?
    private(set) var maskImage: CGImage?
    private(set) var points: [(point: SIMD2<Double>, isSubject: Bool)] = []
    var removeMode = false

    var maskLooksLikeMiss: Bool {
        guard let mask else { return false }
        return mask.inkFraction > Self.missInkFraction
    }

    init(project: DrawingProject, store: ProjectStore) {
        self.project = project
        self.store = store
    }

    /// Where the SAM 2 models live. Dev builds bundle the three
    /// `Models/*.mlpackage` (project.yml); Xcode precompiles them to
    /// `.mlmodelc` in the bundle root, which the loader prefers.
    nonisolated static var modelsDirectory: URL? {
        Bundle.main.resourceURL
    }

    /// The simulator's Core ML GPU path silently returns all-zero logits for
    /// these float16 models (measured: identical prompt, empty mask), so it
    /// gets CPU only. Devices use everything including the ANE.
    nonisolated static var preferredComputeUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .all
        #endif
    }

    func load() async {
        guard let cgImage = Self.decodeImage(at: store.originalImageURL(for: project)) else {
            phase = .failed("Couldn't load this project's photo.")
            return
        }
        image = cgImage
        do {
            guard let directory = Self.modelsDirectory else {
                throw SAM2SegmenterError.modelNotFound(
                    role: "ImageEncoder", directory: URL(filePath: "/"))
            }
            let segmenter = try await SAM2Segmenter(
                modelsDirectory: directory, computeUnits: Self.preferredComputeUnits)
            self.segmenter = segmenter
            phase = .encoding
            try await segmenter.encode(image: cgImage)
            phase = .ready
        } catch {
            phase = .failed("Subject selection isn't available: \(error)")
        }
    }

    // MARK: - Prompts

    func addPoint(atImage point: SIMD2<Double>) {
        guard phase == .ready || phase == .segmenting else { return }
        guard points.count < SAM2Segmenter.maxPromptPoints else { return }
        guard let image,
              point.x >= 0, point.y >= 0,
              point.x <= Double(image.width), point.y <= Double(image.height) else { return }
        points.append((point, !removeMode))
        refreshMask()
    }

    /// A tap near an existing marker deletes that prompt; anywhere else it
    /// adds a new one in the current mode.
    func handleTap(atImage point: SIMD2<Double>, hitRadius: Double) {
        guard phase == .ready || phase == .segmenting else { return }
        if let index = points.firstIndex(where: { simd_length($0.point - point) <= hitRadius }) {
            points.remove(at: index)
            if points.isEmpty {
                // No prompts, no mask — same as reset, but keep the mode.
                promptGeneration += 1
                mask = nil
                maskImage = nil
                if phase == .segmenting { phase = .ready }
            } else {
                refreshMask()
            }
            return
        }
        addPoint(atImage: point)
    }

    func reset() {
        promptGeneration += 1
        points.removeAll()
        mask = nil
        maskImage = nil
        removeMode = false
        if phase == .segmenting { phase = .ready }
    }

    private func refreshMask() {
        guard let segmenter, let image else { return }
        let prompts = points.map { ($0.point, $0.isSubject) }
        guard !prompts.isEmpty else { return }
        let imageWidth = image.width
        let imageHeight = image.height
        promptGeneration += 1
        let generation = promptGeneration
        phase = .segmenting
        Task { [weak self] in
            do {
                let decoded = try await segmenter.mask(points: prompts)
                let (mask, removedRegions) = await Task.detached(priority: .userInitiated) {
                    Self.subtractingRemovedRegions(
                        from: decoded, prompts: prompts,
                        imageWidth: imageWidth, imageHeight: imageHeight)
                }.value
                if removedRegions > 0 {
                    TraceLog.log("minus marker(s) subtracted \(removedRegions) mask region(s)")
                }
                // An all-empty mask selects nothing — treat it as no mask so
                // "Use Outline" can't save a selection that traces to nothing.
                // (Also the symptom of the known iOS-simulator Core ML defect
                // where the decoder zeroes its mask logits; INTEGRATION.md.)
                let isEmpty = mask.inkFraction == 0
                let overlay: CGImage? = isEmpty ? nil : await Task.detached(priority: .userInitiated) {
                    Self.overlayImage(for: mask)
                }.value
                guard let self, self.promptGeneration == generation else { return }
                self.mask = isEmpty ? nil : mask
                self.maskImage = overlay
                self.phase = .ready
                if isEmpty {
                    TraceLog.log("SAM decode returned an empty mask for \(prompts.count) point(s)")
                }
            } catch {
                guard let self, self.promptGeneration == generation else { return }
                // A failed decode shouldn't brick the screen; the user can
                // tap again or skip to tracing everything.
                TraceLog.log("SAM mask decode failed: \(error)")
                self.phase = .ready
            }
        }
    }

    /// SAM often keeps a disjoint region even when a remove marker sits
    /// inside it, which reads as the minus doing nothing. Region subtraction
    /// makes the intent deterministic: any mask region holding a remove
    /// marker — and no add marker — is cut from the selection outright.
    /// Removes inside the subject's own region still defer to the model.
    nonisolated private static func subtractingRemovedRegions(
        from mask: SegmentationMask,
        prompts: [(SIMD2<Double>, Bool)],
        imageWidth: Int, imageHeight: Int
    ) -> (SegmentationMask, Int) {
        guard prompts.contains(where: { !$0.1 }) else { return (mask, 0) }
        var bitmap = MaskGeometry.bitmap(from: mask)
        let components = bitmap.inkComponents(minArea: 1)
        guard components.count > 1 else { return (mask, 0) }
        let locals = components.map { $0.localBitmap() }

        func componentIndex(containing point: SIMD2<Double>) -> Int? {
            let x = Int((point.x * Double(mask.width) / Double(imageWidth)).rounded())
            let y = Int((point.y * Double(mask.height) / Double(imageHeight)).rounded())
            for (index, component) in components.enumerated()
            where locals[index][x - component.origin.x, y - component.origin.y] {
                return index
            }
            return nil
        }

        var keptByAdd: Set<Int> = []
        var markedByRemove: Set<Int> = []
        for (point, isSubject) in prompts {
            guard let index = componentIndex(containing: point) else { continue }
            if isSubject { keptByAdd.insert(index) } else { markedByRemove.insert(index) }
        }
        let doomed = markedByRemove.subtracting(keptByAdd)
        guard !doomed.isEmpty, doomed.count < components.count else { return (mask, 0) }
        for index in doomed {
            let component = components[index]
            let local = locals[index]
            for y in 0..<component.size.height {
                for x in 0..<component.size.width where local[x, y] {
                    bitmap.pixels[(y + component.origin.y) * bitmap.width + (x + component.origin.x)] = false
                }
            }
        }
        return (
            SegmentationMask(width: mask.width, height: mask.height, pixels: bitmap.pixels),
            doomed.count
        )
    }

    // MARK: - Output

    /// Persists the current mask as the project's `mask.png`.
    func saveMask() throws {
        guard let mask else { return }
        try MaskPNG.write(mask, to: store.maskURL(for: project))
    }

    /// The "Trace Everything" path must also forget any previously saved
    /// mask, or the trace screen would silently keep honoring it.
    func discardSavedMask() {
        try? FileManager.default.removeItem(at: store.maskURL(for: project))
    }

    // MARK: - Helpers

    /// Same bounded thumbnail decode as `TraceSession.load` — the mask is
    /// produced in this pixel space, and trace space derives from it.
    nonisolated private static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Bakes the mask into a premultiplied RGBA tint (≈45% blue) so the
    /// overlay is a single texture instead of thousands of SwiftUI shapes.
    nonisolated private static func overlayImage(for mask: SegmentationMask) -> CGImage? {
        let w = mask.width, h = mask.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where mask.pixels[i] {
            rgba[i * 4] = 5        // R (premultiplied by alpha)
            rgba[i * 4 + 1] = 60   // G
            rgba[i * 4 + 2] = 115  // B
            rgba[i * 4 + 3] = 115  // A
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
