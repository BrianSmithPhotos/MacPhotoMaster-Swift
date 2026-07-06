import SwiftUI
import UniformTypeIdentifiers

/// App preferences (Cmd+,). Currently the process/move destination root (docs/SPEC.md §5), the
/// manual Timeline Drive-sync trigger, and per-OpenRouter-model eBird candidate-list toggles — all
/// "rarely touched" actions, so they live in their own Settings scene rather than a header button
/// in the main window.
struct SettingsView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @State private var isChoosingFolder = false

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
        }
        .padding()
        .frame(width: 420)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                viewModel.setLibraryRoot(url)
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: SourceBrowserViewModel())
}
