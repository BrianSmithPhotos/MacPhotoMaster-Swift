import SwiftUI
import UniformTypeIdentifiers

/// App preferences (Cmd+,). Currently the process/move destination root (docs/SPEC.md §5), the
/// manual Timeline Drive-sync trigger, and per-OpenRouter-model eBird candidate-list toggles — all
/// "rarely touched" actions, so they live in their own Settings scene rather than a header button
/// in the main window.
struct SettingsView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @State private var isChoosingFolder = false
    @State private var eBirdAPIKey = ""
    @State private var openRouterAPIKey = ""

    /// Only OpenRouter presets get a toggle here — Ollama/MLX always send the candidate list (it's
    /// free, local compute), see `SourceBrowserViewModel.eBirdDisabledModels`'s doc comment.
    private var openRouterPresets: [String] {
        AIModelSelection.presets.filter { AIModelSelection.parse($0)?.providerID == .openRouter }
    }

    var body: some View {
        Form {
            LabeledContent("Library Folder") {
                HStack {
                    Text(viewModel.libraryRootURL?.path ?? "Not set")
                        .foregroundStyle(viewModel.libraryRootURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { isChoosingFolder = true }
                }
            }

            LabeledContent("Timeline") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Refresh Timeline") { Task { await viewModel.refreshTimeline() } }
                        .disabled(viewModel.isSyncingTimeline)
                    if let message = viewModel.timelineSyncStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("eBird Candidate List (OpenRouter)") {
                ForEach(openRouterPresets, id: \.self) { model in
                    Toggle(
                        model,
                        isOn: Binding(
                            get: { !viewModel.eBirdDisabledModels.contains(model) },
                            set: { viewModel.setEBirdCandidateListEnabled($0, forModel: model) }
                        ))
                }
            }

            Section("API Keys") {
                apiKeyRow(
                    title: "eBird", envVar: "EBIRD_API_KEY", account: "EBIRD_API_KEY",
                    value: $eBirdAPIKey)
                apiKeyRow(
                    title: "OpenRouter", envVar: "OPENROUTER_API_KEY", account: "OPENROUTER_API_KEY",
                    value: $openRouterAPIKey)
            }
        }
        .padding()
        .frame(width: 420)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                viewModel.setLibraryRoot(url)
            }
        }
        .task {
            eBirdAPIKey = APIKeyStore.read(account: "EBIRD_API_KEY") ?? ""
            openRouterAPIKey = APIKeyStore.read(account: "OPENROUTER_API_KEY") ?? ""
        }
    }

    /// Stored in the Keychain via `APIKeyStore`, not `UserDefaults` — a cleartext plist isn't
    /// appropriate for secrets. Disabled (and explained) when `envVar` is set in this process's
    /// environment, since that always takes priority over whatever's saved here — editing the
    /// field in that case would silently have no effect.
    @ViewBuilder
    private func apiKeyRow(title: String, envVar: String, account: String, value: Binding<String>)
        -> some View
    {
        let envOverride = ProcessInfo.processInfo.environment[envVar]
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                SecureField("Not set", text: value)
                    .disabled(envOverride != nil)
                    .onChange(of: value.wrappedValue) { _, newValue in
                        APIKeyStore.save(newValue, account: account)
                    }
                if envOverride != nil {
                    Text("Overridden by \(envVar) environment variable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: SourceBrowserViewModel())
}
