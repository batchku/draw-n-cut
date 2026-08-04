import SwiftUI
import simd

/// The refine-outline screen: tap the drawing to let SAM 2 select the
/// subject, refine with add/remove points, then either carry the mask into
/// tracing ("Use Outline" — the mask boundary becomes the CUT path) or skip
/// straight to tracing everything.
struct RefineMaskView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: [Route]
    let projectID: UUID

    @State private var session: RefineMaskSession?
    @State private var saveError: String?

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ProgressView("Loading…")
            }
        }
        .navigationTitle("Select the Drawing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil,
                  let project = store.projects.first(where: { $0.id == projectID }) else { return }
            let newSession = RefineMaskSession(project: project, store: store)
            session = newSession
            await newSession.load()
        }
    }

    @ViewBuilder
    private func content(_ session: RefineMaskSession) -> some View {
        VStack(spacing: 0) {
            RefineCanvas(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { statusBanner(session) }
                .overlay { phaseOverlay(session) }

            controls(session)
        }
    }

    @ViewBuilder
    private func statusBanner(_ session: RefineMaskSession) -> some View {
        if let text = bannerText(session) {
            Text(text)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    private func bannerText(_ session: RefineMaskSession) -> String? {
        switch session.phase {
        case .ready, .segmenting:
            if session.points.isEmpty {
                return "Tap the drawing to select it."
            }
            // A miss (huge mask: SAM grabbed the paper) or an empty decode
            // both mean the tap didn't land on the subject.
            if session.maskLooksLikeMiss || (session.mask == nil && session.phase == .ready) {
                return "Tap directly on the drawn lines."
            }
            if session.points.count >= SAM2Segmenter.maxPromptPoints {
                return "Marker limit reached — tap a marker to delete one first."
            }
            if session.removeMode {
                return "Tap an area to remove it from the selection."
            }
            return nil
        case .loadingModels, .encoding, .failed:
            return nil
        }
    }

    @ViewBuilder
    private func phaseOverlay(_ session: RefineMaskSession) -> some View {
        switch session.phase {
        case .loadingModels:
            ProgressView("Loading subject selection…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .encoding:
            ProgressView("Reading the photo…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            ContentUnavailableView {
                Label("Selection Unavailable", systemImage: "lasso.badge.sparkles")
            } description: {
                Text("\(message)\nYou can still trace the whole photo.")
            }
        case .ready, .segmenting:
            EmptyView()
        }
    }

    private func controls(_ session: RefineMaskSession) -> some View {
        @Bindable var session = session
        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                // Two-state mode switch, styled like the markers the taps
                // leave behind.
                HStack(spacing: 8) {
                    modeButton("Add Area", isRemove: false, session: session)
                    modeButton("Remove Area", isRemove: true, session: session)
                        .disabled(session.mask == nil)
                }
                Spacer()
                if session.phase == .segmenting {
                    ProgressView()
                }
                Button("Reset") { session.reset() }
                    .disabled(session.points.isEmpty)
            }
            HStack(spacing: 12) {
                Button {
                    session.discardSavedMask()
                    // Replace the stack: a fresh trace screen (stale ones
                    // would show the old outline), with back → library.
                    path = [.trace(projectID: projectID)]
                } label: {
                    Text("Trace Everything")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    do {
                        try session.saveMask()
                        path = [.trace(projectID: projectID)]
                    } catch {
                        saveError = "Couldn't save the outline: \(error.localizedDescription)"
                    }
                } label: {
                    Text("Use Outline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.mask == nil)
            }
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.bar)
    }

    /// One side of the Add/Remove switch: the same white-on-green plus or
    /// white-on-red minus the user's taps drop onto the photo.
    private func modeButton(_ title: String, isRemove: Bool, session: RefineMaskSession) -> some View {
        let color: Color = isRemove ? .red : .green
        let selected = session.removeMode == isRemove
        return Button {
            session.removeMode = isRemove
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRemove ? "minus.circle.fill" : "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, color)
                Text(title)
                    .foregroundStyle(selected ? color : .secondary)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? color.opacity(0.15) : Color(.systemGray6), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The photo with the mask tint, prompt-point markers, tap capture, and
/// pinch zoom / pan (same transform model as the trace canvas). A tap near
/// an existing marker removes it; anywhere else it adds a prompt.
private struct RefineCanvas: View {
    let session: RefineMaskSession

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero

    /// How close (in screen points) a tap must land to a marker to delete it.
    private let markerHitRadius: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(
                width: session.image.map { CGFloat($0.width) } ?? 1,
                height: session.image.map { CGFloat($0.height) } ?? 1
            )
            let fit = fitTransform(imageSize: imageSize, into: geometry.size)
            let scale = fit.scale * zoom
            let offset = CGSize(
                width: fit.offset.width * zoom + panOffset.width,
                height: fit.offset.height * zoom + panOffset.height
            )
            let fittedSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )

            ZStack(alignment: .topLeading) {
                if let image = session.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .offset(x: offset.width, y: offset.height)
                }
                if let maskImage = session.maskImage {
                    Image(decorative: maskImage, scale: 1)
                        .resizable()
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .offset(x: offset.width, y: offset.height)
                        .allowsHitTesting(false)
                }
                ForEach(Array(session.points.enumerated()), id: \.offset) { _, prompt in
                    Image(systemName: prompt.isSubject ? "plus.circle.fill" : "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, prompt.isSubject ? .green : .red)
                        .position(
                            x: prompt.point.x * scale + offset.width,
                            y: prompt.point.y * scale + offset.height
                        )
                        .allowsHitTesting(false)
                }
                Color.clear
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .offset(x: offset.width, y: offset.height)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier("refineImageArea")
                    .accessibilityValue(maskDescription)
            }
            .contentShape(Rectangle())
            .overlay {
                TouchOverlay(
                    eraserActive: false,
                    onErase: { _, _ in },
                    onEraseEnd: {},
                    onPan: { delta in
                        panOffset.width += delta.x
                        panOffset.height += delta.y
                        clampPan(viewport: geometry.size)
                    },
                    onPinch: { scaleDelta, centroid in
                        let newZoom = min(8, max(1, zoom * scaleDelta))
                        let applied = newZoom / zoom
                        // Keep the pinch centroid stationary on screen.
                        panOffset.width = centroid.x - (centroid.x - panOffset.width) * applied
                        panOffset.height = centroid.y - (centroid.y - panOffset.height) * applied
                        zoom = newZoom
                        clampPan(viewport: geometry.size)
                    },
                    onTwoFingerTap: {},
                    onSingleTap: { location in
                        session.handleTap(
                            atImage: SIMD2(
                                (location.x - offset.width) / scale,
                                (location.y - offset.height) / scale
                            ),
                            hitRadius: markerHitRadius / scale
                        )
                    }
                )
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

    private var maskDescription: String {
        guard let mask = session.mask else { return "no mask" }
        return "mask \(Int(mask.inkFraction * 100))%"
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
