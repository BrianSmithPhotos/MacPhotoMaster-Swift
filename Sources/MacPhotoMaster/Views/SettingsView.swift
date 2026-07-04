import SwiftUI
import UniformTypeIdentifiers

/// App preferences (Cmd+,). Currently the process/move destination root (docs/SPEC.md §5) and the
/// manual Timeline Drive-sync trigger — both "rarely touched" actions, so they live in their own
/// Settings scene rather than a header button in the main window.
struct SettingsView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @State private var isChoosingFolder = false

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
