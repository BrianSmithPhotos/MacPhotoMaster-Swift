import SwiftUI
import MacPhotoMasterCore

/// iPad counterpart to the macOS app's `MetadataPanelView`, shown as a resizable sheet from a
/// toolbar button (see `ContentView`) rather than a fixed inspector column — see
/// docs/ARCHITECTURE.md's iPad file access section for why a sheet was chosen over `.inspector`'s
/// auto-collapse.
///
/// Description and keywords are editable and save through `PhotoBrowserViewModel.saveMetadata`,
/// which stages a sidecar via `SidecarStagingStore` rather than touching the original file — see
/// docs/ARCHITECTURE.md's "iPad file access & sidecar staging" section. Three save-scope buttons
/// mirror the Mac app's: This File (the previewed asset), Capture Set (every member of the
/// selected grid tile's set), and Current Selection (the grid's multi-selection, when active).
/// Title stays read-only here, same as the Mac app: it's a live rename preview computed by
/// `PhotoBrowserViewModel.titlePreview`, never independently typed — the "Batch" field is what
/// actually drives it (docs/SPEC.md §4's manual per-session label). Renaming itself only takes
/// effect on the destination copy made at Process & Move time. GPS stays read-only: no lat/long
/// editing on iPad yet.
///
/// Process & Move mirrors the Mac app's four-button row (Single Image/Capture Set/Current
/// Selection/Session), calling `PhotoBrowserViewModel.process(scope:)` directly — unlike the Mac
/// app, there's no library-folder picker here at all: `viewModel.libraryRootURL` is a fixed local
/// staging folder inside the app's own container, not something the user chooses (see that
/// property's doc comment for why).
struct MetadataPanelView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel

    private var asset: PhotoAsset? { viewModel.previewAsset }

    var body: some View {
        NavigationStack {
            Group {
                if let asset {
                    Form {
                        Section("Title & Description") {
                            LabeledContent("Title", value: viewModel.titlePreview)
                            TextField("Batch", text: $viewModel.sessionBatch)
                            TextField("Description", text: $viewModel.editableDescription, axis: .vertical)
                            TextField("Keywords (comma-separated)", text: $viewModel.editableKeywords, axis: .vertical)
                        }
                        Section {
                            Button("Save (This File)") {
                                viewModel.saveMetadata(scope: .singleAsset(asset))
                            }
                            .disabled(viewModel.isSavingMetadata)

                            Button("Save (Capture Set)") {
                                guard let captureSet = viewModel.selectedCaptureSet else { return }
                                viewModel.saveMetadata(scope: .captureSet(captureSet))
                            }
                            .disabled(viewModel.selectedCaptureSet == nil || viewModel.isSavingMetadata)

                            Button("Save (Current Selection)") {
                                let assets = viewModel.manualSelectionAssets
                                guard !assets.isEmpty else { return }
                                viewModel.saveMetadata(scope: .manualSelection(assets))
                            }
                            .disabled(!viewModel.hasMultiSelection || viewModel.isSavingMetadata)

                            if let saveStatusMessage = viewModel.saveStatusMessage {
                                Text(saveStatusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                        Section("Process & Move") {
                            LabeledContent("Library Folder", value: viewModel.libraryRootURL.lastPathComponent)

                            Button("Process (This File)") {
                                viewModel.process(scope: .singleAsset(asset))
                            }
                            .disabled(viewModel.isProcessing)

                            Button("Process (Capture Set)") {
                                guard let captureSet = viewModel.selectedCaptureSet else { return }
                                viewModel.process(scope: .captureSet(captureSet))
                            }
                            .disabled(viewModel.selectedCaptureSet == nil || viewModel.isProcessing)

                            Button("Process (Current Selection)") {
                                let assets = viewModel.manualSelectionAssets
                                guard !assets.isEmpty else { return }
                                viewModel.process(scope: .manualSelection(assets))
                            }
                            .disabled(!viewModel.hasMultiSelection || viewModel.isProcessing)

                            Button("Process (Session)") {
                                viewModel.process(scope: .session(viewModel.captureSets))
                            }
                            .disabled(viewModel.captureSets.isEmpty || viewModel.isProcessing)

                            if let processStatusMessage = viewModel.processStatusMessage {
                                Text(processStatusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
