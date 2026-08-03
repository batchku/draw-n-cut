import SwiftUI

/// Pick a physical size, write the DXF, share it. Traced lines engrave; the
/// sticker outline (when the subject was selected) cuts. Per-path overrides
/// come with the toggle UI task.
struct ExportSheet: View {
    let session: TraceSession

    @State private var widthMM: Double = 100
    @State private var exportedURL: URL?
    @State private var exportError: String?

    private let presets: [Double] = [60, 100, 150, 200]

    var body: some View {
        NavigationStack {
            Form {
                Section("Physical size") {
                    HStack {
                        Slider(value: $widthMM, in: 30...300, step: 5) {
                            Text("Width")
                        }
                        Text("\(Int(widthMM)) mm")
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                    }
                    Picker("Preset", selection: $widthMM) {
                        ForEach(presets, id: \.self) { preset in
                            Text("\(Int(preset)) mm").tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    let size = DXFExportBuilder.sizeMM(
                        of: session.visible.map(\.polyline),
                        cutOutlines: session.cutOutlines,
                        widthMM: widthMM
                    )
                    LabeledContent("Output", value: "\(Int(size.width)) × \(Int(size.height)) mm")
                }

                Section {
                    if let exportedURL {
                        ShareLink(item: exportedURL) {
                            Label("Share \(exportedURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                        Text("Saved to this drawing's local library.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            do {
                                exportedURL = try session.exportDXF(widthMM: widthMM)
                            } catch {
                                exportError = error.localizedDescription
                            }
                        } label: {
                            Label("Create DXF", systemImage: "doc.badge.gearshape")
                        }
                    }
                    if let exportError {
                        Text(exportError).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    if !session.cutOutlines.isEmpty {
                        Text("DXF layers: CUT for the piece's outline (and any holes), ENGRAVE for all traced lines.")
                    } else {
                        Text("DXF layers: ENGRAVE for all traced lines. Select the drawing on the outline screen to add a CUT outline.")
                    }
                }
            }
            .navigationTitle("Export DXF")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: widthMM) { exportedURL = nil }
        }
    }
}
