import SwiftUI

/// Stand-in for the camera capture flow. The real implementation (camera,
/// quarter detection, rectification) replaces this in the capture feature tasks.
struct CapturePlaceholderView: View {
    @Binding var path: [Route]

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Camera capture goes here")
                .font(.headline)
            Text("Include a quarter in the shot — it corrects the camera angle and sets the real-world size.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Simulate Capture") {
                path.append(.refineMask(projectID: UUID()))
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("New Drawing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        CapturePlaceholderView(path: .constant([]))
    }
}
