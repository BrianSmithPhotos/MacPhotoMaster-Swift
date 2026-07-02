import SwiftUI

/// Full-size preview + capture-set variant strip. See docs/SPEC.md §1.
///
/// No variant strip yet — that needs the containing `CaptureSet` (to list every member alongside
/// the representative), which this view doesn't have; it only knows about the single selected
/// `PhotoAsset`. Comes back once selection is modeled as "selected capture set" rather than just
/// "selected asset."
struct PreviewPanelView: View {
    let asset: PhotoAsset?

    @State private var previewImage: CGImage?

    var body: some View {
        VStack {
            Spacer()
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)
                Text(asset == nil ? "Select a photo" : "Loading…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset?.id) {
            previewImage = nil
            guard let asset else { return }
            previewImage = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 2048)
        }
    }
}

#Preview {
    PreviewPanelView(asset: nil)
}
