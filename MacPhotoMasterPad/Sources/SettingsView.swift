import SwiftUI
import UniformTypeIdentifiers
import MacPhotoMasterCore

/// iPad Settings sheet — the counterpart to the Mac app's Cmd+, Settings window. For now it hosts
/// only Timeline (GPS) setup: the iPad can't reach Google Drive as a mounted filesystem path the way
/// the Mac's `TimelineDriveSync` does, so the user locates `Timeline.json` once through the Files
/// document picker and the app persists a security-scoped bookmark to re-import it silently on later
/// launches (see `PhotoBrowserViewModel.locateTimelineFile` and docs/ARCHITECTURE.md's iPad
/// file-access section). AI model + eBird settings (steps 7-8) will join this sheet later.
struct SettingsView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isLocatingTimeline = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        isLocatingTimeline = true
                    } label: {
                        Label(
                            viewModel.hasTimelineBookmark ? "Change Timeline.json…" : "Locate Timeline.json…",
                            systemImage: "mappin.and.ellipse")
                    }

                    Button {
                        viewModel.refreshTimeline()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!viewModel.hasTimelineBookmark || viewModel.isImportingTimeline)

                    if let message = viewModel.timelineStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Timeline (GPS)")
                } footer: {
                    Text(
                        "Pick Timeline.json from Google Drive (turn on \"Available offline\" for it in Drive). "
                        + "Photos taken without GPS get a location suggested from the nearest Timeline point.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // `.plainText` alongside `.json` in case the Drive Files provider types the export as
            // text rather than public.json; the parser validates the contents regardless.
            .fileImporter(isPresented: $isLocatingTimeline, allowedContentTypes: [.json, .plainText]) { result in
                if case .success(let url) = result {
                    viewModel.locateTimelineFile(at: url)
                }
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: PhotoBrowserViewModel())
}
