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
            HStack {
                Image(systemName: "circle.grid.cross")
                    .foregroundStyle(.secondary)
                Slider(value: $session.detail, in: 0...1)
                Image(systemName: "circle.grid.cross.fill")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Text("Detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(eraserMode ? "Sweep over lines to erase • two-finger tap undoes" : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    session.undoErase()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                }
                .disabled(session.eraseTaps.isEmpty)
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

    var body: some View {
        GeometryReader { geometry in
            let imageSize = session.result?.imageSize ?? CGSize(width: 1, height: 1)
            let fit = fitTransform(imageSize: imageSize, into: geometry.size)

            ZStack {
                if showPhoto, let image = session.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .opacity(0.25)
                }
                Canvas { context, _ in
                    for item in session.visible {
                        var swiftUIPath = Path()
                        let points = item.polyline.points.map { point in
                            CGPoint(
                                x: point.x * fit.scale + fit.offset.width,
                                y: point.y * fit.scale + fit.offset.height
                            )
                        }
                        guard let first = points.first else { continue }
                        swiftUIPath.move(to: first)
                        for point in points.dropFirst() { swiftUIPath.addLine(to: point) }
                        if item.polyline.isClosed { swiftUIPath.closeSubpath() }

                        let style = color(for: item.suggestion)
                        context.stroke(
                            swiftUIPath,
                            with: .color(style.color),
                            lineWidth: style.emphasized ? 3 : 1.5
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityIdentifier("traceCanvas")
            .accessibilityValue("\(session.visible.count) paths")
            .overlay {
                TouchOverlay(eraserActive: eraserMode) { location in
                    let imagePoint = SIMD2(
                        (location.x - fit.offset.width) / fit.scale,
                        (location.y - fit.offset.height) / fit.scale
                    )
                    session.eraseSweep(at: imagePoint)
                } onTwoFingerTap: {
                    session.undoErase()
                }
            }
        }
        .background(Color(.systemBackground))
    }

    private func color(for suggestion: RemovalReason?) -> (color: Color, emphasized: Bool) {
        switch suggestion {
        case .enclosingLoop: (.red, true)
        case .textLike: (.blue, true)
        case .edgeArtifact: (.orange, true)
        case nil: (.primary, false)
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
