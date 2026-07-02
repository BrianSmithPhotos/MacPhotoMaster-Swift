import SwiftUI
import UniformTypeIdentifiers

/// Folder tree + thumbnail grid for the active source directory. See docs/SPEC.md §1.
///
/// No folder *tree* yet, deliberately — that's a bigger piece (persisted skip-state per folder,
/// multi-select-by-capture-group, etc. from the spec) than this pass covers. This wires up the
/// single-folder thumbnail grid first so there's an actual end-to-end path from disk to pixels on
/// screen; the tree view slots in above this grid later without changing how the grid works.
struct SourcePanelView: View {
    @ObservedObject var viewModel: SourceBrowserViewModel
    @State private var isChoosingFolder = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Source")
                    .font(.headline)
                Spacer()
                Button("Open Folder…") { isChoosingFolder = true }
            }

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let message = viewModel.loadErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            } else if viewModel.captureSets.isEmpty {
                Text("Open a folder to browse photos.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.captureSets) { captureSet in
                            if let representative = captureSet.representative {
                                CaptureTileView(
                                    asset: representative,
                                    memberCount: captureSet.members.count,
                                    isSelected: viewModel.selectedAssetID == representative.id
                                )
                                .onTapGesture { viewModel.selectedAssetID = representative.id }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        // .fileImporter is the SwiftUI-native folder/file picker — it wraps the same NSOpenPanel
        // you'd otherwise drive by hand from AppKit, but as a modifier tied to `isPresented`
        // rather than something you present imperatively.
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                viewModel.loadFolder(at: url)
            }
        }
    }
}

/// One capture-set tile: the representative's thumbnail, plus a badge when the set has more than
/// one member (e.g. a RAW+JPEG pair from the same shutter press).
private struct CaptureTileView: View {
    let asset: PhotoAsset
    let memberCount: Int
    let isSelected: Bool

    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
                .clipped()

            if memberCount > 1 {
                Text("\(memberCount)")
                    .font(.caption2.bold())
                    .padding(4)
                    .background(.black.opacity(0.6), in: Circle())
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
        // `.task(id:)` re-runs whenever `asset.id` changes (SwiftUI diffs the id, not just
        // presence) and auto-cancels the previous run — important here because ForEach reuses
        // this view's identity across scroll/relayout, and without the id keying, a fast scroll
        // could leave a stale thumbnail decode from a previous asset finishing after this tile
        // was reassigned to a new one.
        .task(id: asset.id) {
            thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 256)
        }
    }
}

#Preview {
    SourcePanelView(viewModel: SourceBrowserViewModel())
}
