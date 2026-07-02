import SwiftUI

/// Folder tree + thumbnail grid for the active source directory. See docs/SPEC.md §1.
struct SourcePanelView: View {
    var body: some View {
        VStack {
            Text("Source")
                .font(.headline)
            Spacer()
            Text("Folder tree + thumbnail grid goes here")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

#Preview {
    SourcePanelView()
}
