//
//  SAM2Segmenter.swift
//  DrawNCut
//
//  On-device SAM 2.1 (Apple Core ML port, apple/coreml-sam2.1-small) wrapper.
//
//  Pipeline: image encoder (1024x1024) -> prompt encoder (1..16 point prompts)
//  -> mask decoder (3 candidate masks + IoU scores; best one is kept).
//  The returned mask is upsampled to the original image resolution so the
//  boundary can be offset into a sticker-style laser CUT outline.
//
//  Self-contained: no imports from the rest of the app. The orchestrator
//  bridges `SegmentationMask` to `BinaryBitmap`.
//

import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// A binary mask at original image resolution. Row-major, `pixels[y * width + x]`,
/// `true` = inside the segmented subject.
public struct SegmentationMask: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [Bool]

    public init(width: Int, height: Int, pixels: [Bool]) {
        precondition(pixels.count == width * height, "pixel count must equal width * height")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Bool {
        pixels[y * width + x]
    }

    /// Fraction of pixels that are inside the mask.
    public var inkFraction: Double {
        guard !pixels.isEmpty else { return 0 }
        return Double(pixels.lazy.filter { $0 }.count) / Double(pixels.count)
    }
}

public enum SAM2SegmenterError: Error, CustomStringConvertible {
    case modelNotFound(role: String, directory: URL)
    case pixelBufferCreationFailed
    case drawingContextCreationFailed
    case imageNotEncoded
    case invalidPointCount(Int)
    case pointOutOfBounds(SIMD2<Double>)
    case unexpectedModelOutput(String)

    public var description: String {
        switch self {
        case .modelNotFound(let role, let directory):
            return "SAM2 \(role) model not found in \(directory.path). Run scripts/download-models.sh."
        case .pixelBufferCreationFailed:
            return "Failed to create a 1024x1024 pixel buffer for the image encoder."
        case .drawingContextCreationFailed:
            return "Failed to create a CGContext over the encoder pixel buffer."
        case .imageNotEncoded:
            return "mask(points:) called before encode(image:)."
        case .invalidPointCount(let n):
            return "SAM2 prompt encoder accepts 1...16 points, got \(n)."
        case .pointOutOfBounds(let p):
            return "Prompt point \(p) lies outside the encoded image bounds."
        case .unexpectedModelOutput(let detail):
            return "Unexpected SAM2 model output: \(detail)"
        }
    }
}

