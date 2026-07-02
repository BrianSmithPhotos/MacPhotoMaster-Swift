import SwiftUI

/// Three-panel shell: source browser | preview | metadata. See docs/SPEC.md §1-3.
///
/// `@StateObject` (not `@ObservedObject`) here because `ContentView` *owns* this view model — it
/// creates the one instance for the app's lifetime. `@StateObject` guarantees SwiftUI keeps that
/// same instance across body re-evaluations; the two child panes below only ever *read* it, which
/// is why they take it as `@ObservedObject`/a plain `let` instead.
struct ContentView: View {
    @StateObject private var browser = SourceBrowserViewModel()

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: browser)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            PreviewPanelView(asset: browser.selectedAsset)
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            MetadataPanelView(asset: browser.selectedAsset)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    ContentView()
}
