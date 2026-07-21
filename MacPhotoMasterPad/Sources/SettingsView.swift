import SwiftUI
import UniformTypeIdentifiers
import MacPhotoMasterCore

/// iPad Settings sheet — the counterpart to the Mac app's Cmd+, Settings window. For now it hosts
/// only Timeline (GPS) setup: the iPad can't reach Google Drive as a mounted filesystem path the way
/// the Mac's `TimelineDriveSync` does, so the user locates `Timeline.json` once through the Files
/// document picker and the app persists a security-scoped bookmark to re-import it silently on later
/// launches (see `PhotoBrowserViewModel.locateTimelineFile` and docs/ARCHITECTURE.md's iPad
/// file-access section), the OpenRouter + eBird API keys, a per-model Compact Prompt toggle (small
/// on-device models), and a per-model eBird candidate-list toggle (chargeable OpenRouter models). The
/// AI model itself is picked per-photo in `MetadataPanelView`, not here.
struct SettingsView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isLocatingTimeline = false
    /// Mirrors of the Keychain-stored API keys, edited via the `SecureField`s below. Loaded in
    /// `.onAppear` and written straight back to the Keychain on change — never persisted anywhere
    /// else (a `UserDefaults` secret would be a cleartext plist). See `APIKeyStore`.
    @State private var openRouterAPIKey = ""
    @State private var eBirdAPIKey = ""

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
                    SecureField("eBird API key", text: $eBirdAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: eBirdAPIKey) { _, newValue in
                            APIKeyStore.save(newValue, account: "EBIRD_API_KEY")
                        }
                } header: {
                    Text("API Keys")
                } footer: {
                    Text(
                        "OpenRouter: needed for openrouter: models (on-device mlx: models need none). "
                        + "eBird: enables the local-species candidate list that improves bird ID. Both "
                        + "stored securely in the device Keychain.")
                }

                Section {
                    ForEach(viewModel.aiModelPresets.filter { $0.hasPrefix("openrouter:") }, id: \.self) { model in
                        Toggle(
                            model,
                            isOn: Binding(
                                get: { !viewModel.eBirdDisabledModels.contains(model) },
                                set: { viewModel.setEBirdCandidateListEnabled($0, forModel: model) }))
                    }
                } header: {
                    Text("eBird Candidate List (OpenRouter)")
                } footer: {
                    Text(
                        "The eBird species list adds input tokens (cost) on chargeable OpenRouter models, "
                        + "so it's off by default for them. On-device mlx: models always use it (free "
                        + "compute, and where it helps most). Needs an eBird API key above.")
                }

                Section {
                    ForEach(viewModel.aiModelPresets, id: \.self) { model in
                        Toggle(
                            model,
                            isOn: Binding(
                                get: { viewModel.compactPromptModels.contains(model) },
                                set: { viewModel.setCompactPrompt($0, forModel: model) }))
                    }
                } header: {
                    Text("Compact Prompt")
                } footer: {
                    Text(
                        "Turn on for small models that echo placeholder keywords or over-apply bird/flower "
                        + "identification (e.g. FastVLM-0.5B). Larger models work better with it off.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                openRouterAPIKey = APIKeyStore.read(account: "OPENROUTER_API_KEY") ?? ""
                eBirdAPIKey = APIKeyStore.read(account: "EBIRD_API_KEY") ?? ""
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
