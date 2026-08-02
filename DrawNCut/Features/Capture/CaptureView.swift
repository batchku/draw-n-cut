import PhotosUI
import SwiftUI

/// Capture a drawing: camera on device, photo library anywhere. Creates the
/// project, stores the photo, and moves straight into tracing.
/// (Quarter detection and rectification slot in here in a later task.)
struct CaptureView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: [Route]

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var importError: String?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "scribble.variable")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photograph the drawing straight-on in decent light.\nLay a quarter next to it for true-to-size cutting (coming soon).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if cameraAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if let importError {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Spacer()
            Spacer()
        }
        .navigationTitle("New Drawing")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                start(with: image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) {
            guard let pickerItem else { return }
            Task {
                if let data = try? await pickerItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    start(with: image)
                } else {
                    importError = "Couldn't load that photo."
                }
            }
        }
    }

    private func start(with image: UIImage) {
        do {
            let normalized = image.orientationNormalized()
            guard let jpeg = normalized.jpegData(compressionQuality: 0.9) else {
                importError = "Couldn't read that photo."
                return
            }
            let project = try store.create(title: "Drawing \(store.projects.count + 1)")
            try jpeg.write(to: store.originalImageURL(for: project), options: .atomic)
            path = [.trace(projectID: project.id)]
        } catch {
            importError = "Couldn't save the photo: \(error.localizedDescription)"
        }
    }
}

extension UIImage {
    /// Bakes EXIF orientation into the pixels so `cgImage` sees the photo the
    /// way the user did.
    func orientationNormalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Minimal UIKit camera wrapper.
struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
