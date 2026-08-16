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
    var outlineSmoothness: Double? = nil
    var smoothness: Double? = nil
    /// Legacy format: cut-promotion taps as [x, y], in tap order. Still
    /// decoded — each surviving tap converts into a frozen promotion once,
    /// against the restored trace.
    var cutTaps: [[Double]]? = nil
    /// Frozen tap-promoted cut lines: exact geometry, no tap replay.
    var promotedCuts: [SnapshotPolyline]? = nil
    /// Frozen point-edited geometry, when the user reshaped the trace.
    var editedPaths: [SnapshotEditedPath]? = nil
    /// True once frozen geometry also carries the cut outline (older
    /// versions saved traced paths only).
    var editedPathsIncludeOutlines: Bool? = nil
}

/// One frozen polyline as saved in a version: raw points plus closure.
struct SnapshotPolyline: Codable {
    var points: [[Double]]
    var isClosed: Bool
}

/// One point-edited path as saved in a version: raw points, closure, role.
struct SnapshotEditedPath: Codable {
    var points: [[Double]]
    var isClosed: Bool
    var isCut: Bool
}

/// One path in point-edit space: geometry frozen from the live trace the
/// moment editing starts. From then on this is what renders and exports,
/// until a re-trace (slider or eraser change) resets it.
struct EditablePath: Equatable {
    var polyline: Polyline
    var isCut: Bool
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
    /// The photo's binarized ink in trace space, kept while a mask exists so
    /// outline recomputation can snap the cut to the drawn stroke.
    private var snapInk: BinaryBitmap?
    /// The CUT boundaries: the segmentation mask's silhouette — one closed
    /// loop per mask region plus one per enclosed hole, all raster contours
    /// and therefore closed by construction. Empty when the project has no
    /// mask; the outline comes from segmentation or not at all. Not
    /// erasable: they are the piece's edges.
    private(set) var cutOutlines: [Polyline] = []
    /// The mask silhouette at FIXED fidelity, computed once per mask load —
    /// the slider-independent reference for deciding which traced lines just
    /// re-draw the cut. Moving the Cut sliders reshapes `cutOutlines` only;
    /// it must never flicker blue lines in and out.
    private var referenceOutlines: [Polyline] = []
    private(set) var suggestionsByTarget: [TargetKey: RemovalReason] = [:]
    private(set) var removedTargets: Set<TargetKey> = []
    /// Traced polylines that just re-draw the cut outline (the figure's own
    /// silhouette stroke). The laser already cuts there; engraving them too
    /// would double-burn the piece's edge, so they are hidden from output.
    private(set) var outlineTargets: Set<TargetKey> = []
    /// Cut lines the user promoted by tapping engrave lines: FROZEN copies,
    /// owned by the cut world like the outline. Re-tracing (engrave sliders)
    /// never reshapes them; the traced source line underneath stays hidden
    /// via `promotedSourceTargets`.
    private(set) var promotedCuts: [Polyline] = []
    /// Traced polylines hidden because a frozen promotion covers them —
    /// recomputed against `promotedCuts` after every re-trace (keys change),
    /// and immediately on promote/demote.
    private var promotedSourceTargets: Set<TargetKey> = []
    /// Legacy cut taps from an old saved version, converted into frozen
    /// promotions exactly once, when the restore's re-trace lands.
    private var pendingLegacyCutTaps: [SIMD2<Double>]?
    /// Frozen, user-editable geometry (nil while the trace is live). Once
    /// set, it is the source of truth for rendering and export; a re-trace
    /// discards it — point surgery is the last step, after the sliders.
    private(set) var editedPaths: [EditablePath]?
    /// Edits restored from a saved version, applied when the restore's own
    /// re-trace finishes (which would otherwise clear them).
    private var pendingRestoredEdits: [EditablePath]?
    /// Undo for frozen-geometry gestures (a point drag, a join, one brush
    /// stroke): each completed gesture that changed anything pushes the
    /// prior state; one undo pops one gesture. Cleared on re-trace.
    private(set) var editUndoStack: [[EditablePath]] = []
    /// Set at gesture start, promoted to the stack on the gesture's first
    /// actual mutation — a drag that grabs nothing never records an undo.
    private var pendingUndoSnapshot: [EditablePath]?
    private(set) var isTracing = false
    private(set) var suggestionsApplied = false

