import SwiftUI
import MacPhotoMasterCore

/// Two-panel shell: source browser | preview, with metadata as a resizable sheet rather than a
/// third fixed column — see docs/ARCHITECTURE.md's iPad file access section for why. This is the
/// first working slice of the real iPad UI (source browsing, single- and grid-multi-select,
/// preview, read-only metadata); editing and Save/Process are deliberately not here yet.
struct ContentView: View {
    /// The one modal sheet this screen can show at a time. Driven through a single `.sheet(item:)`
    /// rather than two chained `.sheet(isPresented:)` modifiers: stacking two sheet presentations on
    /// one view leaves a phantom `PresentationHostingController` registered as "presented" after the
    /// visible sheet is dismissed, which then blocks the sidebar's Open Folder `.fileImporter` (also a
    /// UIKit presentation on this same hosting controller) with an "already presenting" error.
    private enum ActiveSheet: Identifiable {
        case metadata
        case settings
        var id: Self { self }
    }

    @StateObject private var browser = PhotoBrowserViewModel()
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: browser)
        } detail: {
            PreviewPanelView(viewModel: browser)
                .toolbar {
                    // The Title the previewed file would be renamed to, not its current filename —
                    // the same live `RenameService` preview the metadata sheet shows, batch label
                    // included, so it answers "which file is this" in the vocabulary the library
                    // will actually use. Tracks `previewAsset`, so it follows the filmstrip rather
                    // than the grid selection. Truncating in the middle keeps both ends visible:
                    // the leading sequence number separates frames in a burst, the tail carries the
                    // extension that tells a JPEG from its RAW.
                    ToolbarItem(placement: .principal) {
                        if !browser.renamePreviewFilename.isEmpty {
                            Text(browser.renamePreviewFilename)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            activeSheet = .metadata
                        } label: {
                            Label("Metadata", systemImage: "info.circle")
                        }
                        .disabled(browser.previewAsset == nil)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            activeSheet = .settings
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .metadata:
                MetadataPanelView(viewModel: browser)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .settings:
                SettingsView(viewModel: browser)
            }
        }
    }
}

#Preview {
    ContentView()
}
