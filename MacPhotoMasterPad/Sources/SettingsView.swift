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
/// AI model itself is picked per-photo in `MetadataPanelView`, not here. A "Clear Staged Edits"
/// button lives here too — the only way to discard staged sidecars, which nothing else ever removes
/// (a Process & Move reads a draft and leaves it in place).
struct SettingsView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isLocatingTimeline = false
    /// Mirrors of the Keychain-stored API keys, edited via the `SecureField`s below. Loaded in
    /// `.onAppear` and written straight back to the Keychain on change — never persisted anywhere
    /// else (a `UserDefaults` secret would be a cleartext plist). See `APIKeyStore`.
    @State private var openRouterAPIKey = ""
    @State private var eBirdAPIKey = ""
    @State private var isConfirmingClearStagedEdits = false

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

                Section {
                    Button(role: .destructive) {
                        isConfirmingClearStagedEdits = true
                    } label: {
                        Label("Clear Staged Edits (\(viewModel.stagedEditCount))", systemImage: "trash")
                    }
                    .disabled(viewModel.stagedEditCount == 0)
                    // Confirmed rather than immediate: staged edits are the only copy of work not
                    // yet processed, and the count in the message is what makes "is this the test
                    // run or my afternoon?" answerable before the tap. Attached to the button, not
                    // to the Form: a second presentation modifier on the view that already carries
                    // the Timeline `.fileImporter` is the stacking that leaves a phantom
                    // `PresentationHostingController` behind (see `ContentView.ActiveSheet`) —
                    // which then blocks the sidebar's Open Folder picker after Settings is closed.
                    .confirmationDialog(
                        "Clear \(viewModel.stagedEditCount) staged edit(s)?",
                        isPresented: $isConfirmingClearStagedEdits, titleVisibility: .visible
                    ) {
                        Button("Clear Staged Edits", role: .destructive) {
                            viewModel.clearStagedEdits()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Any description, keyword or location not yet processed into the library is discarded. Photos on the card are unaffected.")
                    }

                    if let message = viewModel.stagedEditsStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Staged Edits")
                } footer: {
                    Text(
                        "Descriptions, keywords and locations saved on this iPad are staged in the app "
                        + "rather than written to the originals on the card, and stay staged even after "
                        + "Process & Move copies them. Clearing discards every one that hasn't been "
                        + "processed — the photos on the card are never touched either way.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                openRouterAPIKey = APIKeyStore.read(account: "OPENROUTER_API_KEY") ?? ""
                eBirdAPIKey = APIKeyStore.read(account: "EBIRD_API_KEY") ?? ""
                viewModel.refreshStagedEditCount()
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
