import CoreGraphics
import Foundation
import ImageIO
import Observation
import simd

/// One saved trace version's content: the Detail setting plus the user's
/// erase shapes. Erasures are image-space regions rasterized into a mask
/// that is subtracted from the ink before every trace, so they survive
/// Detail changes exactly.
struct TraceSnapshot: Codable {
    var detail: Double
    /// Legacy format: [x, y] or [x, y, radius] hit-test taps. Still decoded
    /// (as brush dots) so old saved versions keep working.
    var eraseTaps: [[Double]] = []
    var eraseShapes: [EraseShape]? = nil
}

/// Drives the trace screen: owns the image, re-traces when Detail changes,
/// applies suggestions and erase taps, and saves/restores versions.
@MainActor
@Observable
final class TraceSession {
    struct TargetKey: Hashable {
        let elementIndex: Int
        let polylineIndex: Int
    }

    /// Offset of the sticker cut outline from the mask boundary, as a
    /// fraction of the image diagonal (≈7.5 mm on an A4-width drawing).
    nonisolated static let cutOutlineOffsetFraction = 0.03

    private let store: ProjectStore
    private(set) var project: DrawingProject
    private(set) var image: CGImage?
    private(set) var result: TraceResult?
    /// Subject mask in trace space; ink outside it is ignored while tracing.
    private var mask: BinaryBitmap?
    /// The sticker-style CUT outline around the piece. Derived from the
    /// subject mask when one exists, otherwise recomputed from the traced
    /// ink after every re-trace — either way it is a closed loop by
    /// construction. Not erasable: it is the piece's edge.
    private(set) var cutOutline: Polyline?
    /// The mask-derived outline, stable across re-traces; nil when the user
    /// traced everything and the outline instead follows the ink.
    private var subjectOutline: Polyline?
    private(set) var suggestionsByTarget: [TargetKey: RemovalReason] = [:]
    private(set) var removedTargets: Set<TargetKey> = []
    private(set) var isTracing = false
    private(set) var suggestionsApplied = false

    var detail: Double = 0.7 {
        didSet { if oldValue != detail { scheduleRetrace(debounce: true) } }
    }
    /// Every erase gesture, in image space. Rasterized into a mask and
    /// subtracted from the ink before each trace.
    private(set) var eraseShapes: [EraseShape] = []

    private var textRegions: [CGRect] = []
    private var retraceTask: Task<Void, Never>?

    init(project: DrawingProject, store: ProjectStore) {
        self.project = project
        self.store = store
    }

    // MARK: - Loading

