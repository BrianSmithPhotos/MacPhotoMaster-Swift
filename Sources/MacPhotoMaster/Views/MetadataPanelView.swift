import SwiftUI

/// Editable metadata fields + AI/GPS/save/process actions. See docs/SPEC.md §2-7.
struct MetadataPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
            Spacer()
            Text("Title, description, keywords, GPS fields go here")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

#Preview {
    MetadataPanelView()
}
