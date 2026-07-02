import SwiftUI

/// Full-size preview + capture-set variant strip. See docs/SPEC.md §1.
struct PreviewPanelView: View {
    var body: some View {
        VStack {
            Spacer()
            Image(systemName: "photo")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Preview")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PreviewPanelView()
}
