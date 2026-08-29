import ImageIO
import SwiftUI

/// Home screen: the local library of drawing projects.
struct LibraryView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: [Route]
    /// Bumped as backfilled thumbnails land, so rows reload from disk.
    @State private var thumbnailGeneration = 0

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("Draw'n'Cut")
        .task(id: store.projects.count) { await backfillThumbnails() }
        .toolbar {
            if !store.projects.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        path.append(.capture)
                    } label: {
                        Label("New Drawing", systemImage: "camera.fill")
                    }
                }
            }
        }
    }

    /// Fills in thumbnails for drawings last traced before thumbnails
    /// existed. One at a time and off the main actor: a library of drawings
    /// tracing all at once would make the list unusable while it worked.
    private func backfillThumbnails() async {
        for job in store.thumbnailJobs() {
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                ThumbnailBuilder.build(
                    photoURL: job.photoURL,
                    maskURL: job.maskURL,
                    settings: ThumbnailBuilder.settings(atVersionPath: job.versionURL),
                    to: job.destination
                )
            }.value
            // Nudge the rows so each thumbnail appears as it lands rather
            // than the whole library changing at the end.
            thumbnailGeneration += 1
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Drawings Yet", systemImage: "scribble.variable")
        } description: {
            Text("Photograph a drawing and Draw'n'Cut will turn it into a laser-cuttable file.")
        } actions: {
            Button {
                path.append(.capture)
            } label: {
                Label("New Drawing", systemImage: "camera.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var projectList: some View {
        List {
            ForEach(store.projects) { project in
                NavigationLink(value: Route.trace(projectID: project.id)) {
                    HStack(spacing: 12) {
                        ProjectThumbnail(url: store.thumbnailURL(for: project),
                                         version: project.updatedAt,
                                         generation: thumbnailGeneration)
                        VStack(alignment: .leading, spacing: 4) {
                        Text(project.title)
                            .font(.headline)
                        HStack(spacing: 8) {
                            Text(project.updatedAt, format: .dateTime.month().day().hour().minute())
                            if !project.traceVersions.isEmpty {
                                Text("v\(project.traceVersions.count)")
                                    .padding(.horizontal, 6)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("projectRow")
            }
            .onDelete { offsets in
                for offset in offsets {
                    try? store.delete(store.projects[offset])
                }
            }
        }
    }
}

/// One library row's picture. Loading happens in `.task` rather than in the
/// row body so scrolling never blocks on disk, and it reloads when the
/// project changes because the file is rewritten in place at the same URL.
private struct ProjectThumbnail: View {
    let url: URL
    /// Not read, but a change to either re-runs the load: the path is stable,
    /// so what says the picture changed is the project's own date, or the
    /// backfill reporting that it has written another one.
    let version: Date
    let generation: Int

    @State private var image: CGImage?

    private static let side: CGFloat = 56

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Not "missing" — a drawing traced before thumbnails existed
                // gets one the next time it is opened.
                Image(systemName: "scribble.variable")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityHidden(true)
        .task(id: "\(version.timeIntervalSince1970)-\(generation)") {
            if let loaded = await Self.load(url) { image = loaded }
        }
    }

    private static func load(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2 * side,
            ] as CFDictionary)
        }.value
    }
}

#Preview {
    NavigationStack {
        LibraryView(path: .constant([]))
    }
    .environment(ProjectStore())
}
