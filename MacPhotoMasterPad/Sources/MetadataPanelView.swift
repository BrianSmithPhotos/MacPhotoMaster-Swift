import SwiftUI
import MacPhotoMasterCore

/// iPad counterpart to the macOS app's `MetadataPanelView`, shown as a resizable sheet from a
/// toolbar button (see `ContentView`) rather than a fixed inspector column — see
/// docs/ARCHITECTURE.md's iPad file access section for why a sheet was chosen over `.inspector`'s
/// auto-collapse.
///
/// Read-only for now: editing needs somewhere to save to, and on iPad that's the staged-sidecar
/// model described in docs/SPEC.md §3's "iPad divergence" note, which isn't built yet — wiring up
/// editable fields ahead of that would just be a text box that silently discards what you type.
/// This intentionally stops at displaying what `NativeMetadataReader` already read.
struct MetadataPanelView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel

    private var asset: PhotoAsset? { viewModel.previewAsset }

    var body: some View {
        NavigationStack {
            Group {
                if let asset {
                    Form {
                        Section("Title & Description") {
                            LabeledContent("Title", value: asset.title)
                            LabeledContent("Description", value: asset.descriptionText.isEmpty ? "—" : asset.descriptionText)
                            LabeledContent("Keywords", value: asset.keywords.isEmpty ? "—" : asset.keywords.joined(separator: ", "))
                        }
                        Section("Camera") {
                            LabeledContent("Camera", value: asset.cameraModel)
                            LabeledContent("Lens", value: asset.lensModel)
                            LabeledContent("Aperture", value: asset.aperture)
                            LabeledContent("Shutter", value: asset.shutterSpeed)
                            LabeledContent("Focal length", value: asset.focalLength)
                            LabeledContent("ISO", value: asset.iso)
                            if let capturedAt = asset.capturedAt {
                                LabeledContent("Captured", value: capturedAt.formatted())
                            }
                        }
                        if asset.gpsLatitude != nil || asset.gpsLongitude != nil {
                            Section("Location") {
                                LabeledContent("Latitude", value: asset.gpsLatitude.map { String(format: "%.5f", $0) } ?? "—")
                                LabeledContent("Longitude", value: asset.gpsLongitude.map { String(format: "%.5f", $0) } ?? "—")
                                LabeledContent("Altitude", value: asset.gpsAltitude.map { String(format: "%.0f m", $0) } ?? "—")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Photo Selected", systemImage: "photo", description: Text("Select a photo to see its metadata."))
                }
            }
            .navigationTitle(asset?.url.lastPathComponent ?? "Metadata")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    MetadataPanelView(viewModel: PhotoBrowserViewModel())
}
