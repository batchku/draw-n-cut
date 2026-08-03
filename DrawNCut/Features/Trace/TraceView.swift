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
            TraceCanvas(session: session, showPhoto: showPhoto, eraserMode: eraserMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if session.pendingSuggestionCount > 0 && !session.suggestionsApplied {
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

    private func suggestionBanner(_ session: TraceSession) -> some View {
        HStack(spacing: 12) {
            Label("\(session.pendingSuggestionCount) cleanup suggestions", systemImage: "wand.and.stars")
                .font(.footnote)
            Button("Apply") { session.applySuggestions() }
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
            // The red cut outline: how faithfully it follows the mask.
            if session.hasSubjectMask {
                HStack {
                    Text("Outline")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 52, alignment: .leading)
                    Slider(value: $session.outlineDetail, in: 0...1)
                        .tint(.red)
                }
            }
            // The blue engrave lines: the trace Detail.
            HStack {
                Text("Lines")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(width: 52, alignment: .leading)
                Slider(value: $session.detail, in: 0...1)
                    .tint(.blue)
            }
            HStack(spacing: 16) {
                Spacer()
                Text(eraserMode ? "Circle around things to erase • two-finger tap undoes" : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    session.undoErase()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                }
                .disabled(session.eraseShapes.isEmpty)
                .accessibilityLabel("Undo erase")
                Button {
                    eraserMode.toggle()
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

/// Renders the traced polylines scaled to fit, over the (optional) photo.
/// Taps map back to image space and erase the nearest line.
private struct TraceCanvas: View {
    let session: TraceSession
    let showPhoto: Bool
    let eraserMode: Bool

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    /// The in-progress lasso, in view coordinates, while a finger circles
    /// something in eraser mode.
    @State private var lassoViewPoints: [CGPoint] = []

    /// Spot-erase radius as the finger experiences it, regardless of zoom.
    private let eraserViewRadius: CGFloat = 22

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

            Canvas { context, _ in
                if showPhoto, let image = session.image {
                    let rect = CGRect(
                        x: offset.width, y: offset.height,
                        width: imageSize.width * scale, height: imageSize.height * scale
                    )
                    context.opacity = 0.25
                    context.draw(Image(decorative: image, scale: 1), in: rect)
                    context.opacity = 1
                }
                for item in session.visible {
                    let style = color(for: item.suggestion)
                    context.stroke(
                        path(for: item.polyline, scale: scale, offset: offset),
                        with: .color(style.color),
                        lineWidth: style.emphasized ? 3 : 1.5
                    )
                }
                // The CUT loops (piece edges and holes) — drawn last so they
                // read as the piece's edges. Red like the DXF CUT layer. Not
                // erasable: they aren't traced polylines.
                for outline in session.cutOutlines {
                    context.stroke(
                        path(for: outline, scale: scale, offset: offset),
                        with: .color(.red),
                        lineWidth: 3
                    )
                }
                // The lasso being drawn right now.
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
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityIdentifier("traceCanvas")
            .accessibilityValue("\(session.visible.count) paths")
            .overlay {
                TouchOverlay(eraserActive: eraserMode) { previous, current in
                    // Collect the loop; nothing erases until the finger lifts.
                    if previous == nil {
                        lassoViewPoints = [current]
                    } else {
                        lassoViewPoints.append(current)
                    }
                } onEraseEnd: {
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
                    session.undoErase()
                }
            }
        }
        .background(Color.white)
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
