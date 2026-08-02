import SwiftUI

/// Home screen: the local library of drawing projects.
/// Real project storage arrives with the data-model task; for now this is the
/// navigation shell with an empty state.
struct LibraryView: View {
    @Binding var path: [Route]

    var body: some View {
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
        .navigationTitle("Draw'n'Cut")
    }
}

#Preview {
    NavigationStack {
        LibraryView(path: .constant([]))
    }
}
