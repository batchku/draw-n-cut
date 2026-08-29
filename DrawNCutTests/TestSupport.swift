import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import DrawNCut

/// Writes a synthetic canvas to disk so a `TraceSession` can load it the way
/// the app does, instead of tests reaching past the store's file layout.
enum TestImageFile {
    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension TraceSession {
    /// Waits for the in-flight trace to land. Tracing is scheduled on a
    /// detached task, so `load()` and the sliders return well before the
    /// result exists; polling the session's own flag beats sleeping a
    /// guessed interval and keeps these tests deterministic.
    @MainActor
    func settle(timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        // isTracing is false before the first schedule runs too, so require a
        // result as well as quiescence.
        while ContinuousClock.now < deadline {
            if !isTracing, result != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TraceSettleTimeout()
    }
}

struct TraceSettleTimeout: Error, CustomStringConvertible {
    var description: String { "the trace did not finish in time" }
}
