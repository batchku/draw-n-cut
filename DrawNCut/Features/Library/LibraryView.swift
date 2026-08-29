import ImageIO
import SwiftUI

/// Home screen: the local library of drawing projects.
struct LibraryView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: [Route]

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
        }
        .navigationTitle("Draw'n'Cut")
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
                                         version: project.updatedAt)
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
    /// Not read, but a change to it re-runs the load: the path is stable, so
    /// the modification date is what says the picture is stale.
    let version: Date

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
        .task(id: version) {
            image = await Self.load(url)
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