    var detail: Double = 0.7 {
        didSet { if oldValue != detail { scheduleRetrace(debounce: true) } }
    }
    /// How the engrave lines are drawn: 0 follows the raster faithfully
    /// (jagged), 1 simplifies and rounds hard. Separate from Detail, which
    /// decides what survives.
    var smoothness: Double = TraceParameters.defaultSmoothness {
        didSet { if oldValue != smoothness { scheduleRetrace(debounce: true) } }
    }
    /// Fidelity of the cut outline to the mask boundary: 1 follows every
    /// bump the segmenter saw, 0 is a heavily simplified silhouette.
    var outlineDetail: Double = 0.7 {
        didSet { if oldValue != outlineDetail { scheduleOutlineRefresh() } }
    }
    /// How the cut outline is drawn: 0 keeps raw corners, 1 rounds hard —
    /// the cut-side twin of the engrave `smoothness`.
    var outlineSmoothness: Double = TraceParameters.defaultSmoothness {
        didSet { if oldValue != outlineSmoothness { scheduleOutlineRefresh() } }
    }
    var hasSubjectMask: Bool { mask != nil }
    /// Every erase gesture, in image space. Rasterized into a mask and
    /// subtracted from the ink before each trace.
    private(set) var eraseShapes: [EraseShape] = []
    /// Undo granularity: each user action (one lasso, one spot, one
    /// suggestions-Apply) contributes one batch of shapes; undo removes a
    /// whole batch — pressing undo after Apply brings ALL its lines back.
    private var eraseBatchSizes: [Int] = []

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
            snapInk = nil
            cutOutlines = []
            referenceOutlines = []
            return
        }
        let traceSpace = BinaryBitmap.traceSize(for: cgImage)
        let detail = outlineDetail
        let smoothness = outlineSmoothness
        let loaded = await Task.detached(priority: .userInitiated) { () -> (BinaryBitmap, BinaryBitmap?, [Polyline], [Polyline])? in
            guard let bitmap = MaskPNG.readBitmap(from: maskURL, scaledTo: traceSpace) else { return nil }
            // The cut runs exactly on the subject's silhouette — the mask
            // boundary IS the figure's edge (the deer's outline). Raster
            // contours, so every loop is closed no matter what. Where the
            // segmenter's edge strays off the pen line, snapping pulls the
            // cut back onto the drawing's own stroke.
            let ink = BinaryBitmap(cgImage: cgImage)
            let displayed = Self.outlines(
                of: bitmap, snappedTo: ink, detail: detail, smoothness: smoothness)
            // The fixed-fidelity reference for coincident-line hiding: the
            // Cut sliders never touch it, so which blue lines the outline
            // makes redundant is invariant under them.
            let reference = Self.outlines(
                of: bitmap, snappedTo: ink,
                detail: 0.7, smoothness: TraceParameters.defaultSmoothness)
            return (bitmap, ink, displayed, reference)
        }.value
        mask = loaded?.0
        snapInk = loaded?.1
        cutOutlines = loaded?.2 ?? []
        referenceOutlines = loaded?.3 ?? []
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
        let smoothness = smoothness
        let regions = textRegions
        let mask = mask
        let shapes = eraseShapes
        let outlines = referenceOutlines
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
                    image: image, mask: mask, eraseMask: eraseMask,
                    detail: detail, smoothness: smoothness) else { return nil }
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
            // Frozen promotions survive untouched; only the hidden traced
            // twins are re-derived against the fresh keys.
            self.refreshPromotedSourceTargets()
            // Legacy saved versions stored taps, not geometry: convert each
            // surviving tap into a frozen promotion once, right here against
            // the restored trace.
            if let taps = self.pendingLegacyCutTaps {
                self.pendingLegacyCutTaps = nil
                for tap in taps { self.toggleCut(at: tap) }
            }
            // A fresh trace supersedes point surgery — except when this trace
            // was triggered by a version restore carrying its own edits.
            self.editedPaths = self.pendingRestoredEdits
            self.pendingRestoredEdits = nil
            // The undo stack narrates one frozen-geometry session; a re-trace
            // starts a new one — undo must never resurrect stale geometry.
            self.editUndoStack = []
            self.pendingUndoSnapshot = nil
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
    nonisolated private static func outlines(
        of mask: BinaryBitmap, snappedTo ink: BinaryBitmap?, detail: Double, smoothness: Double
    ) -> [Polyline] {
        let d = max(0, min(1, detail))
        let s = max(0, min(1, smoothness))
        let diagonal = Double(mask.width * mask.width + mask.height * mask.height).squareRoot()
        // Piecewise-linear through the default look at detail 0.7; the
        // coarse end doubled so the slider's range is unmistakable.
        let tolerance = d <= 0.7
            ? 16 + (2.9 - 16) * (d / 0.7)
            : 2.9 + (0.5 - 2.9) * ((d - 0.7) / 0.3)
        return MaskGeometry.cutContours(
            of: mask,
            snappedTo: ink,
            // Big enough to bridge the segmenter's worst wander (measured
            // ~50px at a 2500px diagonal), small enough not to reach interior
            // features like an eye.
            snapDistance: 0.02 * diagonal,
            simplifyTolerance: tolerance,
            smoothingPasses: s < 0.2 ? 0 : s < 0.6 ? 1 : s < 0.85 ? 2 : 3
        )
    }

    /// Recomputes the cut outline when a Cut slider moves. ONLY the red
    /// outline: which blue lines it hides (`outlineTargets`) is derived from
    /// the fixed-fidelity `referenceOutlines`, so the Cut sliders can never
    /// flicker engrave lines or promotions.
    private func scheduleOutlineRefresh() {
        guard let mask else { return }
        outlineTask?.cancel()
        let detail = outlineDetail
        let smoothness = outlineSmoothness
        let ink = snapInk
        outlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let outlines = await Task.detached(priority: .userInitiated) {
                Self.outlines(of: mask, snappedTo: ink, detail: detail, smoothness: smoothness)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.cutOutlines = outlines
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
            binarization = "ink=\(report.inkPixelCount) mask=\(report.paperMaskActive ? "on(\(Int(report.paperCoverage * 100))%)" : "off") sep=\(Int(report.otsuClassSeparation)) border=\(Int(report.paperSurroundContrast)) edge=\(Int(report.paperEdgeSharpness))"
        }
        let polylineCount = traced.elements.reduce(0) { $0 + $1.polylines.count }
        TraceLog.log(
            "traced detail=\(String(format: "%.2f", detail)) smooth=\(String(format: "%.2f", smoothness)) → \(traced.elements.count) elements, \(polylineCount) polylines, \(suggestionCount) suggestions | \(binarization)",
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

    // MARK: - Cut promotion

    /// Toggles the tapped engrave line between engrave (blue) and cut (red).
    /// Promotion FREEZES: the tapped polyline's current geometry is copied
    /// into `promotedCuts` — owned by the cut world from then on, immune to
    /// the Engrave sliders — and its traced source hides. Tapping the frozen
    /// red line again demotes it: the copy is dropped and the source shows.
    func toggleCut(at point: SIMD2<Double>) {
        let promoted = nearestPromotedCut(to: point)
        let traced = nearestVisibleTarget(to: point)
        switch (promoted, traced) {
        case let (.some(p), .some(t)):
            if p.distance <= t.distance { demote(at: p.index) } else { promote(t.key) }
        case let (.some(p), nil):
            demote(at: p.index)
        case let (nil, .some(t)):
            promote(t.key)
        case (nil, nil):
            break
        }
    }

    private func promote(_ key: TargetKey) {
        guard let result,
              result.elements.indices.contains(key.elementIndex),
              result.elements[key.elementIndex].polylines.indices.contains(key.polylineIndex)
        else { return }
        promotedCuts.append(result.elements[key.elementIndex].polylines[key.polylineIndex])
        promotedSourceTargets.insert(key)
    }

    private func demote(at index: Int) {
        promotedCuts.remove(at: index)
        refreshPromotedSourceTargets()
    }

    /// Re-derives which traced lines the frozen promotions cover (and hide):
    /// after a re-trace the keys are new, and after a demotion the remaining
    /// promotions decide what stays hidden.
    private func refreshPromotedSourceTargets() {
        guard let result, !promotedCuts.isEmpty else {
            promotedSourceTargets = []
            return
        }
        promotedSourceTargets = Self.coincidentTargets(in: result, outlines: promotedCuts)
    }

    /// The frozen promoted line nearest a tap, within the same thumb radius
    /// hit-testing uses for traced lines — demotion must find frozen copies,
    /// whose sources are hidden.
    private func nearestPromotedCut(to point: SIMD2<Double>) -> (index: Int, distance: Double)? {
        guard let result else { return nil }
        let threshold = 0.025 * hypot(result.imageSize.width, result.imageSize.height)
        var best: (Int, Double)?
        for (index, polyline) in promotedCuts.enumerated() {
            var points = polyline.points
            if polyline.isClosed, let first = points.first { points.append(first) }
            guard points.count > 1 else { continue }
            for i in 0..<(points.count - 1) {
                let d = PathGeometry.distanceToSegment(point, points[i], points[i + 1])
                if d < (best?.1 ?? threshold) {
                    best = (index, d)
                }
            }
        }
        return best.map { (index: $0.0, distance: $0.1) }
    }

    // MARK: - Point editing

    /// One control point of one edited path.
    struct PointRef: Equatable {
        var path: Int
        var point: Int
    }

    /// Freezes the current trace (with its cut promotions) AND the cut
    /// outline into editable geometry — outline points drag, join, and brush
    /// like any others. No-op when already editing. While frozen, the live
    /// `cutOutlines` are neither drawn nor exported (their frozen copies
    /// are), so slider-derived outlines can't double up.
    func beginPointEditing() {
        guard editedPaths == nil else { return }
        // Promoted sources are hidden from `visible`, so everything visible
        // engraves; the frozen promotions come along as cut paths.
        editedPaths = visible.map {
            EditablePath(polyline: $0.polyline, isCut: false)
        } + promotedCuts.map {
            EditablePath(polyline: $0, isCut: true)
        } + cutOutlines.map {
            EditablePath(polyline: $0, isCut: true)
        }
    }

    // MARK: - Edit gestures & undo

    /// Marks a finger-down on the frozen geometry: everything the gesture
    /// mutates until `endEditGesture` coalesces into ONE undo entry, pushed
    /// on the gesture's first actual change. A gesture that changes nothing
    /// (a marker stroke through empty space, a drag that grabbed no point)
    /// records nothing.
    func beginEditGesture() {
        pendingUndoSnapshot = editedPaths
    }

    /// Marks the finger-up. A snapshot never promoted (no mutation happened)
    /// is discarded.
    func endEditGesture() {
        pendingUndoSnapshot = nil
    }

    /// Applies a mutation to the frozen geometry, recording the gesture's
    /// pre-state on its first actual change.
    private func applyEdit(_ newPaths: [EditablePath], previous: [EditablePath]) {
        guard newPaths != previous else { return }
        if let snapshot = pendingUndoSnapshot {
            editUndoStack.append(snapshot)
            pendingUndoSnapshot = nil
        }
        editedPaths = newPaths
    }

    /// True when the undo button should be enabled: an edit gesture or an
    /// erasure is there to take back.
    var canUndo: Bool {
        (editedPaths != nil && !editUndoStack.isEmpty) || !eraseShapes.isEmpty
    }

    /// The one user-facing undo: pops the most recent edit gesture while
    /// frozen geometry exists, otherwise falls back to erase undo.
    func undo() {
        if editedPaths != nil, let previous = editUndoStack.popLast() {
            editedPaths = previous
            return
        }
        undoErase()
    }

    /// Locally smooths every path span within `radius` of the swept marker
    /// segment: strong simplification plus a rounding pass, anchored just
    /// outside the touched span so the result blends in. Called per touch
    /// sample — overlapping sweeps compound, so scrubbing smooths harder.
    func brushSmooth(from previous: SIMD2<Double>?, to point: SIMD2<Double>, radius: Double) {
        guard let paths = editedPaths else { return }
        let stroke = previous.map { [$0, point] } ?? [point]
        applyEdit(Self.brushSmoothed(paths, stroke: stroke, radius: radius), previous: paths)
    }

    nonisolated static func brushSmoothed(
        _ paths: [EditablePath], stroke: [SIMD2<Double>], radius: Double
    ) -> [EditablePath] {
        guard !stroke.isEmpty, radius > 0 else { return paths }
        func distanceToStroke(_ p: SIMD2<Double>) -> Double {
            guard stroke.count > 1 else { return simd_length(p - stroke[0]) }
            var best = Double.infinity
            for i in 0..<(stroke.count - 1) {
                best = min(best, PathGeometry.distanceToSegment(p, stroke[i], stroke[i + 1]))
            }
            return best
        }
        let tolerance = 0.25 * radius
        return paths.map { path in
            var polyline = path.polyline
            guard polyline.points.count > 2 else { return path }
            var hit = polyline.points.map { distanceToStroke($0) <= radius }
            guard hit.contains(true) else { return path }

            if polyline.isClosed {
                guard let pivot = hit.firstIndex(of: false) else {
                    // The whole loop is under the marker: smooth it whole.
                    let eased = PathGeometry.smoothed(
                        PathGeometry.simplified(polyline, tolerance: tolerance), passes: 1)
                    return EditablePath(polyline: eased, isCut: path.isCut)
                }
                // A closed loop's start is arbitrary — rotate the seam onto
                // an untouched point so spans never wrap.
                polyline.points = Array(polyline.points[pivot...] + polyline.points[..<pivot])
                hit = Array(hit[pivot...] + hit[..<pivot])
            }

            // Each maximal touched run, widened by one anchor point per
            // side. Replaced right-to-left so earlier indices stay valid;
            // simplify + Chaikin both pin the anchors, so spans blend in.
            var points = polyline.points
            var spans: [(start: Int, end: Int)] = []
            var index = 0
            while index < hit.count {
                guard hit[index] else { index += 1; continue }
                var runEnd = index
                while runEnd + 1 < hit.count && hit[runEnd + 1] { runEnd += 1 }
                spans.append((max(0, index - 1), min(hit.count - 1, runEnd + 1)))
                index = runEnd + 1
            }
            for span in spans.reversed() where span.end - span.start >= 2 {
                let piece = Polyline(points: Array(points[span.start...span.end]), isClosed: false)
                let eased = PathGeometry.smoothed(
                    PathGeometry.simplified(piece, tolerance: tolerance), passes: 1)
                points.replaceSubrange(span.start...span.end, with: eased.points)
            }
            polyline.points = points
            return EditablePath(polyline: polyline, isCut: path.isCut)
        }
    }

    func position(of ref: PointRef) -> SIMD2<Double>? {
        guard let paths = editedPaths, paths.indices.contains(ref.path),
              paths[ref.path].polyline.points.indices.contains(ref.point) else { return nil }
        return paths[ref.path].polyline.points[ref.point]
    }

    /// The control point nearest a touch, within `radius`.
    func editablePoint(near location: SIMD2<Double>, radius: Double) -> PointRef? {
        guard let paths = editedPaths else { return nil }
        var best: (PointRef, Double)?
        for (pathIndex, path) in paths.enumerated() {
            for (pointIndex, point) in path.polyline.points.enumerated() {
                let d = simd_length(point - location)
                if d <= radius, d < (best?.1 ?? .infinity) {
                    best = (PointRef(path: pathIndex, point: pointIndex), d)
                }
            }
        }
        return best?.0
    }

    nonisolated static func isEndpoint(_ ref: PointRef, in paths: [EditablePath]) -> Bool {
        guard paths.indices.contains(ref.path) else { return false }
        let polyline = paths[ref.path].polyline
        return !polyline.isClosed && (ref.point == 0 || ref.point == polyline.points.count - 1)
    }

    /// The control point the drag can magnetically land on, within `radius`
    /// of the dragged position. Every point of every path is a target —
    /// placing a point exactly onto a mid-line vertex matters as much as
    /// joining ends — except the dragged point's immediate neighbors, which
    /// would otherwise stick constantly while dragging along its own line.
    /// Only an endpoint released on an endpoint joins paths (see `joining`).
    nonisolated static func snapTarget(
        in paths: [EditablePath], for dragged: PointRef,
        near location: SIMD2<Double>, radius: Double
    ) -> PointRef? {
        guard paths.indices.contains(dragged.path) else { return nil }
        var best: (PointRef, Double)?
        for (pathIndex, path) in paths.enumerated() {
            let count = path.polyline.points.count
            for (pointIndex, point) in path.polyline.points.enumerated() {
                if pathIndex == dragged.path {
                    // Itself and its neighbors (across the seam on a closed
                    // path) are never targets.
                    let gap = abs(pointIndex - dragged.point)
                    let separation = path.polyline.isClosed ? min(gap, count - gap) : gap
                    if separation <= 1 { continue }
                }
                let d = simd_length(point - location)
                if d <= radius, d < (best?.1 ?? .infinity) {
                    best = (PointRef(path: pathIndex, point: pointIndex), d)
                }
            }
        }
        return best?.0
    }

    /// Joins two endpoints: the same path's other end closes the shape;
    /// another path's end merges the two into one (cut wins over engrave —
    /// joins exist to build cut loops).
    nonisolated static func joining(
        _ paths: [EditablePath], dragged: PointRef, target: PointRef
    ) -> [EditablePath] {
        guard isEndpoint(dragged, in: paths), isEndpoint(target, in: paths) else { return paths }
        var paths = paths
        if target.path == dragged.path {
            // The dragged duplicate sits on the other end; closing supplies
            // that segment.
            var polyline = paths[dragged.path].polyline
            if dragged.point == 0 {
                polyline.points.removeFirst()
            } else {
                polyline.points.removeLast()
            }
            polyline.isClosed = true
            paths[dragged.path].polyline = polyline
        } else {
            var head = paths[dragged.path].polyline.points
            var tail = paths[target.path].polyline.points
            if dragged.point == 0 { head.reverse() }          // dragged end last
            if target.point != 0 { tail.reverse() }           // snapped end first
            let merged = Polyline(points: head.dropLast() + tail, isClosed: false)
            let isCut = paths[dragged.path].isCut || paths[target.path].isCut
            let keep = min(dragged.path, target.path)
            let drop = max(dragged.path, target.path)
            paths[keep] = EditablePath(polyline: merged, isCut: isCut)
            paths.remove(at: drop)
        }
        return paths
    }

    func snapTarget(for dragged: PointRef, near location: SIMD2<Double>, radius: Double) -> PointRef? {
        guard let paths = editedPaths else { return nil }
        return Self.snapTarget(in: paths, for: dragged, near: location, radius: radius)
    }

    func movePoint(_ ref: PointRef, to location: SIMD2<Double>) {
        guard let previous = editedPaths, previous.indices.contains(ref.path),
              previous[ref.path].polyline.points.indices.contains(ref.point) else { return }
        var paths = previous
        paths[ref.path].polyline.points[ref.point] = location
        applyEdit(paths, previous: previous)
    }

    /// Completes a drag; without a snap target the drag was just a move.
    func endPointDrag(_ dragged: PointRef, snappedTo target: PointRef?) {
        guard let target, let paths = editedPaths else { return }
        applyEdit(Self.joining(paths, dragged: dragged, target: target), previous: paths)
    }

    // MARK: - Erasing

    /// The visible polyline nearest a tap, within a forgiving thumb radius.
    func target(near point: SIMD2<Double>) -> TargetKey? {
        nearestVisibleTarget(to: point)?.key
    }

    private func nearestVisibleTarget(to point: SIMD2<Double>) -> (key: TargetKey, distance: Double)? {
        guard let result else { return nil }
        let threshold = 0.025 * hypot(result.imageSize.width, result.imageSize.height)
        var best: (TargetKey, Double)?
        for (e, element) in result.elements.enumerated() {
            for (p, polyline) in element.polylines.enumerated() {
                let key = TargetKey(elementIndex: e, polylineIndex: p)
                guard !removedTargets.contains(key), !outlineTargets.contains(key),
                      !promotedSourceTargets.contains(key) else { continue }
                var points = polyline.points
                if polyline.isClosed, let first = points.first { points.append(first) }
                guard points.count > 1 else { continue }
                for i in 0..<(points.count - 1) {
                    let d = PathGeometry.distanceToSegment(point, points[i], points[i + 1])
                    if d < (best?.1 ?? threshold) {
                        best = (key, d)
                    }
                }
            }
        }
        return best.map { (key: $0.0, distance: $0.1) }
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
        eraseBatchSizes.append(1)
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
        eraseBatchSizes.append(1)
        for key in targets(within: radius, of: point) {
            removedTargets.insert(key)
        }
        scheduleRetrace(debounce: true)
    }

    func undoErase() {
        guard !eraseShapes.isEmpty else { return }
        let batch = eraseBatchSizes.popLast() ?? 1
        eraseShapes.removeLast(min(batch, eraseShapes.count))
        suggestionsApplied = false
        scheduleRetrace(debounce: false)
    }

    func resetErases() {
        eraseShapes.removeAll()
        eraseBatchSizes.removeAll()
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
        var added = 0
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
            added += 1
        }
        // One undo press restores everything this Apply removed.
        if added > 0 { eraseBatchSizes.append(added) }
        suggestionsApplied = true
        scheduleRetrace(debounce: false)
    }

    // MARK: - Versions

    func saveVersion() throws {
        let snapshot = TraceSnapshot(
            detail: detail, eraseShapes: eraseShapes, outlineDetail: outlineDetail,
            outlineSmoothness: outlineSmoothness,
            smoothness: smoothness,
            promotedCuts: promotedCuts.map { polyline in
                SnapshotPolyline(
                    points: polyline.points.map { [$0.x, $0.y] },
                    isClosed: polyline.isClosed
                )
            },
            editedPaths: editedPaths.map { paths in
                paths.map { path in
                    SnapshotEditedPath(
                        points: path.polyline.points.map { [$0.x, $0.y] },
                        isClosed: path.polyline.isClosed,
                        isCut: path.isCut
                    )
                }
            },
            editedPathsIncludeOutlines: editedPaths != nil)
        let data = try JSONEncoder().encode(snapshot)
        _ = try store.addTraceVersion(to: project, detail: detail, pathsData: data)
        syncProject()
    }

    func restore(_ version: TraceVersion) {
        let url = store.tracePathsURL(for: version, in: project)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TraceSnapshot.self, from: data) else { return }
        defer { eraseBatchSizes = eraseShapes.map { _ in 1 } }
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
        outlineSmoothness = snapshot.outlineSmoothness ?? TraceParameters.defaultSmoothness
        // Older snapshots predate the Smoothness slider; they were made with
        // what is now its default. Setting these may each schedule a retrace,
        // but scheduling cancels the previous task, so only one trace runs.
        smoothness = snapshot.smoothness ?? TraceParameters.defaultSmoothness
        if let frozen = snapshot.promotedCuts {
            // Frozen promotions restore as exact geometry — no tap replay.
            promotedCuts = frozen.compactMap { saved in
                let points = saved.points.compactMap { values -> SIMD2<Double>? in
                    values.count >= 2 ? SIMD2(values[0], values[1]) : nil
                }
                guard points.count >= 2 else { return nil }
                return Polyline(points: points, isClosed: saved.isClosed)
            }
            pendingLegacyCutTaps = nil
        } else {
            // Legacy snapshots stored taps: convert each into a frozen
            // promotion once, after the restore-triggered re-trace lands.
            promotedCuts = []
            let taps = (snapshot.cutTaps ?? []).compactMap { values -> SIMD2<Double>? in
                values.count >= 2 ? SIMD2(values[0], values[1]) : nil
            }
            pendingLegacyCutTaps = taps.isEmpty ? nil : taps
        }
        refreshPromotedSourceTargets()
        // Applied after the restore-triggered re-trace lands.
        pendingRestoredEdits = snapshot.editedPaths.map { paths in
            paths.compactMap { path in
                let points = path.points.compactMap { values -> SIMD2<Double>? in
                    values.count >= 2 ? SIMD2(values[0], values[1]) : nil
                }
                guard points.count >= 2 else { return nil }
                return EditablePath(
                    polyline: Polyline(points: points, isClosed: path.isClosed),
                    isCut: path.isCut
                )
            }
        }
        // Versions saved before the outline was absorbed into the frozen set
        // would otherwise lose their red cut loop (live outlines are hidden
        // while edits exist) — graft the current outline in.
        if pendingRestoredEdits != nil, snapshot.editedPathsIncludeOutlines != true {
            pendingRestoredEdits! += cutOutlines.map { EditablePath(polyline: $0, isCut: true) }
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
                guard !removedTargets.contains(key), !outlineTargets.contains(key),
                      !promotedSourceTargets.contains(key) else { continue }
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
    /// the file URL. The cut outline and any tap-promoted lines land on the
    /// CUT layer; everything else traced engraves.
    func exportDXF(widthMM: Double) throws -> URL {
        let engrave: [Polyline]
        let cuts: [Polyline]
        if let editedPaths {
            // Frozen geometry already contains the cut outline and any
            // promotions (they froze in as isCut paths).
            engrave = editedPaths.filter { !$0.isCut }.map(\.polyline)
            cuts = editedPaths.filter(\.isCut).map(\.polyline)
        } else {
            // Promoted sources are hidden from `visible`; the frozen copies
            // cut instead.
            engrave = visible.map(\.polyline)
            cuts = cutOutlines + promotedCuts
        }
        let dxf = DXFExportBuilder.dxf(
            from: engrave, cutOutlines: cuts, widthMM: widthMM)
        let directory = store.exportsDirectory(for: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
        let url = directory.appending(path: "\(project.title.replacingOccurrences(of: " ", with: "-"))-\(existing + 1).dxf")
        try dxf.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
