import SwiftUI

/// The screens a drawing moves through on its way from photo to DXF.
enum Route: Hashable {
    case capture
    case refineMask(projectID: UUID)
    case trace(projectID: UUID)
    case export(projectID: UUID)
}

struct RootView: View {
    @State private var path: [Route] = []
    @State private var store = ProjectStore()

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(path: $path)
                .onAppear {
                    try? store.loadAll()
                    openDemoImageIfRequested()
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .capture:
                        CaptureView(path: $path)
                    case .refineMask(let projectID):
                        StagePlaceholderView(
                            title: "Refine Outline",
                            systemImage: "lasso.badge.sparkles",
                            detail: "SAM 2 proposes the subject; tap to add or remove regions.",
                            next: .trace(projectID: projectID),
                            path: $path
                        )
                    case .trace(let projectID):
                        TraceView(path: $path, projectID: projectID)
                    case .export(let projectID):
                        TraceView(path: $path, projectID: projectID)
                    }
                }
        }
        .environment(store)
    }

    /// Test/demo hook: `DEMO_IMAGE=<path>` in the launch environment creates
    /// a project from that image and jumps straight to the trace screen.
    private func openDemoImageIfRequested() {
        #if DEBUG
        guard let demoPath = ProcessInfo.processInfo.environment["DEMO_IMAGE"],
              path.isEmpty else { return }
        do {
            let data = try Data(contentsOf: URL(filePath: demoPath))
            let project = try store.create(title: "Demo Drawing")
            try data.write(to: store.originalImageURL(for: project), options: .atomic)
            path = [.trace(projectID: project.id)]
        } catch {
            print("demo image failed: \(error)")
        }
        #endif
    }
}

#Preview {
    RootView()
}
