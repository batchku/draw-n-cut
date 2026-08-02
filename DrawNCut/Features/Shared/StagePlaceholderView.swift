import SwiftUI

/// Generic stand-in for a pipeline stage so the full navigation flow can be
/// walked end to end before the stages are implemented.
struct StagePlaceholderView: View {
    let title: String
    let systemImage: String
    let detail: String
    let next: Route?
    @Binding var path: [Route]

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let next {
                Button("Continue") {
                    path.append(next)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Done") {
                    path.removeAll()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        StagePlaceholderView(
            title: "Trace Details",
            systemImage: "slider.horizontal.below.square.and.square.filled",
            detail: "One Detail slider controls the inner trace.",
            next: nil,
            path: .constant([])
        )
    }
}