/// Wraps the three SAM 2.1 Core ML models and holds the cached image embedding,
/// so the user can tap several candidate points cheaply after one encode pass.
public actor SAM2Segmenter {

    /// Side length of the square model input. SAM 2 uses plain scale-to-fill
    /// resizing (no letterboxing), matching Apple's conversion.
    public static let modelInputSide = 1024
    /// Prompt encoder range constraint (verified on apple/coreml-sam2.1-small).
    public static let maxPromptPoints = 16

    private let imageEncoder: MLModel
    private let promptEncoder: MLModel
    private let maskDecoder: MLModel

    private struct EncodedImage {
        let imageEmbedding: MLMultiArray  // 1 x 256 x 64 x 64
        let featsS0: MLMultiArray         // 1 x 32 x 256 x 256
        let featsS1: MLMultiArray         // 1 x 64 x 128 x 128
        let width: Int                    // original image width
        let height: Int                   // original image height
    }

    private var encodedImage: EncodedImage?

    /// Loads the image encoder, prompt encoder and mask decoder from
    /// `modelsDirectory`. Accepts `.mlmodelc` (precompiled) or `.mlpackage`
    /// (compiled on first use, cached in Caches/SAM2CompiledModels).
    ///
    /// - Parameters:
    ///   - modelsDirectory: directory containing the three SAM2 models, e.g.
    ///     the repo-root `Models/` folder populated by `scripts/download-models.sh`.
    ///   - computeUnits: `.all` uses the ANE when available; `.cpuAndGPU` is a
    ///     safe default on Macs without ANE access.
    public init(
        modelsDirectory: URL,
        computeUnits: MLComputeUnits = .cpuAndGPU
    ) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        self.imageEncoder = try Self.loadModel(
            role: "ImageEncoder", in: modelsDirectory, configuration: configuration)
        self.promptEncoder = try Self.loadModel(
            role: "PromptEncoder", in: modelsDirectory, configuration: configuration)
        self.maskDecoder = try Self.loadModel(
            role: "MaskDecoder", in: modelsDirectory, configuration: configuration)
    }

    // MARK: - Encoding

    /// Resizes `image` to 1024x1024 (scale-to-fill, matching the coordinate
    /// transform used for prompts), runs the image encoder and caches the
    /// embeddings. Call once per photo; then `mask(points:)` is cheap.
    public func encode(image: CGImage) async throws {
        let pixelBuffer = try Self.makeInputPixelBuffer(from: image)
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let outputs = try await imageEncoder.prediction(from: inputs)

        guard
            let embedding = outputs.featureValue(for: "image_embedding")?.multiArrayValue,
            let featsS0 = outputs.featureValue(for: "feats_s0")?.multiArrayValue,
            let featsS1 = outputs.featureValue(for: "feats_s1")?.multiArrayValue
        else {
            throw SAM2SegmenterError.unexpectedModelOutput(
                "image encoder did not produce image_embedding/feats_s0/feats_s1")
        }

        encodedImage = EncodedImage(
            imageEmbedding: embedding,
            featsS0: featsS0,
            featsS1: featsS1,
            width: image.width,
            height: image.height)
    }

    /// Discards the cached embedding (e.g. when the user picks a new photo).
    public func reset() {
        encodedImage = nil
    }

    // MARK: - Mask decoding

    /// Runs the prompt encoder + mask decoder for point prompts given in
    /// ORIGINAL image pixel coordinates. `true` = foreground (include),
    /// `false` = background (exclude). Returns the best-scoring of SAM2's
    /// three candidate masks, bilinearly upsampled to the original image
    /// resolution and thresholded at logit 0.
    public func mask(points: [(SIMD2<Double>, Bool)]) async throws -> SegmentationMask {
        guard let encoded = encodedImage else {
            throw SAM2SegmenterError.imageNotEncoded
        }
        guard (1...Self.maxPromptPoints).contains(points.count) else {
            throw SAM2SegmenterError.invalidPointCount(points.count)
        }

        // 1. Point prompts -> model input coordinates (scale-fill to 1024x1024).
        let side = Double(Self.modelInputSide)
        let pointsArray = try MLMultiArray(
            shape: [1, NSNumber(value: points.count), 2], dataType: .float32)
        let labelsArray = try MLMultiArray(
            shape: [1, NSNumber(value: points.count)], dataType: .int32)
        for (index, (point, isForeground)) in points.enumerated() {
            guard point.x >= 0, point.y >= 0,
                  point.x <= Double(encoded.width), point.y <= Double(encoded.height)
            else {
                throw SAM2SegmenterError.pointOutOfBounds(point)
            }
            let modelX = point.x / Double(encoded.width) * side
            let modelY = point.y / Double(encoded.height) * side
            pointsArray[[0, NSNumber(value: index), 0]] = NSNumber(value: Float(modelX))
            pointsArray[[0, NSNumber(value: index), 1]] = NSNumber(value: Float(modelY))
            labelsArray[[0, NSNumber(value: index)]] = NSNumber(value: isForeground ? 1 : 0)
        }

        // 2. Prompt encoder.
        let promptInputs = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: pointsArray),
            "labels": MLFeatureValue(multiArray: labelsArray),
        ])
        let promptOutputs = try await promptEncoder.prediction(from: promptInputs)
        guard
            let sparse = promptOutputs.featureValue(for: "sparse_embeddings")?.multiArrayValue,
            let dense = promptOutputs.featureValue(for: "dense_embeddings")?.multiArrayValue
        else {
            throw SAM2SegmenterError.unexpectedModelOutput(
                "prompt encoder did not produce sparse_embeddings/dense_embeddings")
        }

        // 3. Mask decoder (note: decoder input names are singular).
        let decoderInputs = try MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": MLFeatureValue(multiArray: encoded.imageEmbedding),
            "sparse_embedding": MLFeatureValue(multiArray: sparse),
            "dense_embedding": MLFeatureValue(multiArray: dense),
            "feats_s0": MLFeatureValue(multiArray: encoded.featsS0),
            "feats_s1": MLFeatureValue(multiArray: encoded.featsS1),
        ])
        let decoderOutputs = try await maskDecoder.prediction(from: decoderInputs)
        guard
            let lowResMasks = decoderOutputs.featureValue(for: "low_res_masks")?.multiArrayValue,
            let scoresArray = decoderOutputs.featureValue(for: "scores")?.multiArrayValue
        else {
            throw SAM2SegmenterError.unexpectedModelOutput(
                "mask decoder did not produce low_res_masks/scores")
        }

        // 4. Pick the best-scoring of the 3 candidate masks.
        let scores = try Self.floatArray(from: scoresArray)
        guard lowResMasks.shape.count == 4, lowResMasks.shape[0] == 1,
              lowResMasks.shape[1].intValue == scores.count
        else {
            throw SAM2SegmenterError.unexpectedModelOutput(
                "low_res_masks shape \(lowResMasks.shape) does not match \(scores.count) scores")
        }
        let maskHeight = lowResMasks.shape[2].intValue
        let maskWidth = lowResMasks.shape[3].intValue
        let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0

        let allLogits = try Self.floatArray(from: lowResMasks)
        let planeSize = maskHeight * maskWidth
        let bestLogits = Array(allLogits[(bestIndex * planeSize)..<((bestIndex + 1) * planeSize)])

        // 5. Bilinear upsample logits to original resolution, threshold at 0.
        let pixels = Self.upsampleAndThreshold(
            logits: bestLogits,
            sourceWidth: maskWidth,
            sourceHeight: maskHeight,
            targetWidth: encoded.width,
            targetHeight: encoded.height)

        return SegmentationMask(width: encoded.width, height: encoded.height, pixels: pixels)
    }

    // MARK: - Model loading

    private static func loadModel(
        role: String,
        in directory: URL,
        configuration: MLModelConfiguration
    ) throws -> MLModel {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        // Variant-agnostic: matches SAM2_1Small…, SAM2_1Tiny…, etc.
        func candidate(withExtension ext: String) -> URL? {
            contents.first {
                $0.pathExtension == ext && $0.lastPathComponent.contains(role)
            }
        }

        if let compiled = candidate(withExtension: "mlmodelc") {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        guard let package = candidate(withExtension: "mlpackage") else {
            throw SAM2SegmenterError.modelNotFound(role: role, directory: directory)
        }

        // Compile once, cache the .mlmodelc so subsequent launches skip
        // compilation (~seconds for the image encoder).
        let cacheDirectory = try fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SAM2CompiledModels", isDirectory: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let cachedURL = cacheDirectory.appendingPathComponent(
            package.deletingPathExtension().lastPathComponent + ".mlmodelc")
        if fileManager.fileExists(atPath: cachedURL.path) {
            if let model = try? MLModel(contentsOf: cachedURL, configuration: configuration) {
                return model
            }
            // Stale/corrupt cache: recompile.
            try? fileManager.removeItem(at: cachedURL)
        }

        let compiledURL = try MLModel.compileModel(at: package)
        _ = try? fileManager.replaceItemAt(cachedURL, withItemAt: compiledURL)
        let loadURL = fileManager.fileExists(atPath: cachedURL.path) ? cachedURL : compiledURL
        return try MLModel(contentsOf: loadURL, configuration: configuration)
    }

    // MARK: - Preprocessing

    /// Draws `image` scale-to-fill into a 1024x1024 BGRA pixel buffer.
    /// SAM 2's normalization is baked into the Core ML image input.
    private static func makeInputPixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let side = modelInputSide
        var pixelBufferOut: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw SAM2SegmenterError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw SAM2SegmenterError.drawingContextCreationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixelBuffer
    }

    // MARK: - Output handling

    /// Copies an MLMultiArray (float16/float32/double) into a contiguous [Float].
    private static func floatArray(from multiArray: MLMultiArray) throws -> [Float] {
        switch multiArray.dataType {
        case .float32:
            return multiArray.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        case .double:
            return multiArray.withUnsafeBufferPointer(ofType: Double.self) { $0.map(Float.init) }
        case .float16:
            #if arch(x86_64)
            // Float16 is unavailable on Intel; fall back to NSNumber access.
            return (0..<multiArray.count).map { multiArray[$0].floatValue }
            #else
            return multiArray.withUnsafeBufferPointer(ofType: Float16.self) { $0.map(Float.init) }
            #endif
        default:
            throw SAM2SegmenterError.unexpectedModelOutput(
                "unsupported MLMultiArray dataType \(multiArray.dataType.rawValue)")
        }
    }

    /// Bilinearly upsamples a low-res logit plane to the target size and
    /// thresholds at 0 (SAM2 convention: logit > 0 means inside the mask).
    private static func upsampleAndThreshold(
        logits: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [Bool] {
        var pixels = [Bool](repeating: false, count: targetWidth * targetHeight)
        let xScale = Float(sourceWidth) / Float(targetWidth)
        let yScale = Float(sourceHeight) / Float(targetHeight)

        logits.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for ty in 0..<targetHeight {
                    // Align sample centers (the +0.5/-0.5 dance mirrors
                    // PyTorch's align_corners=false bilinear resize).
                    let sy = max(0, min(Float(sourceHeight) - 1, (Float(ty) + 0.5) * yScale - 0.5))
                    let y0 = Int(sy)
                    let y1 = min(y0 + 1, sourceHeight - 1)
                    let fy = sy - Float(y0)
                    let rowBase = ty * targetWidth
                    for tx in 0..<targetWidth {
                        let sx = max(0, min(Float(sourceWidth) - 1, (Float(tx) + 0.5) * xScale - 0.5))
                        let x0 = Int(sx)
                        let x1 = min(x0 + 1, sourceWidth - 1)
                        let fx = sx - Float(x0)

                        let top = src[y0 * sourceWidth + x0] * (1 - fx)
                            + src[y0 * sourceWidth + x1] * fx
                        let bottom = src[y1 * sourceWidth + x0] * (1 - fx)
                            + src[y1 * sourceWidth + x1] * fx
                        let value = top * (1 - fy) + bottom * fy
                        dst[rowBase + tx] = value > 0
                    }
                }
            }
        }
        return pixels
    }
}
