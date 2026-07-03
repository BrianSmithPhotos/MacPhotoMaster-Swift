import SwiftUI
import UniformTypeIdentifiers

/// App preferences (Cmd+,). Currently just the process/move destination root (docs/SPEC.md §5) —
/// a "set once, rarely change" value, so it lives in its own Settings scene rather than a header
/// button in the main window.
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
