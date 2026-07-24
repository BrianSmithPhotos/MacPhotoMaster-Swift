import SwiftUI
import MacPhotoMasterCore

/// Three-panel shell: source browser | preview | metadata. See docs/SPEC.md §1-3.
///
/// `@ObservedObject` here (not `@StateObject`) because `MacPhotoMasterApp` now owns the one
/// instance for the app's lifetime — it's shared with the Settings scene, which also reads/writes
/// `libraryRootURL`. See `MacPhotoMasterApp`'s doc comment for why.
struct ContentView: View {
    @ObservedObject var browser: SourceBrowserViewModel
    @State private var isMetadataPanelPresented = true
    @State private var isIPadImportPresented = false

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            PreviewPanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $isMetadataPanelPresented) {
            MetadataPanelView(viewModel: browser)
                .inspectorColumnWidth(min: 280, ideal: 320)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isIPadImportPresented = true
                } label: {
                    Label("Import from iPad", systemImage: "square.and.arrow.down.on.square")
                }
            }
            ToolbarItem {
                Button {
                    isMetadataPanelPresented.toggle()
                } label: {
                    Label("Toggle Metadata Panel", systemImage: "sidebar.trailing")
                }
            }
        }
        .sheet(isPresented: $isIPadImportPresented) {
            IPadImportView(viewModel: browser)
        }
    }
}

#Preview {
    ContentView(browser: SourceBrowserViewModel())
}
