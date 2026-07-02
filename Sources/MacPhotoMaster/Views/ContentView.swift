import SwiftUI

/// Three-panel shell: source browser | preview | metadata. See docs/SPEC.md §1-3.
struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            SourcePanelView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            PreviewPanelView()
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            MetadataPanelView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    ContentView()
}
