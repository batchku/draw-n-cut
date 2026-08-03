import CoreGraphics
import Foundation
import ImageIO
import os

/// Pipeline diagnostics, mirrored three ways so the state of the app is
/// observable from a connected Mac:
/// - os.Logger → Console.app / `log` tooling
/// - stdout → visible live via `devicectl device process launch --console`
/// - per-project `diagnostics.log` → pulled with the Documents folder
enum TraceLog {
    private static let logger = Logger(subsystem: "com.alimomeni.drawncut", category: "pipeline")

    static func log(_ message: String, file fileURL: URL? = nil) {
        logger.info("\(message, privacy: .public)")
        print("[trace] \(message)")
        guard let fileURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

/// Renders the current trace to a small PNG next to the project's photo, so a
/// Documents pull shows exactly what the user's screen showed.
enum TracePreviewRenderer {
    static func write(polylines: [Polyline], imageSize: CGSize, to url: URL) {
        let maxSide = 900.0
        let scale = maxSide / max(imageSize.width, imageSize.height)
        let w = max(1, Int(imageSize.width * scale))
        let h = max(1, Int(imageSize.height * scale))
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(1.5)
        for polyline in polylines {
            guard let first = polyline.points.first else { continue }
            // Flip y: trace space is y-down, CGContext is y-up.
            context.move(to: CGPoint(x: first.x * scale, y: Double(h) - first.y * scale))
            for point in polyline.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * scale, y: Double(h) - point.y * scale))
            }
            if polyline.isClosed { context.closePath() }
            context.strokePath()
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
