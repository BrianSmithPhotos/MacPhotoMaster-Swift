import SwiftUI

/// Three-panel shell: source browser | preview | metadata. See docs/SPEC.md §1-3.
///
/// `@ObservedObject` here (not `@StateObject`) because `MacPhotoMasterApp` now owns the one
/// instance for the app's lifetime — it's shared with the Settings scene, which also reads/writes
/// `libraryRootURL`. See `MacPhotoMasterApp`'s doc comment for why.
struct ContentView: View {
    @ObservedObject var browser: SourceBrowserViewModel

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            PreviewPanelView(asset: browser.selectedAsset)
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            MetadataPanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    ContentView(browser: SourceBrowserViewModel())
}
