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
    var outlineDetail: Double? = nil
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

    private let store: ProjectStore
    private(set) var project: DrawingProject
    private(set) var image: CGImage?
    private(set) var result: TraceResult?
    /// Subject mask in trace space; ink outside it is ignored while tracing.
    private var mask: BinaryBitmap?
    /// The CUT boundaries: the segmentation mask's silhouette — one closed
    /// loop per mask region plus one per enclosed hole, all raster contours
    /// and therefore closed by construction. Empty when the project has no
    /// mask; the outline comes from segmentation or not at all. Not
    /// erasable: they are the piece's edges.
    private(set) var cutOutlines: [Polyline] = []
    private(set) var suggestionsByTarget: [TargetKey: RemovalReason] = [:]
    private(set) var removedTargets: Set<TargetKey> = []
    /// Traced polylines that just re-draw the cut outline (the figure's own
    /// silhouette stroke). The laser already cuts there; engraving them too
    /// would double-burn the piece's edge, so they are hidden from output.
    private(set) var outlineTargets: Set<TargetKey> = []
    private(set) var isTracing = false
    private(set) var suggestionsApplied = false

    var detail: Double = 0.7 {
        didSet { if oldValue != detail { scheduleRetrace(debounce: true) } }
    }
    /// Fidelity of the cut outline to the mask boundary: 1 follows every
    /// bump the segmenter saw, 0 is a heavily smoothed silhouette.
    var outlineDetail: Double = 0.7 {
        didSet { if oldValue != outlineDetail { scheduleOutlineRefresh() } }
    }
    var hasSubjectMask: Bool { mask != nil }
    /// Every erase gesture, in image space. Rasterized into a mask and
    /// subtracted from the ink before each trace.
    private(set) var eraseShapes: [EraseShape] = []

    private var textRegions: [CGRect] = []
    private var retraceTask: Task<Void, Never>?
    private var outlineTask: Task<Void, Never>?

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
            cutOutlines = []
            return
        }
        let traceSpace = BinaryBitmap.traceSize(for: cgImage)
        let fidelity = outlineDetail
        let loaded = await Task.detached(priority: .userInitiated) { () -> (BinaryBitmap, [Polyline])? in
            guard let bitmap = MaskPNG.readBitmap(from: maskURL, scaledTo: traceSpace) else { return nil }
            // The cut runs exactly on the subject's silhouette — the mask
            // boundary IS the figure's edge (the deer's outline). Raster
            // contours, so every loop is closed no matter what.
            return (bitmap, Self.outlines(of: bitmap, fidelity: fidelity))
        }.value
        mask = loaded?.0
        cutOutlines = loaded?.1 ?? []
        TraceLog.log(
            "mask \(loaded == nil ? "FAILED to load" : "loaded"), \(cutOutlines.count) cut loop(s), \(cutOutlines.reduce(0) { $0 + $1.points.count }) points",
            file: diagnosticsURL
        )
    }

    /// Re-reads `mask.png` and re-traces. The refine screen may have
    /// rewritten or deleted the mask while this screen sat lower in the
    /// navigation stack — popping back must pick that up.
    func reloadMask() async {
        guard let image else { return }
        await loadMask(for: image)
        scheduleRetrace(debounce: false)
    }

    // MARK: - Tracing

    private func scheduleRetrace(debounce: Bool) {
        guard let image else { return }
        retraceTask?.cancel()
        let detail = detail
        let regions = textRegions
        let mask = mask
        let shapes = eraseShapes
        let outlines = cutOutlines
        isTracing = true
        retraceTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            // Trace, classify, and detect all off the main actor — in a debug
            // build this is seconds of work on a full-page scan.
            let computed = await Task.detached(priority: .userInitiated) { () -> (TraceResult, [TargetKey: RemovalReason], Set<TargetKey>)? in
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
                let coincident = Self.coincidentTargets(in: traced, outlines: outlines)
                return (traced, Self.targets(for: suggestions, in: traced), coincident)
            }.value
            guard !Task.isCancelled, let self, let (traced, byTarget, coincident) = computed else { return }
            self.result = traced
            self.suggestionsByTarget = byTarget
            self.isTracing = false
            // The mask already excluded every erased region from this trace;
            // per-polyline removals were only instant feedback and would
            // otherwise hide freshly traced neighbors.
            self.removedTargets = []
            self.outlineTargets = coincident
            self.logTraceOutcome(traced, suggestionCount: byTarget.count)
            // Text regions may have landed while this trace was running.
            if self.textRegions != regions {
                self.refreshSuggestions()
            }
        }
    }

    /// The mask boundary as closed loops (regions + holes), at a given
    /// fidelity. 1 hugs every raster bump the segmenter produced; 0
    /// simplifies and smooths hard.
    nonisolated private static func outlines(of mask: BinaryBitmap, fidelity: Double) -> [Polyline] {
        let f = max(0, min(1, fidelity))
        return MaskGeometry.cutContours(
            of: mask,
            simplifyTolerance: 8 - (8 - 0.75) * f,
            smoothingPasses: f < 0.5 ? 2 : 1
        )
    }

    /// Recomputes the cut outline (and which traced lines it makes
    /// redundant) when the Outline slider moves.
    private func scheduleOutlineRefresh() {
        guard let mask else { return }
        outlineTask?.cancel()
        let fidelity = outlineDetail
        let result = result
        outlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let computed = await Task.detached(priority: .userInitiated) { () -> ([Polyline], Set<TargetKey>) in
                let outlines = Self.outlines(of: mask, fidelity: fidelity)
                var coincident: Set<TargetKey> = []
                if let result {
                    coincident = Self.coincidentTargets(in: result, outlines: outlines)
                }
                return (outlines, coincident)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.cutOutlines = computed.0
            self.outlineTargets = computed.1
        }
    }

    /// Polylines that run along a cut loop — the figure's silhouette stroke
    /// re-traced as ink. Most of their length sits within a pen width of a
    /// cut path, so cutting already renders them.
    nonisolated private static func coincidentTargets(
        in result: TraceResult, outlines: [Polyline]
    ) -> Set<TargetKey> {
        let edges: [[SIMD2<Double>]] = outlines.compactMap { outline in
            var edge = outline.points
            if outline.isClosed, let first = edge.first { edge.append(first) }
            return edge.count > 1 ? edge : nil
        }
        guard !edges.isEmpty else { return [] }

        func isNear(_ point: SIMD2<Double>, within distance: Double) -> Bool {
            for edge in edges {
                for i in 0..<(edge.count - 1)
                where PathGeometry.distanceToSegment(point, edge[i], edge[i + 1]) <= distance {
                    return true
                }
            }
            return false
        }

        var coincident: Set<TargetKey> = []
        for (e, element) in result.elements.enumerated() {
            let distance = max(6.0, 2.0 * element.estimatedStrokeWidth)
            for (p, polyline) in element.polylines.enumerated() {
                guard !polyline.points.isEmpty else { continue }
                let near = polyline.points.count { isNear($0, within: distance) }
                if 10 * near >= 8 * polyline.points.count {
                    coincident.insert(TargetKey(elementIndex: e, polylineIndex: p))
                }
            }
        }
        return coincident
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
        let snapshot = TraceSnapshot(
            detail: detail, eraseShapes: eraseShapes, outlineDetail: outlineDetail)
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
        if let restored = snapshot.outlineDetail {
            outlineDetail = restored   // triggers outline refresh when changed
        }
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
                guard !removedTargets.contains(key), !outlineTargets.contains(key) else { continue }
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
        let dxf = DXFExportBuilder.dxf(from: polylines, cutOutlines: cutOutlines, widthMM: widthMM)
        let directory = store.exportsDirectory(for: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
        let url = directory.appending(path: "\(project.title.replacingOccurrences(of: " ", with: "-"))-\(existing + 1).dxf")
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
