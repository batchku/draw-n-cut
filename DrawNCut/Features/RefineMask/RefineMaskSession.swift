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

    func reset() {
        promptGeneration += 1
        points.removeAll()
        mask = nil
        maskImage = nil
        removeMode = false
        if phase == .segmenting { phase = .ready }
    }

    private func refreshMask() {
        guard let segmenter else { return }
        let prompts = points.map { ($0.point, $0.isSubject) }
        guard !prompts.isEmpty else { return }
        promptGeneration += 1
        let generation = promptGeneration
        phase = .segmenting
        Task { [weak self] in
            do {
                let mask = try await segmenter.mask(points: prompts)
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