    func load() async {
        let url = store.originalImageURL(for: project)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        // Bounded thumbnail decode: never materialize the full-resolution
        // photo in memory — an oversized stored image (or a future 48MP
        // camera) must not be able to run the app into the jetsam limit.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2000,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            TraceLog.log("load FAILED for \(url.lastPathComponent)", file: diagnosticsURL)
            return
        }
        TraceLog.log("loaded \(url.lastPathComponent) → \(cgImage.width)x\(cgImage.height)", file: diagnosticsURL)
        image = cgImage
        textRegions = []
        await loadMask(for: cgImage)
        scheduleRetrace(debounce: false)
        // Text detection is slower than tracing; fold results in when ready.
        let traceSpace = BinaryBitmap.traceSize(for: cgImage)
        if let regions = try? await TextDetector.textRegions(in: cgImage, scaledTo: traceSpace) {
            textRegions = regions
            refreshSuggestions()
        }
        // Start from the latest saved version when one exists.
        if let latest = project.activeTraceVersion {
            restore(latest)
        }
    }

    /// Reads the project's `mask.png` (written by the refine screen) into
    /// trace space and derives the sticker cut outline from it. No file, no
    /// mask: the whole photo traces, as before.
    private func loadMask(for cgImage: CGImage) async {
        let maskURL = store.maskURL(for: project)
        guard FileManager.default.fileExists(atPath: maskURL.path) else {
            mask = nil
            subjectOutline = nil
            cutOutline = nil
            return
        }
        let traceSpace = BinaryBitmap.traceSize(for: cgImage)
        let loaded = await Task.detached(priority: .userInitiated) { () -> (BinaryBitmap, Polyline?)? in
            guard let bitmap = MaskPNG.readBitmap(from: maskURL, scaledTo: traceSpace) else { return nil }
            let diagonal = Double(hypot(traceSpace.width, traceSpace.height))
            let offset = max(1, Int(Self.cutOutlineOffsetFraction * diagonal))
            return (bitmap, MaskGeometry.stickerOutline(around: bitmap, offsetPixels: offset))
        }.value
        mask = loaded?.0
        subjectOutline = loaded?.1
        cutOutline = loaded?.1
        TraceLog.log(
            "mask \(loaded == nil ? "FAILED to load" : "loaded"), cut outline \(cutOutline == nil ? "absent" : "\(cutOutline!.points.count) points")",
            file: diagnosticsURL
        )
    }

    // MARK: - Tracing

    private func scheduleRetrace(debounce: Bool) {
        guard let image else { return }
        retraceTask?.cancel()
        let detail = detail
        let regions = textRegions
        let mask = mask
        let shapes = eraseShapes
        let hasSubjectOutline = subjectOutline != nil
        isTracing = true
        retraceTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            // Trace, classify, and detect all off the main actor — in a debug
            // build this is seconds of work on a full-page scan.
            let computed = await Task.detached(priority: .userInitiated) { () -> (TraceResult, [TargetKey: RemovalReason], Polyline?)? in
                let traceSpace = BinaryBitmap.traceSize(for: image)
                let eraseMask = EraseMask.bitmap(
                    from: shapes, width: Int(traceSpace.width), height: Int(traceSpace.height))
                guard let traced = TraceEngine.trace(
                    image: image, mask: mask, eraseMask: eraseMask, detail: detail) else { return nil }
                let classification = ElementClassifier.classify(traced)
                let suggestions = NonSubjectDetector.suggestions(
                    for: classification,
                    imageSize: traced.imageSize,
                    textRegions: regions
                )
                // Without a subject mask the CUT outline follows whatever ink
                // survived erasing — recomputed here so it stays closed and
                // current after every change.
                let fallback = hasSubjectOutline ? nil : Self.inkOutline(for: traced)
                return (traced, Self.targets(for: suggestions, in: traced), fallback)
            }.value
            guard !Task.isCancelled, let self, let (traced, byTarget, fallback) = computed else { return }
            self.result = traced
            self.suggestionsByTarget = byTarget
            self.isTracing = false
            // The mask already excluded every erased region from this trace;
            // per-polyline removals were only instant feedback and would
            // otherwise hide freshly traced neighbors.
            self.removedTargets = []
            if self.subjectOutline == nil {
                self.cutOutline = fallback
            }
            self.logTraceOutcome(traced, suggestionCount: byTarget.count)
            // Text regions may have landed while this trace was running.
            if self.textRegions != regions {
                self.refreshSuggestions()
            }
        }
    }

    /// Sticker-style CUT outline around everything traced, used when no
    /// subject mask exists: rasterize the centerlines at pen width, grow by
    /// the offset, and contour — closed by construction, unlike any traced
    /// polyline.
    nonisolated private static func inkOutline(for result: TraceResult) -> Polyline? {
        let width = Int(result.imageSize.width), height = Int(result.imageSize.height)
        guard width > 0, height > 0 else { return nil }
        var bitmap = BinaryBitmap(width: width, height: height)
        var inked = false
        for element in result.elements {
            let radius = max(1.0, element.estimatedStrokeWidth / 2)
            for polyline in element.polylines {
                var points = polyline.points
                if polyline.isClosed, let first = points.first { points.append(first) }
                guard !points.isEmpty else { continue }
                EraseMask.stampStroke(points, radius: radius, into: &bitmap)
                inked = true
            }
        }
        guard inked else { return nil }
        let diagonal = Double(hypot(result.imageSize.width, result.imageSize.height))
        let offset = max(1, Int(cutOutlineOffsetFraction * diagonal))
        return MaskGeometry.stickerOutline(around: bitmap, offsetPixels: offset)
    }

    private var diagnosticsURL: URL {
        store.directory(for: project).appending(path: "diagnostics.log")
    }

    private func logTraceOutcome(_ traced: TraceResult, suggestionCount: Int) {
        var binarization = "binarization=?"
        if let report = traced.binarization {
            binarization = "ink=\(report.inkPixelCount) mask=\(report.paperMaskActive ? "on(\(Int(report.paperCoverage * 100))%)" : "off") sep=\(Int(report.otsuClassSeparation)) border=\(Int(report.paperSurroundContrast))"
        }
        let polylineCount = traced.elements.reduce(0) { $0 + $1.polylines.count }
        TraceLog.log(
            "traced detail=\(String(format: "%.2f", detail)) → \(traced.elements.count) elements, \(polylineCount) polylines, \(suggestionCount) suggestions | \(binarization)",
            file: diagnosticsURL
        )
        let visiblePolylines = visible.map(\.polyline)
        TracePreviewRenderer.write(
            polylines: visiblePolylines,
            imageSize: traced.imageSize,
            to: store.directory(for: project).appending(path: "trace-preview.png")
        )
    }

    nonisolated private static func targets(for suggestions: [RemovalSuggestion], in result: TraceResult) -> [TargetKey: RemovalReason] {
        var byTarget: [TargetKey: RemovalReason] = [:]
        let elementIndexByID = Dictionary(
            uniqueKeysWithValues: result.elements.enumerated().map { ($1.id, $0) }
        )
        for suggestion in suggestions {
            guard let elementIndex = elementIndexByID[suggestion.elementID] else { continue }
            if let polylineIndex = suggestion.polylineIndex {
                byTarget[TargetKey(elementIndex: elementIndex, polylineIndex: polylineIndex)] = suggestion.reason
            } else {
                for polylineIndex in result.elements[elementIndex].polylines.indices {
                    byTarget[TargetKey(elementIndex: elementIndex, polylineIndex: polylineIndex)] = suggestion.reason
                }
            }
        }
        return byTarget
    }

    // MARK: - Erasing

    /// The polyline nearest a tap, within a forgiving thumb radius.
    func target(near point: SIMD2<Double>) -> TargetKey? {
        guard let result else { return nil }
        let threshold = 0.025 * hypot(result.imageSize.width, result.imageSize.height)
        var best: (TargetKey, Double)?
        for (e, element) in result.elements.enumerated() {
            for (p, polyline) in element.polylines.enumerated() {
                var points = polyline.points
                if polyline.isClosed, let first = points.first { points.append(first) }
                guard points.count > 1 else { continue }
                for i in 0..<(points.count - 1) {
                    let d = PathGeometry.distanceToSegment(point, points[i], points[i + 1])
                    if d < (best?.1 ?? threshold) {
                        best = (TargetKey(elementIndex: e, polylineIndex: p), d)
                    }
                }
            }
        }
        return best?.0
    }

    /// Fingertip-sized eraser radius in image pixels at 1× zoom.
    var defaultEraserRadius: Double {
        guard let result else { return 60 }
        return 0.03 * hypot(result.imageSize.width, result.imageSize.height)
    }

    /// Every polyline within `radius` of a point — the eraser removes all of
    /// them, not just the nearest.
    private func targets(within radius: Double, of point: SIMD2<Double>) -> [TargetKey] {
        guard let result else { return [] }
        var hits: [TargetKey] = []
        for (e, element) in result.elements.enumerated() {
            for (p, polyline) in element.polylines.enumerated() {
                var points = polyline.points
                if polyline.isClosed, let first = points.first { points.append(first) }
                guard points.count > 1 else { continue }
                for i in 0..<(points.count - 1) {
                    if PathGeometry.distanceToSegment(point, points[i], points[i + 1]) <= radius {
                        hits.append(TargetKey(elementIndex: e, polylineIndex: p))
                        break
                    }
                }
            }
        }
        return hits
    }

    /// Lasso erase: everything inside the closed loop is masked out of the
    /// ink before every subsequent trace, so it stays erased at any Detail.
    /// Polylines mostly inside the loop disappear immediately for feedback;
    /// the masked re-trace is authoritative.
    func eraseLasso(points: [SIMD2<Double>]) {
        guard points.count >= 3 else { return }
        eraseShapes.append(.lasso(points: points))
        if let result {
            for (e, element) in result.elements.enumerated() {
                for (p, polyline) in element.polylines.enumerated() {
                    let inside = polyline.points.count { PathGeometry.polygon(points, contains: $0) }
                    if inside * 2 > polyline.points.count {
                        removedTargets.insert(TargetKey(elementIndex: e, polylineIndex: p))
                    }
                }
            }
        }
        scheduleRetrace(debounce: true)
    }

    /// Spot erase (a tap): a brush dot into the mask, with instant
    /// polyline-level feedback like the lasso.
    func eraseSpot(at point: SIMD2<Double>, radius: Double) {
        eraseShapes.append(.brush(points: [point], radius: radius))
        for key in targets(within: radius, of: point) {
            removedTargets.insert(key)
        }
        scheduleRetrace(debounce: true)
    }

    func undoErase() {
        guard !eraseShapes.isEmpty else { return }
        eraseShapes.removeLast()
        suggestionsApplied = false
        scheduleRetrace(debounce: false)
    }

    func resetErases() {
        eraseShapes.removeAll()
        suggestionsApplied = false
        scheduleRetrace(debounce: false)
    }

    /// Recomputes suggestions off-main against the existing trace result
    /// (used when text regions arrive after the trace).
    private func refreshSuggestions() {
        guard let result else { return }
        let regions = textRegions
        Task { [weak self] in
            let byTarget = await Task.detached(priority: .utility) { () -> [TargetKey: RemovalReason] in
                let classification = ElementClassifier.classify(result)
                let suggestions = NonSubjectDetector.suggestions(
                    for: classification,
                    imageSize: result.imageSize,
                    textRegions: regions
                )
                return Self.targets(for: suggestions, in: result)
            }.value
            guard let self else { return }
            self.suggestionsByTarget = byTarget
        }
    }

    /// Accepts every current suggestion by brushing its centerline into the
    /// erase mask (so it persists across re-traces and into versions).
    func applySuggestions() {
        guard let result else { return }
        for key in suggestionsByTarget.keys where !removedTargets.contains(key) {
            let element = result.elements[key.elementIndex]
            let polyline = element.polylines[key.polylineIndex]
            var points = polyline.points
            if polyline.isClosed, let first = points.first { points.append(first) }
            guard !points.isEmpty else { continue }
            // A little wider than the pen so threshold flicker along the
            // mark can't leave residue, but tight enough to spare neighbors.
            let radius = max(3, 1.5 * element.estimatedStrokeWidth)
            eraseShapes.append(.brush(points: points, radius: radius))
            removedTargets.insert(key)
        }
        suggestionsApplied = true
        scheduleRetrace(debounce: false)
    }

    // MARK: - Versions

    func saveVersion() throws {
        let snapshot = TraceSnapshot(detail: detail, eraseShapes: eraseShapes)
        let data = try JSONEncoder().encode(snapshot)
        _ = try store.addTraceVersion(to: project, detail: detail, pathsData: data)
        syncProject()
    }

    func restore(_ version: TraceVersion) {
        let url = store.tracePathsURL(for: version, in: project)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TraceSnapshot.self, from: data) else { return }
        if let shapes = snapshot.eraseShapes {
            eraseShapes = shapes
        } else {
            // Legacy snapshots stored hit-test taps ([x, y] or [x, y, radius]);
            // a brush dot at the same spot erases the same mark's ink.
            eraseShapes = snapshot.eraseTaps.compactMap { values in
                guard values.count >= 2 else { return nil }
                let radius = values.count >= 3 ? values[2] : defaultEraserRadius
                return .brush(points: [SIMD2(values[0], values[1])], radius: radius)
            }
        }
        try? store.setActiveTraceVersion(version, in: project)
        syncProject()
        if detail == snapshot.detail {
            scheduleRetrace(debounce: false)
        } else {
            detail = snapshot.detail   // triggers retrace
        }
    }

    private func syncProject() {
        if let updated = store.projects.first(where: { $0.id == project.id }) {
            project = updated
        }
    }

    // MARK: - Visible output

    /// Polylines that survive erasure, with any pending suggestion reason.
    var visible: [(key: TargetKey, polyline: Polyline, suggestion: RemovalReason?)] {
        guard let result else { return [] }
        var output: [(TargetKey, Polyline, RemovalReason?)] = []
        for (e, element) in result.elements.enumerated() {
            for (p, polyline) in element.polylines.enumerated() {
                let key = TargetKey(elementIndex: e, polylineIndex: p)
                guard !removedTargets.contains(key) else { continue }
                output.append((key, polyline, suggestionsByTarget[key]))
            }
        }
        return output
    }

    var pendingSuggestionCount: Int {
        suggestionsByTarget.keys.count { !removedTargets.contains($0) }
    }

    // MARK: - Export

    /// Writes the current visible trace as a DXF sized to `widthMM`, returns
    /// the file URL. The sticker outline (when present) lands on the CUT
    /// layer; everything traced engraves. Per-path overrides are a later task.
    func exportDXF(widthMM: Double) throws -> URL {
        let polylines = visible.map(\.polyline)
        let dxf = DXFExportBuilder.dxf(from: polylines, cutOutline: cutOutline, widthMM: widthMM)
        let directory = store.exportsDirectory(for: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
        let url = directory.appending(path: "\(project.title.replacingOccurrences(of: " ", with: "-"))-\(existing + 1).dxf")
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
