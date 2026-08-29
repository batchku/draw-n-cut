import CoreGraphics
import Foundation
import ImageIO

/// Builds a library thumbnail for a project that has not been opened since
/// thumbnails existed.
///
/// The trace screen rewrites the thumbnail after every trace, but that only
/// ever covers drawings the user visits. Every drawing made before the
/// feature shipped would otherwise sit on a placeholder icon forever, which
/// is exactly how the library first looked: every row blank.
///
/// A full trace is far too expensive to run for a whole library, so this
/// works at a fraction of the resolution. At a 56pt row the difference is
/// invisible, and it turns a multi-second job per drawing into a brief one.
enum ThumbnailBuilder {
    /// Longest edge the photo is decoded to before tracing. The trace
    /// pipeline is O(pixels) at every stage, so this is what makes a
    /// whole-library backfill affordable.
    static let traceDimension = 700

    /// True when `project.json` has moved on since the thumbnail was written
    /// (or there is no thumbnail at all).
    static func isStale(thumbnail: URL, project updatedAt: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: thumbnail.path),
              let written = attributes[.modificationDate] as? Date else { return true }
        return written < updatedAt
    }

    /// Traces `photoURL` small and writes the composited thumbnail.
    /// Returns false when there is no photo to work from; a photo that traces
    /// to nothing still produces a thumbnail, because the photograph alone
    /// identifies a drawing far better than a placeholder icon does.
    @discardableResult
    nonisolated static func build(
        photoURL: URL, maskURL: URL?, settings: TraceSnapshot?, to url: URL
    ) -> Bool {
        guard let photo = decode(photoURL, maxPixelSize: traceDimension) else { return false }

        let detail = settings?.detail ?? 0.7
        let smoothness = settings?.smoothness ?? TraceParameters.defaultSmoothness
        let threshold = settings?.threshold ?? BinaryBitmap.defaultThreshold

        let traceSpace = BinaryBitmap.traceSize(for: photo)
        var mask: BinaryBitmap?
        if let maskURL, FileManager.default.fileExists(atPath: maskURL.path) {
            mask = MaskPNG.readBitmap(from: maskURL, scaledTo: traceSpace)
        }

        let traced = TraceEngine.trace(
            image: photo, mask: mask, detail: detail,
            smoothness: smoothness, threshold: threshold)

        let engrave = traced?.elements.flatMap(\.polylines) ?? []
        // The cut outline is the mask's own boundary, the same as the trace
        // screen derives — at thumbnail size a plain contour reads correctly.
        let cuts: [Polyline] = mask.flatMap { MaskGeometry.outerContour(of: $0) }.map { [$0] } ?? []
        let imageSize = traced?.imageSize
            ?? CGSize(width: photo.width, height: photo.height)

        ThumbnailRenderer.write(
            photo: photo, engrave: engrave, cuts: cuts,
            imageSize: imageSize, subject: mask, to: url)
        return true
    }

    /// The settings the drawing was last traced with, so its thumbnail shows
    /// what the user last saw rather than a default trace.
    nonisolated static func settings(atVersionPath url: URL?) -> TraceSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TraceSnapshot.self, from: data)
    }

    nonisolated private static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}
