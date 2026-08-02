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
                Button {
                    path.append(.trace(projectID: project.id))
                } label: {
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
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for offset in offsets {
                    try? store.delete(store.projects[offset])
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LibraryView(path: .constant([]))
    }
    .environment(ProjectStore())
}
