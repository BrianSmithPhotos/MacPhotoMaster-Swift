import AppKit
import SwiftUI

/// Full-size preview + selected-images filmstrip. See docs/SPEC.md §1.
///
/// Takes the view model rather than a single `PhotoAsset` so the filmstrip below the preview can
/// read `variantMemberIDs`/`variantSelectedIDs` and resolve any member of the current selection —
/// not just the one asset shown large.
struct PreviewPanelView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel

    @State private var previewImage: CGImage?

    private var asset: PhotoAsset? { viewModel.selectedAsset }

    var body: some View {
        VStack(spacing: 8) {
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

            if viewModel.variantMemberIDs.count > 1 {
                SelectedImagesStripView(viewModel: viewModel)
            }
        }
    }
}

/// Row of every member of the current selection (see `SourceBrowserViewModel.variantMemberIDs`),
/// shown under the large preview. Plain click switches which member is previewed large; cmd-click
/// toggles a member's ring-selection (`variantSelectedIDs`) — the batch these tiles resolve to is
/// intended to back AI/process-move actions that operate on a fine-tuned subset, mirroring the
/// reference app's variant strip.
private struct SelectedImagesStripView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel

    private var members: [PhotoAsset] {
        let assetByID = Dictionary(uniqueKeysWithValues: viewModel.captureSets.flatMap(\.members).map { ($0.id, $0) })
        return viewModel.variantMemberIDs.compactMap { assetByID[$0] }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    VariantTileView(
                        asset: member,
                        isRingSelected: viewModel.variantSelectedIDs.contains(member.id),
                        isActive: viewModel.selectedAssetID == member.id,
                        onPlainSelect: { viewModel.setActivePreview(member.id) },
                        onToggleSelect: { viewModel.toggleVariantSelection(member.id) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 68)
    }
}

/// One filmstrip thumbnail: dimmed when ring-deselected, accent-bordered when it's the actively
/// previewed member.
private struct VariantTileView: View {
    let asset: PhotoAsset
    let isRingSelected: Bool
    let isActive: Bool
    let onPlainSelect: () -> Void
    let onToggleSelect: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                onToggleSelect()
            } else {
                onPlainSelect()
            }
        } label: {
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
                .opacity(isRingSelected ? 1.0 : 0.4)
                .clipped()
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("variantTile.\(asset.id.lastPathComponent)")
        .accessibilityLabel(asset.url.lastPathComponent)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview {
    PreviewPanelView(viewModel: SourceBrowserViewModel())
}
