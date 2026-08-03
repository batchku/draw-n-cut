import CoreGraphics
import CoreML
import Foundation
import Testing
import simd
@testable import DrawNCut

/// True when the SAM 2 models are bundled with the host app (project.yml
/// adds Models/*.mlpackage, populated by scripts/download-models.sh).
/// A checkout without the weights skips these tests instead of failing.
private func samModelsBundled() -> Bool {
    guard let url = RefineMaskSession.modelsDirectory,
          let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)
    else { return false }
    let roles = ["ImageEncoder", "PromptEncoder", "MaskDecoder"]
    return roles.allSatisfy { role in
        contents.contains {
            ($0.pathExtension == "mlmodelc" || $0.pathExtension == "mlpackage")
                && $0.lastPathComponent.contains(role)
        }
    }
}

/// Exercises the real SAM 2 pipeline against the fish-photo fixture.
/// Serialized: the three models share compute; parallel loads only thrash.
@Suite(.serialized)
struct SAM2SegmenterTests {

    @Test(.enabled(if: samModelsBundled()))
    func fishBodyTapYieldsTightMask() async throws {
        let image = try FixtureTraceTests.fixtureImage("fish-photo", extension: "jpg")
        let directory = try #require(RefineMaskSession.modelsDirectory)
        let clock = ContinuousClock()

        var mark = clock.now
        let segmenter = try await SAM2Segmenter(
            modelsDirectory: directory, computeUnits: RefineMaskSession.preferredComputeUnits)
        let loadTime = clock.now - mark

        mark = clock.now
        try await segmenter.encode(image: image)
        let encodeTime = clock.now - mark

        // (500, 1030) on the fish body in 1500×2000 trace space, scaled to
        // the fixture's native pixels (1950×2600).
        let point = SIMD2(
            500.0 / 1500.0 * Double(image.width),
            1030.0 / 2000.0 * Double(image.height)
        )
        mark = clock.now
        let mask = try await segmenter.mask(points: [(point, true)])
        let decodeTime = clock.now - mark

        print("[sam-test] load=\(loadTime) encode=\(encodeTime) decode=\(decodeTime) inkFraction=\(mask.inkFraction)")

        #expect(mask.width == image.width && mask.height == image.height)

        #if targetEnvironment(simulator)
        // Known iOS-simulator Core ML defect (verified on the iOS 26.5
        // runtime; INTEGRATION.md "Simulator caveat"): the mask decoder
        // executes but returns all-zero mask logits, so the decode yields an
        // empty mask. The identical Swift + models + fixture + point produce
        // inkFraction ≈ 0.045 on macOS — run scripts/sam-macos-check/run.sh
        // for the strict assertion. When Apple fixes the runtime, the strict
        // path below takes over automatically.
        if mask.inkFraction == 0 {
            withKnownIssue("SAM2 mask decoder returns empty masks on the iOS simulator") {
                #expect(mask.inkFraction > 0.01, "empty mask (simulator Core ML defect)")
            }
            return
        }
        #endif

        // A subject hit is a tight mask; the known failure mode (paper or
        // shadow region) measures ~48% of the frame.
        #expect(mask.inkFraction > 0.01, "mask too small: \(mask.inkFraction)")
        #expect(mask.inkFraction < 0.30, "mask looks like a paper miss: \(mask.inkFraction)")

        // End-to-end shape: the mask bridges into trace space and yields a
        // closed sticker outline.
        let traceSpace = BinaryBitmap.traceSize(for: image)
        let bitmap = MaskGeometry.bitmap(from: mask, scaledTo: traceSpace)
        let outline = try #require(MaskGeometry.stickerOutline(around: bitmap, offsetPixels: 75))
        #expect(outline.isClosed)
        #expect(outline.points.count >= 8)
    }
}
