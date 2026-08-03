// sam-macos-check — proves the SAM 2 pipeline works on this machine.
//
// The iOS *simulator's* Core ML runtime returns all-zero mask logits from
// the SAM 2.1 mask decoder (see DrawNCut/Segmentation/INTEGRATION.md), so
// the simulator test suite can't validate mask quality. This harness runs
// the exact same SAM2Segmenter.swift against the same Models/ and fixture
// on macOS, where the decoder works, and fails (exit 1) unless a fish-body
// tap yields a plausible subject mask (ink fraction 1%–30%).
//
// Run with: scripts/sam-macos-check/run.sh

import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("usage: sam-macos-check <models-dir> <fish-photo.jpg>\n", stderr)
    exit(2)
}
let modelsURL = URL(filePath: arguments[1])
let imageURL = URL(filePath: arguments[2])

guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("could not load \(imageURL.path)\n", stderr)
    exit(2)
}

let semaphore = DispatchSemaphore(value: 0)
var failed = true
Task {
    defer { semaphore.signal() }
    do {
        let clock = ContinuousClock()
        var mark = clock.now
        let segmenter = try await SAM2Segmenter(modelsDirectory: modelsURL, computeUnits: .cpuAndGPU)
        let loadTime = clock.now - mark

        mark = clock.now
        try await segmenter.encode(image: image)
        let encodeTime = clock.now - mark

        // (500, 1030) on the fish body in 1500×2000 trace space.
        let point = SIMD2(
            500.0 / 1500.0 * Double(image.width),
            1030.0 / 2000.0 * Double(image.height))
        mark = clock.now
        let mask = try await segmenter.mask(points: [(point, true)])
        let decodeTime = clock.now - mark

        print("load=\(loadTime) encode=\(encodeTime) decode=\(decodeTime)")
        print("point=\(point) inkFraction=\(mask.inkFraction)")
        if mask.inkFraction > 0.01 && mask.inkFraction < 0.30 {
            print("OK: fish-body tap yields a plausible subject mask")
            failed = false
        } else {
            fputs("FAIL: ink fraction \(mask.inkFraction) outside (0.01, 0.30)\n", stderr)
        }
    } catch {
        fputs("FAIL: \(error)\n", stderr)
    }
}
semaphore.wait()
exit(failed ? 1 : 0)
