import SwiftUI
import MacPhotoMasterCore

/// iPad counterpart to the macOS app's `PreviewPanelView` — big preview plus a filmstrip of the
/// selected capture set's members. The Mac version's cmd-click "ring-selection" (narrowing which
/// members a Save/Process action applies to beyond the grid's own multi-selection) has no touch
/// equivalent yet and isn't wired up here — there's nothing beyond `saveMetadata`'s/`process`'s
/// existing `.captureSet`/`.manualSelection` scopes for a ring-selection to further narrow until
/// that's designed. Tapping a filmstrip thumbnail just switches which member the big preview shows.
struct PreviewPanelView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel

    @State private var previewImage: CGImage?

    private var asset: PhotoAsset? { viewModel.previewAsset }

    var body: some View {
        VStack(spacing: 8) {
            VStack {
                Spacer()
                if let previewImage {
                    GeometryReader { geo in
                        Image(decorative: previewImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
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

            if let members = viewModel.selectedCaptureSet?.members, members.count > 1 {
                FilmstripView(
                    members: members,
                    activeAssetID: asset?.id,
                    onSelect: { viewModel.setActivePreview($0) }
                )
            }
        }
    }
}

/// Row of every member of the selected capture set, shown under the large preview. Tapping a
/// thumbnail switches which member is previewed large.
private struct FilmstripView: View {
    let members: [PhotoAsset]
    let activeAssetID: PhotoAsset.ID?
    let onSelect: (PhotoAsset.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    FilmstripTileView(
                        asset: member,
                        isActive: activeAssetID == member.id,
                        onSelect: { onSelect(member.id) }
                    )
                }
            }
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 92)
    }
}

/// One filmstrip thumbnail: accent-bordered when it's the actively previewed member.
private struct FilmstripTileView: View {
    let asset: PhotoAsset
    let isActive: Bool
    let onSelect: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 82, height: 60)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(asset.url.pathExtension.uppercased())
                            .font(.caption2)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 3)
                }
                .clipped()
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.url.lastPathComponent)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview {
    PreviewPanelView(viewModel: PhotoBrowserViewModel())
}
