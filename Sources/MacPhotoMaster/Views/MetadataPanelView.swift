import SwiftUI
import UniformTypeIdentifiers

/// Editable metadata fields + AI/GPS/save/process actions. See docs/SPEC.md §2-7.
///
/// Read-only for now: `ExifToolClient`'s write path (spec §3) doesn't exist yet, so there's
/// nowhere for an edit to go. Fields display what `NativeMetadataReader` read for the current
/// selection; editing/Save/AI/rename actions come once the write path is built. Process/move
/// (spec §5) is wired below the fields, mirroring the Python reference app's `metadata_panel`
/// button row rather than a source-panel button or right-click menu — it's the last action taken
/// once editing an SD card's images is done, so it belongs at the foot of this pane.
struct MetadataPanelView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @State private var isChoosingLibraryFolder = false
    /// Set right before showing the library-folder picker for a process action that ran with no
    /// library root configured yet, so the picker's completion handler knows to run that action
    /// once the pick resolves. Normal path is Settings (Cmd+,); this is just a fallback so a first
    /// run isn't a dead end.
    @State private var pendingProcessScope: ProcessMoveScope?

    private var asset: PhotoAsset? { viewModel.selectedAsset }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
                .padding([.top, .horizontal])

            if let asset {
                Form {
                    LabeledContent("Title", value: asset.title)
                    LabeledContent("Description", value: asset.descriptionText)
                    LabeledContent("Keywords", value: asset.keywords.joined(separator: ", "))
                    LabeledContent("Camera", value: asset.cameraModel)
                    LabeledContent("Lens", value: asset.lensModel)
                    LabeledContent("Aperture", value: asset.aperture)
                    LabeledContent("Shutter", value: asset.shutterSpeed)
                    LabeledContent("Focal length", value: asset.focalLength)
                    LabeledContent("ISO", value: asset.iso)
                    if let capturedAt = asset.capturedAt {
                        LabeledContent("Captured", value: capturedAt.formatted())
                    }
                    if let latitude = asset.gpsLatitude, let longitude = asset.gpsLongitude {
                        LabeledContent("GPS", value: "\(latitude), \(longitude)")
                    }
                }
                .formStyle(.grouped)
            } else {
                Spacer()
                Text("Select a photo to see its metadata.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }

            processMoveSection
        }
        .fileImporter(isPresented: $isChoosingLibraryFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            viewModel.setLibraryRoot(url)
            if let pendingProcessScope {
                viewModel.process(scope: pendingProcessScope, libraryRoot: url)
                self.pendingProcessScope = nil
            }
        }
    }

    private var processMoveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Process & Move")
                .font(.subheadline.bold())

            HStack(spacing: 6) {
                Button("Single Image") {
                    guard let asset = viewModel.selectedAsset else { return }
                    requestProcess(.singleAsset(asset))
                }
                .disabled(viewModel.selectedAsset == nil || viewModel.isProcessing)

                Button("Capture Set") {
                    guard let captureSet = viewModel.selectedCaptureSet else { return }
                    requestProcess(.captureSet(captureSet))
                }
                .disabled(viewModel.selectedCaptureSet == nil || viewModel.isProcessing)

                Button("Session") { requestProcess(.session(viewModel.captureSets)) }
                    .disabled(viewModel.captureSets.isEmpty || viewModel.isProcessing)
            }

            if let processStatusMessage = viewModel.processStatusMessage {
                Text(processStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .bottom])
    }

    /// Runs `scope` against the persisted library root, prompting for one first (via the
    /// library-folder `.fileImporter` above) if none has been set in Settings yet.
    private func requestProcess(_ scope: ProcessMoveScope) {
        guard let libraryRootURL = viewModel.libraryRootURL else {
            pendingProcessScope = scope
            isChoosingLibraryFolder = true
            return
        }
        viewModel.process(scope: scope, libraryRoot: libraryRootURL)
    }
}

#Preview {
    MetadataPanelView(viewModel: SourceBrowserViewModel())
}
