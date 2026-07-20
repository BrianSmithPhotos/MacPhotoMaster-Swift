import SwiftUI
import UniformTypeIdentifiers
import MacPhotoMasterCore

/// iPad Settings sheet — the counterpart to the Mac app's Cmd+, Settings window. For now it hosts
/// only Timeline (GPS) setup: the iPad can't reach Google Drive as a mounted filesystem path the way
/// the Mac's `TimelineDriveSync` does, so the user locates `Timeline.json` once through the Files
/// document picker and the app persists a security-scoped bookmark to re-import it silently on later
/// launches (see `PhotoBrowserViewModel.locateTimelineFile` and docs/ARCHITECTURE.md's iPad
/// file-access section), plus the OpenRouter API key for AI suggestions (step 8). The AI model
/// itself is picked per-photo in `MetadataPanelView`, not here. eBird key + subject-isolation
/// settings will join this sheet in step 8b.
struct SettingsView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isLocatingTimeline = false
    /// Mirror of the Keychain-stored OpenRouter key, edited via the `SecureField` below. Loaded in
    /// `.onAppear` and written straight back to the Keychain on change — never persisted anywhere
    /// else (a `UserDefaults` secret would be a cleartext plist). See `APIKeyStore`.
    @State private var openRouterAPIKey = ""

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

                Section {
                    SecureField("OpenRouter API key", text: $openRouterAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: openRouterAPIKey) { _, newValue in
                            APIKeyStore.save(newValue, account: "OPENROUTER_API_KEY")
                        }
                } header: {
                    Text("API Keys")
                } footer: {
                    Text(
                        "Needed only for openrouter: models. On-device mlx: models (e.g. FastVLM) need "
                        + "no key. Stored securely in the device Keychain.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                openRouterAPIKey = APIKeyStore.read(account: "OPENROUTER_API_KEY") ?? ""
            }
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
