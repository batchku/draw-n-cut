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
                Toggle(isOn: $session.removeMode) {
                    Label("Remove Area", systemImage: "minus.circle")
                        .font(.callout)
                }
                .toggleStyle(.button)
                .disabled(session.mask == nil)
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
                    path.append(.trace(projectID: projectID))
                } label: {
                    Text("Trace Everything")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    do {
                        try session.saveMask()
                        path.append(.trace(projectID: projectID))
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
}

/// The photo with the mask tint, prompt-point markers, and tap capture.
/// The tap layer sits exactly over the fitted image so view→image mapping
/// is a single scale factor.
private struct RefineCanvas: View {
    let session: RefineMaskSession

    var body: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(
                width: session.image.map { CGFloat($0.width) } ?? 1,
                height: session.image.map { CGFloat($0.height) } ?? 1
            )
            let fit = fitTransform(imageSize: imageSize, into: geometry.size)
            let fittedSize = CGSize(
                width: imageSize.width * fit.scale,
                height: imageSize.height * fit.scale
            )

            ZStack(alignment: .topLeading) {
                if let image = session.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .offset(x: fit.offset.width, y: fit.offset.height)
                }
                if let maskImage = session.maskImage {
                    Image(decorative: maskImage, scale: 1)
                        .resizable()
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .offset(x: fit.offset.width, y: fit.offset.height)
                        .allowsHitTesting(false)
                }
                ForEach(Array(session.points.enumerated()), id: \.offset) { _, prompt in
                    Image(systemName: prompt.isSubject ? "plus.circle.fill" : "minus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, prompt.isSubject ? .green : .red)
                        .position(
                            x: prompt.point.x * fit.scale + fit.offset.width,
                            y: prompt.point.y * fit.scale + fit.offset.height
                        )
                        .allowsHitTesting(false)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .offset(x: fit.offset.width, y: fit.offset.height)
                    .onTapGesture { location in
                        session.addPoint(atImage: SIMD2(
                            location.x / fit.scale,
                            location.y / fit.scale
                        ))
                    }
                    .accessibilityElement()
                    .accessibilityIdentifier("refineImageArea")
                    .accessibilityValue(maskDescription)
            }
        }
        .background(Color(.systemBackground))
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
