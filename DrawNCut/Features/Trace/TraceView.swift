import SwiftUI
import simd

/// The trace screen: live preview, the single Detail slider, tap-to-remove,
/// cleanup suggestions, version history, and DXF export.
struct TraceView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: [Route]
    let projectID: UUID

    @State private var session: TraceSession?
    @State private var showPhoto = false
    @State private var showExport = false
    @State private var saveConfirmation = false
    @State private var eraserMode = false
    @State private var pointEditMode = false
    @State private var brushMode = false

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ProgressView("Loading…")
            }
        }
        .navigationTitle(session?.project.title ?? "Trace")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil,
                  let project = store.projects.first(where: { $0.id == projectID }) else { return }
            let newSession = TraceSession(project: project, store: store)
            session = newSession
            await newSession.load()
        }
        .onAppear {
            // Popping back from Select Subject reveals this same instance;
            // the mask file may have changed while it sat in the stack.
            guard let session else { return }
            Task { await session.reloadMask() }
        }
    }

    @ViewBuilder
    private func content(_ session: TraceSession) -> some View {
        VStack(spacing: 0) {
            TraceCanvas(session: session, showPhoto: showPhoto, eraserMode: eraserMode,
                        pointEditMode: pointEditMode, brushMode: brushMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if session.pendingSuggestionCount > 0 && !session.suggestionsApplied
                        && !pointEditMode && !brushMode {
                        suggestionBanner(session)
                    }
                }
                .overlay {
                    if session.isTracing {
                        ProgressView("Tracing…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if session.result != nil && session.visible.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing to Trace", systemImage: "eye.slash")
                        } description: {
                            Text("No drawing was found in this photo. Retake it with more light, filling the frame with the page.")
                        }
                    }
                }

            controls(session)
        }
        .toolbar { toolbarContent(session) }
        .sheet(isPresented: $showExport) {
            ExportSheet(session: session)
                .presentationDetents([.medium])
        }
    }

    /// These are REMOVAL suggestions from the app's own heuristics (not the
    /// segmentation model): highlighted lines look like page clutter — an
    /// enclosing circle, handwriting, edge junk — and the button deletes
    /// them. The wording must say so; "apply corrections" once read as
    /// "fix them" and surprised the user when lines vanished.
    private func suggestionBanner(_ session: TraceSession) -> some View {
        HStack(spacing: 12) {
            Label(
                "\(session.pendingSuggestionCount) highlighted lines look like page clutter",
                systemImage: "wand.and.stars"
            )
            .font(.footnote)
            Button("Remove", role: .destructive) { session.applySuggestions() }
                .font(.footnote.bold())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private func controls(_ session: TraceSession) -> some View {
        @Bindable var session = session
        return VStack(spacing: 10) {
            // Sliders re-derive geometry from the photo, which would discard
            // point surgery — so they sleep while points are being edited.
            // Two matching sections: the red CUT outline and the blue ENGRAVE
            // lines, each with Detail (what the shape keeps) and Smoothing
            // (how its curves are drawn).
            Group {
                if session.hasSubjectMask {
                    sectionHeader("Cut", tint: .red)
                    sliderRow("Detail", value: $session.outlineDetail, tint: .red)
                    sliderRow("Smoothing", value: $session.outlineSmoothness, tint: .red)
                }
                sectionHeader("Engrave", tint: .blue)
                sliderRow("Detail", value: $session.detail, tint: .blue)
                sliderRow("Smoothing", value: $session.smoothness, tint: .blue)
            }
            .disabled(pointEditMode || brushMode)
            .opacity(pointEditMode || brushMode ? 0.35 : 1)
            HStack(spacing: 16) {
                Toggle(isOn: $pointEditMode) {
                    Text("Points")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityIdentifier("pointEditToggle")
                .onChange(of: pointEditMode) { _, on in
                    if on {
                        eraserMode = false
                        brushMode = false
                        session.beginPointEditing()
                    }
                }
                Spacer()
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    session.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                }
                .disabled(!session.canUndo)
                .accessibilityLabel("Undo")
                Button {
                    brushMode.toggle()
                    if brushMode {
                        eraserMode = false
                        pointEditMode = false
                        session.beginPointEditing()
                    }
                } label: {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.title2)
                        .foregroundStyle(brushMode ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel(brushMode ? "Smoothing marker on" : "Smoothing marker off")
                .accessibilityIdentifier("smoothBrushToggle")
                Button {
                    eraserMode.toggle()
                    if eraserMode {
                        pointEditMode = false
                        brushMode = false
                    }
                } label: {
                    Image(systemName: eraserMode ? "eraser.fill" : "eraser")
                        .font(.title2)
                        .foregroundStyle(eraserMode ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel(eraserMode ? "Eraser on" : "Eraser off")
                .accessibilityIdentifier("eraserToggle")
            }
        }
        .padding()
        .background(.bar)
    }

    private func sectionHeader(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, tint: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(tint)
        }
        .padding(.leading, 8)
    }

    private var hint: String {
        if pointEditMode {
            return "Drag points • drop an endpoint on another to join"
        }
        if brushMode {
            return "Sweep over jagged lines to smooth • scrub for more"
        }
        if eraserMode {
            return "Circle around things to erase • two-finger tap undoes"
        }
        return ""
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ session: TraceSession) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                do {
                    try session.saveVersion()
                    saveConfirmation = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        saveConfirmation = false
                    }
                } catch {}
            } label: {
                if saveConfirmation {
                    Label("Saved", systemImage: "checkmark")
                } else {
                    Label("Save Version", systemImage: "square.and.arrow.down")
                }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            // Run (or redo) SAM subject selection on this stored drawing —
            // the only way a cut outline comes into existence.
            Button {
                path.append(.refineMask(projectID: projectID))
            } label: {
                Label(
                    session.hasSubjectMask ? "Redo Outline" : "Select Subject",
                    systemImage: "person.and.background.dotted"
                )
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            versionsMenu(session)
        }
        ToolbarItem(placement: .secondaryAction) {
            Toggle(isOn: $showPhoto) {
                Label("Show Photo", systemImage: "photo")
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button {
                showExport = true
            } label: {
                Label("Export DXF", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.visible.isEmpty)
        }
    }

    @ViewBuilder
    private func versionsMenu(_ session: TraceSession) -> some View {
        let versions = session.project.traceVersions
        Menu {
            if versions.isEmpty {
                Text("No saved versions yet")
            }
            ForEach(versions.reversed()) { version in
                Button {
                    session.restore(version)
                } label: {
                    let active = session.project.activeTraceVersionID == version.id
                    Label(
                        "v\(version.number) — detail \(Int(version.detail * 100))%",
                        systemImage: active ? "checkmark.circle.fill" : "clock.arrow.circlepath"
                    )
                }
            }
        } label: {
            Label("Versions", systemImage: "clock.arrow.circlepath")
        }
    }
}

/// The snap-in glide: when a dragged point engages a magnet it eases onto it
/// over a fifth of a second instead of teleporting — at loupe magnification
/// an instant jump reads as a jarring jolt. Pure math so it's testable.
enum SnapTween {
    static let duration: Double = 0.22
    /// Ease-out cubic progress for a normalized time 0...1: fast start,
    /// gentle landing on the magnet.
    static func progress(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

/// Where the point-drag loupe sits relative to the finger: above and to the
/// right by default, flipping side/vertical near viewport edges, finally
/// clamped fully on-screen. Pure math so it's directly testable.
enum LoupeGeometry {
    static let radius: CGFloat = 62
    /// Extra magnification on top of the user's current zoom.
    static let magnification: CGFloat = 2.5
    private static let fingerOffset = CGVector(dx: 84, dy: -104)

    static func center(finger: CGPoint, viewport: CGSize) -> CGPoint {
        var x = finger.x + fingerOffset.dx
        var y = finger.y + fingerOffset.dy
        // Would poke past the right edge → sit to the finger's left.
        if x + radius > viewport.width { x = finger.x - fingerOffset.dx }
        // Would poke past the top → sit below the finger.
        if y - radius < 0 { y = finger.y - fingerOffset.dy }
        return CGPoint(
            x: min(max(x, radius), max(radius, viewport.width - radius)),
            y: min(max(y, radius), max(radius, viewport.height - radius))
        )
    }
}

/// Renders the traced polylines scaled to fit, over the (optional) photo.
/// Taps map back to image space and erase the nearest line.
private struct TraceCanvas: View {
    let session: TraceSession
    let showPhoto: Bool
    let eraserMode: Bool
    let pointEditMode: Bool
    let brushMode: Bool

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    /// The in-progress lasso, in view coordinates, while a finger circles
    /// something in eraser mode.
    @State private var lassoViewPoints: [CGPoint] = []
    /// The control point under the finger, while one is being dragged.
    @State private var dragRef: TraceSession.PointRef?
    /// The endpoint the dragged point is currently snapped onto.
    @State private var snapRef: TraceSession.PointRef?
    /// Where the finger is right now (view space) — anchors the drag loupe.
    @State private var dragViewLocation: CGPoint?
    /// The in-flight snap glide, while a dragged point eases onto a magnet.
    @State private var snapTweenTask: Task<Void, Never>?

    /// Spot-erase radius as the finger experiences it, regardless of zoom.
    private let eraserViewRadius: CGFloat = 22
    /// How far a finger can miss a control point and still grab it (view pt).
    private let pointGrabViewRadius: CGFloat = 24
    /// Magnetic range for endpoint-to-endpoint snapping (view pt).
    private let snapViewRadius: CGFloat = 16
    /// Half-width of the smoothing marker (view pt) — a thick pen. Zooming
    /// in narrows it in image space for finer, gentler smoothing.
    private let brushViewRadius: CGFloat = 24
    /// The marker trail while the finger sweeps, in view coordinates.
    @State private var brushViewPoints: [CGPoint] = []

    var body: some View {
        GeometryReader { geometry in
            let imageSize = session.result?.imageSize ?? CGSize(width: 1, height: 1)
            let fit = fitTransform(imageSize: imageSize, into: geometry.size)
            // Total image→view transform: fit, then zoom about the origin,
            // then pan.
            let scale = fit.scale * zoom
            let offset = CGSize(
                width: fit.offset.width * zoom + panOffset.width,
                height: fit.offset.height * zoom + panOffset.height
            )

            Canvas { context, size in
                drawScene(context, scale: scale, offset: offset)
                // The smoothing marker's trail — a thick translucent pen.
                if brushViewPoints.count > 1 {
                    var trail = Path()
                    trail.move(to: brushViewPoints[0])
                    for point in brushViewPoints.dropFirst() { trail.addLine(to: point) }
                    context.stroke(
                        trail,
                        with: .color(.orange.opacity(0.3)),
                        style: StrokeStyle(
                            lineWidth: 2 * brushViewRadius, lineCap: .round, lineJoin: .round)
                    )
                }
                // The lasso being drawn right now (never magnified).
                if lassoViewPoints.count > 1 {
                    var lasso = Path()
                    lasso.move(to: lassoViewPoints[0])
                    for point in lassoViewPoints.dropFirst() { lasso.addLine(to: point) }
                    context.stroke(
                        lasso,
                        with: .color(.orange),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                }
                // The drag loupe: the finger hides exactly the point being
                // placed, so a magnified circle floats beside it showing the
                // point, its surroundings, and the snap ring.
                if pointEditMode, let dragRef, let finger = dragViewLocation,
                   let point = session.position(of: dragRef) {
                    let center = LoupeGeometry.center(finger: finger, viewport: size)
                    let radius = LoupeGeometry.radius
                    let circle = Path(ellipseIn: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: 2 * radius, height: 2 * radius
                    ))
                    // The loupe keeps the dragged point at its center: solve
                    // the magnified transform for point → center.
                    let loupeScale = scale * LoupeGeometry.magnification
                    let loupeOffset = CGSize(
                        width: center.x - point.x * loupeScale,
                        height: center.y - point.y * loupeScale
                    )
                    var loupe = context
                    loupe.clip(to: circle)
                    loupe.fill(circle, with: .color(.white))
                    drawScene(loupe, scale: loupeScale, offset: loupeOffset)
                    context.stroke(circle, with: .color(.gray.opacity(0.7)), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityIdentifier("traceCanvas")
            .accessibilityValue("\(session.visible.count) paths")
            .overlay {
                // One-finger drags are claimed by whichever edit mode is on:
                // lasso collection for the eraser, point dragging for point
                // editing. Two-finger pan/pinch stays available in both.
                TouchOverlay(eraserActive: eraserMode || pointEditMode || brushMode) { previous, current in
                    let toImage = { (p: CGPoint) in
                        SIMD2(
                            (p.x - offset.width) / scale,
                            (p.y - offset.height) / scale
                        )
                    }
                    if brushMode {
                        // Live: every swept segment smooths what's under it
                        // immediately; scrubbing compounds. One stroke =
                        // one undo entry, bounded by the gesture.
                        if previous == nil { session.beginEditGesture() }
                        brushViewPoints.append(current)
                        session.brushSmooth(
                            from: previous.map(toImage),
                            to: toImage(current),
                            radius: brushViewRadius / scale
                        )
                        return
                    }
                    if pointEditMode {
                        let location = toImage(current)
                        if previous == nil {
                            // One drag (including a snap-join on release) =
                            // one undo entry; grabbing nothing records nothing.
                            session.beginEditGesture()
                            dragRef = session.editablePoint(
                                near: location, radius: pointGrabViewRadius / scale)
                            snapRef = nil
                            snapTweenTask?.cancel()
                            snapTweenTask = nil
                        }
                        guard let ref = dragRef else { return }
                        dragViewLocation = current
                        if let target = session.snapTarget(
                            for: ref, near: location, radius: snapViewRadius / scale),
                           let magnet = session.position(of: target) {
                            if snapRef != target {
                                // Newly magnetized: glide onto the magnet
                                // instead of teleporting.
                                snapRef = target
                                startSnapTween(ref: ref, to: magnet)
                            } else if snapTweenTask == nil {
                                session.movePoint(ref, to: magnet)
                            }
                        } else {
                            snapRef = nil
                            snapTweenTask?.cancel()
                            snapTweenTask = nil
                            session.movePoint(ref, to: location)
                        }
                        return
                    }
                    // Collect the loop; nothing erases until the finger lifts.
                    if previous == nil {
                        lassoViewPoints = [current]
                    } else {
                        lassoViewPoints.append(current)
                    }
                } onEraseEnd: {
                    if brushMode {
                        brushViewPoints = []
                        session.endEditGesture()
                        return
                    }
                    if pointEditMode {
                        snapTweenTask?.cancel()
                        snapTweenTask = nil
                        if let ref = dragRef {
                            // Released mid-glide: land exactly on the magnet
                            // before joining.
                            if let snapRef, let magnet = session.position(of: snapRef) {
                                session.movePoint(ref, to: magnet)
                            }
                            session.endPointDrag(ref, snappedTo: snapRef)
                        }
                        session.endEditGesture()
                        dragRef = nil
                        snapRef = nil
                        dragViewLocation = nil
                        return
                    }
                    let toImage = { (p: CGPoint) in
                        SIMD2(
                            (p.x - offset.width) / scale,
                            (p.y - offset.height) / scale
                        )
                    }
                    if lassoViewPoints.count >= 3 {
                        session.eraseLasso(points: lassoViewPoints.map(toImage))
                    } else if let point = lassoViewPoints.first {
                        session.eraseSpot(at: toImage(point), radius: eraserViewRadius / scale)
                    }
                    lassoViewPoints = []
                } onPan: { delta in
                    panOffset.width += delta.x
                    panOffset.height += delta.y
                    clampPan(viewport: geometry.size)
                } onPinch: { scaleDelta, centroid in
                    let newZoom = min(8, max(1, zoom * scaleDelta))
                    let applied = newZoom / zoom
                    // Keep the pinch centroid stationary on screen.
                    panOffset.width = centroid.x - (centroid.x - panOffset.width) * applied
                    panOffset.height = centroid.y - (centroid.y - panOffset.height) * applied
                    zoom = newZoom
                    clampPan(viewport: geometry.size)
                } onTwoFingerTap: {
                    session.undo()
                } onSingleTap: { location in
                    // Tap a blue line → cut (red); tap again → engrave (blue).
                    // While editing points or brushing, taps belong to those.
                    guard !pointEditMode && !brushMode else { return }
                    session.toggleCut(at: SIMD2(
                        (location.x - offset.width) / scale,
                        (location.y - offset.height) / scale
                    ))
                }
            }
        }
        .background(Color.white)
    }

    /// Eases the dragged point from where it is onto the magnet, ~60fps for
    /// SnapTween.duration. Cancelled when the finger pulls off the magnet or
    /// lifts; the release handler pins the exact magnet position regardless.
    private func startSnapTween(ref: TraceSession.PointRef, to magnet: SIMD2<Double>) {
        snapTweenTask?.cancel()
        guard let from = session.position(of: ref) else { return }
        snapTweenTask = Task { @MainActor in
            let started = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(started) / SnapTween.duration
                let eased = SnapTween.progress(t)
                session.movePoint(ref, to: from + (magnet - from) * eased)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { snapTweenTask = nil }
        }
    }

    /// Everything that belongs to the drawing itself — photo, paths, cut
    /// loops, and (in point-edit mode) control-point handles and the snap
    /// ring. Drawn once for the screen and again, magnified, inside the
    /// drag loupe.
    private func drawScene(_ context: GraphicsContext, scale: Double, offset: CGSize) {
        var context = context
        if showPhoto, let image = session.image,
           let imageSize = session.result?.imageSize {
            let rect = CGRect(
                x: offset.width, y: offset.height,
                width: imageSize.width * scale, height: imageSize.height * scale
            )
            context.opacity = 0.25
            context.draw(Image(decorative: image, scale: 1), in: rect)
            context.opacity = 1
        }
        if let edited = session.editedPaths {
            // Point-edited geometry replaces the live trace until the
            // next re-trace resets it.
            for editablePath in edited {
                context.stroke(
                    path(for: editablePath.polyline, scale: scale, offset: offset),
                    with: .color(editablePath.isCut ? .red : .blue),
                    lineWidth: editablePath.isCut ? 3 : 1.5
                )
            }
        } else {
            for item in session.visible {
                let style = color(for: item.suggestion)
                context.stroke(
                    path(for: item.polyline, scale: scale, offset: offset),
                    with: .color(style.color),
                    lineWidth: style.emphasized ? 3 : 1.5
                )
            }
        }
        // The CUT loops (piece edges and holes) — drawn last so they
        // read as the piece's edges. Red like the DXF CUT layer. While
        // frozen geometry exists it already contains them, so the live
        // outlines stay hidden (they'd double up).
        if session.editedPaths == nil {
            // Tap-promoted lines are frozen copies owned by the cut world:
            // drawn exactly like the outline, red, on top of the blues.
            for outline in session.cutOutlines + session.promotedCuts {
                context.stroke(
                    path(for: outline, scale: scale, offset: offset),
                    with: .color(.red),
                    lineWidth: 3
                )
            }
        }
        // Control-point handles. Endpoints draw bigger — they're the
        // joinable ones. Handle size is constant on screen, not in
        // image space, so zooming in doesn't balloon them.
        if pointEditMode, let edited = session.editedPaths {
            for (pathIndex, editablePath) in edited.enumerated() {
                let polyline = editablePath.polyline
                let tint: Color = editablePath.isCut ? .red : .blue
                for (index, point) in polyline.points.enumerated() {
                    let ref = TraceSession.PointRef(path: pathIndex, point: index)
                    let isEndpoint = !polyline.isClosed
                        && (index == 0 || index == polyline.points.count - 1)
                    let radius: CGFloat = isEndpoint ? 6 : 3.5
                    let center = CGPoint(
                        x: point.x * scale + offset.width,
                        y: point.y * scale + offset.height
                    )
                    let rect = CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: 2 * radius, height: 2 * radius
                    )
                    // The point in hand fills orange so it reads instantly
                    // in the loupe.
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(ref == dragRef ? .orange : .white)
                    )
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(tint),
                        lineWidth: isEndpoint ? 2 : 1.25
                    )
                }
            }
            // The endpoint the drag is magnetically locked onto.
            if let snapRef, let position = session.position(of: snapRef) {
                let center = CGPoint(
                    x: position.x * scale + offset.width,
                    y: position.y * scale + offset.height
                )
                let rect = CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
                context.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 3)
            }
        }
    }

    private func clampPan(viewport: CGSize) {
        if zoom <= 1 {
            panOffset = .zero
            return
        }
        let minX = viewport.width * (1 - zoom)
        let minY = viewport.height * (1 - zoom)
        panOffset.width = min(0, max(minX, panOffset.width))
        panOffset.height = min(0, max(minY, panOffset.height))
    }

    private func path(for polyline: Polyline, scale: Double, offset: CGSize) -> Path {
        var swiftUIPath = Path()
        let points = polyline.points.map { point in
            CGPoint(
                x: point.x * scale + offset.width,
                y: point.y * scale + offset.height
            )
        }
        guard let first = points.first else { return swiftUIPath }
        swiftUIPath.move(to: first)
        for point in points.dropFirst() { swiftUIPath.addLine(to: point) }
        if polyline.isClosed { swiftUIPath.closeSubpath() }
        return swiftUIPath
    }

    /// Engrave lines are blue (matching the DXF ENGRAVE layer); red is
    /// reserved for the CUT outline. Suggestions highlight in warm hues.
    private func color(for suggestion: RemovalReason?) -> (color: Color, emphasized: Bool) {
        switch suggestion {
        case .enclosingLoop: (.orange, true)
        case .textLike: (.purple, true)
        case .edgeArtifact: (.pink, true)
        case nil: (.blue, false)
        }
    }

    private func fitTransform(imageSize: CGSize, into container: CGSize) -> (scale: Double, offset: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return (1, .zero) }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let offset = CGSize(
            width: (container.width - imageSize.width * scale) / 2,
            height: (container.height - imageSize.height * scale) / 2
        )
        return (scale, offset)
    }
}
