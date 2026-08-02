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

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .capture:
                        CapturePlaceholderView(path: $path)
                    case .refineMask(let projectID):
                        StagePlaceholderView(
                            title: "Refine Outline",
                            systemImage: "lasso.badge.sparkles",
                            detail: "SAM 2 proposes the subject; tap to add or remove regions.",
                            next: .trace(projectID: projectID),
                            path: $path
                        )
                    case .trace(let projectID):
                        StagePlaceholderView(
                            title: "Trace Details",
                            systemImage: "slider.horizontal.below.square.and.square.filled",
                            detail: "One Detail slider controls the inner trace. Every kept setting becomes a version.",
                            next: .export(projectID: projectID),
                            path: $path
                        )
                    case .export:
                        StagePlaceholderView(
                            title: "Export DXF",
                            systemImage: "square.and.arrow.up",
                            detail: "Toggle cut vs engrave per path, then save locally and to Google Drive.",
                            next: nil,
                            path: $path
                        )
                    }
                }
        }
    }
}

#Preview {
    RootView()
}
