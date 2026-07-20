import SwiftUI
import MacPhotoMasterCore

/// Two-panel shell: source browser | preview, with metadata as a resizable sheet rather than a
/// third fixed column — see docs/ARCHITECTURE.md's iPad file access section for why. This is the
/// first working slice of the real iPad UI (source browsing, single- and grid-multi-select,
/// preview, read-only metadata); editing and Save/Process are deliberately not here yet.
struct ContentView: View {
    @StateObject private var browser = PhotoBrowserViewModel()
    @State private var isMetadataPresented = false
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: browser)
        } detail: {
            PreviewPanelView(viewModel: browser)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isMetadataPresented = true
                        } label: {
                            Label("Metadata", systemImage: "info.circle")
                        }
                        .disabled(browser.previewAsset == nil)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isSettingsPresented = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $isMetadataPresented) {
            MetadataPanelView(viewModel: browser)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(viewModel: browser)
        }
    }
}

#Preview {
    ContentView()
}
