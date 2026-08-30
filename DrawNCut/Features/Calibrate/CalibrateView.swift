import CoreGraphics
import ImageIO
import SwiftUI
import simd

/// Offers the coin correction, and never applies it without being asked.
///
/// Detection is good, not certain, and a wrong correction silently warps a
/// drawing the user then works on for ten minutes. So the coin it found is
/// drawn on the photo, the measured tilt and size are stated, and nothing is
/// written until "Straighten It" is tapped. Skipping leaves the photo exactly
/// as shot.
struct CalibrateView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: [Route]
    let projectID: UUID

    @State private var photo: CGImage?
    @State private var candidate: CoinCandidate?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .navigationTitle("Straighten the Photo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                if let photo {
                    Image(decorative: photo, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                if let photo, let candidate {
                    CoinOverlay(
                        ellipse: candidate.ellipse,
                        imageSize: CGSize(width: photo.width, height: photo.height),
                        viewport: geometry.size
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let candidate {
                Text("Found a coin, tilted \(Int(candidate.ellipse.tilt * 180 / .pi))°.")
                    .font(.subheadline.bold())
                Text("Straightening squares the drawing up and sets its real size, so exports come out to scale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let failure {
                Text(failure)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView("Looking for a coin…")
            }

            HStack(spacing: 12) {
                Button {
                    proceed()
                } label: {
                    Text("Skip").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("skipCalibration")

                Button {
                    Task { await straighten() }
                } label: {
                    if working {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Straighten It").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(candidate == nil || working)
                .accessibilityIdentifier("applyCalibration")
            }
        }
        .padding()
        .background(.bar)
    }

    private func load() async {
        guard photo == nil, let project = store.projects.first(where: { $0.id == projectID })
        else { return }
        let url = store.originalImageURL(for: project)
        let found = await Task.detached(priority: .userInitiated) {
            () -> (CGImage, CoinCandidate?)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 2000,
                  ] as CFDictionary) else { return nil }
            return (image, CoinDetector.detect(in: image))
        }.value
        photo = found?.0
        candidate = found?.1
        if candidate == nil {
            failure = "No coin found in this photo. You can carry on without straightening."
        }
    }

    private func straighten() async {
        guard let project = store.projects.first(where: { $0.id == projectID }),
              let candidate else { return }
        working = true
        defer { working = false }

        let originalURL = store.originalImageURL(for: project)
        let rectifiedURL = store.rectifiedImageURL(for: project)
        let ellipse = candidate.ellipse

        let scale = await Task.detached(priority: .userInitiated) { () -> Double? in
            // Re-decode at full size: the correction is written from the
            // photo as shot, not from the preview-sized copy it was found in.
            guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil),
                  let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            // The ellipse was measured on the 2000px preview; rescale it.
            let factor = Double(full.width) / Double(min(full.width, 2000))
            let scaled = FittedEllipse(
                center: ellipse.center * factor,
                semiMajor: ellipse.semiMajor * factor,
                semiMinor: ellipse.semiMinor * factor,
                angle: ellipse.angle
            )
            guard let rectifier = CoinRectifier(ellipse: scaled),
                  let corrected = rectifier.rectified(full),
                  let destination = CGImageDestinationCreateWithURL(
                    rectifiedURL as CFURL, "public.png" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, corrected, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            // Millimetres per pixel of the *written* image, which may have
            // been capped smaller than the correction's own frame.
            let widthRatio = Double(corrected.width) / rectifier.correctedBounds(
                of: CGSize(width: full.width, height: full.height)).width
            return rectifier.millimetersPerPixel / widthRatio
        }.value

        if let scale {
            var updated = project
            updated.scale = ScaleInfo(millimetersPerPixel: scale, source: .quarter)
            try? store.save(updated)
        } else {
            failure = "Couldn't straighten this photo. Carrying on with the original."
        }
        proceed()
    }

    private func proceed() {
        path = [.refineMask(projectID: projectID)]
    }
}

/// Draws the detected coin over the photo, letter-boxed the same way the
/// image is, so the user can see what the app actually found.
private struct CoinOverlay: View {
    let ellipse: FittedEllipse
    let imageSize: CGSize
    let viewport: CGSize

    var body: some View {
        Canvas { context, _ in
            let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
            let inset = CGSize(
                width: (viewport.width - imageSize.width * scale) / 2,
                height: (viewport.height - imageSize.height * scale) / 2
            )
            var path = Path()
            let samples = 90
            for i in 0...samples {
                let t = Double(i) / Double(samples) * 2 * .pi
                let local = SIMD2(ellipse.semiMajor * cos(t), ellipse.semiMinor * sin(t))
                let rotated = SIMD2(
                    local.x * cos(ellipse.angle) - local.y * sin(ellipse.angle),
                    local.x * sin(ellipse.angle) + local.y * cos(ellipse.angle)
                )
                let point = CGPoint(
                    x: (ellipse.center.x + rotated.x) * scale + inset.width,
                    y: (ellipse.center.y + rotated.y) * scale + inset.height
                )
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.green), lineWidth: 3)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("coinOverlay")
    }
}
