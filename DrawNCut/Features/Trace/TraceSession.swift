import CoreGraphics
import Foundation
import ImageIO
import Observation
import simd

/// One saved trace version's content: the Detail setting plus the user's
/// erase taps. Erasures are stored as image-space points and re-applied by
/// hit-testing after every re-trace, so they survive Detail changes.
struct TraceSnapshot: Codable {
    var detail: Double
    var eraseTaps: [[Double]]
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
    private(set) var suggestionsByTarget: [TargetKey: RemovalReason] = [:]
    private(set) var removedTargets: Set<TargetKey> = []
    private(set) var isTracing = false
    private(set) var suggestionsApplied = false

    var detail: Double = 0.7 {
        didSet { if oldValue != detail { scheduleRetrace(debounce: true) } }
    }
    private(set) var eraseTaps: [SIMD2<Double>] = []

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

    // MARK: - Tracing

    private func scheduleRetrace(debounce: Bool) {
        guard let image else { return }
        retraceTask?.cancel()
        let detail = detail
        let regions = textRegions
        isTracing = true
        retraceTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            // Trace, classify, and detect all off the main actor — in a debug
            // build this is seconds of work on a full-page scan.
            let computed = await Task.detached(priority: .userInitiated) { () -> (TraceResult, [TargetKey: RemovalReason])? in
                guard let traced = TraceEngine.trace(image: image, detail: detail) else { return nil }
                let classification = ElementClassifier.classify(traced)
                let suggestions = NonSubjectDetector.suggestions(
                    for: classification,
                    imageSize: traced.imageSize,
                    textRegions: regions
                )
                return (traced, Self.targets(for: suggestions, in: traced))
            }.value
            guard !Task.isCancelled, let self, let (traced, byTarget) = computed else { return }
            self.result = traced
            self.suggestionsByTarget = byTarget
            self.isTracing = false
            self.reapplyErasures()
            self.logTraceOutcome(traced, suggestionCount: byTarget.count)
            // Text regions may have landed while this trace was running.
            if self.textRegions != regions {
                self.refreshSuggestions()
            }
        }
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

    /// Re-applies erase taps against the current trace result.
    private func reapplyErasures() {
        removedTargets = Set(eraseTaps.compactMap { target(near: $0) })
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

    func erase(at point: SIMD2<Double>) {
        guard target(near: point) != nil else { return }
        eraseTaps.append(point)
        reapplyErasures()
    }

    func undoErase() {
        guard !eraseTaps.isEmpty else { return }
        eraseTaps.removeLast()
        suggestionsApplied = false
        reapplyErasures()
    }

    func resetErases() {
        eraseTaps.removeAll()
        suggestionsApplied = false
        reapplyErasures()
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
            self.reapplyErasures()
        }
    }

    /// Accepts every current suggestion by converting it into an erase tap on
    /// the target polyline (so it persists across re-traces and into versions).
    func applySuggestions() {
        guard let result else { return }
        for key in suggestionsByTarget.keys where !removedTargets.contains(key) {
            let polyline = result.elements[key.elementIndex].polylines[key.polylineIndex]
            let mid = polyline.points[polyline.points.count / 2]
            eraseTaps.append(mid)
        }
        suggestionsApplied = true
        reapplyErasures()
    }

    // MARK: - Versions

    func saveVersion() throws {
        let snapshot = TraceSnapshot(detail: detail, eraseTaps: eraseTaps.map { [$0.x, $0.y] })
        let data = try JSONEncoder().encode(snapshot)
        _ = try store.addTraceVersion(to: project, detail: detail, pathsData: data)
        syncProject()
    }

    func restore(_ version: TraceVersion) {
        let url = store.tracePathsURL(for: version, in: project)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TraceSnapshot.self, from: data) else { return }
        eraseTaps = snapshot.eraseTaps.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
        try? store.setActiveTraceVersion(version, in: project)
        syncProject()
        if detail == snapshot.detail {
            reapplyErasures()
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
    /// the file URL. All paths engrave for now; the cut outline arrives with
    /// SAM mask integration, and per-path overrides with the toggle UI task.
    func exportDXF(widthMM: Double) throws -> URL {
        let polylines = visible.map(\.polyline)
        let dxf = DXFExportBuilder.dxf(from: polylines, widthMM: widthMM)
        let directory = store.exportsDirectory(for: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
        let url = directory.appending(path: "\(project.title.replacingOccurrences(of: " ", with: "-"))-\(existing + 1).dxf")
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
