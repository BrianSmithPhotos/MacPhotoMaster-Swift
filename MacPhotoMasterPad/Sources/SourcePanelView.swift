import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MacPhotoMasterCore

/// iPad counterpart to the macOS app's `SourcePanelView` — same breadcrumb/subfolder/grid layout
/// and the same `.fileImporter` folder picker (which presents `UIDocumentPickerViewController` on
/// this platform, so it already handles picking a mass-storage-mode camera or SD card reader — see
/// docs/ARCHITECTURE.md's iPad file access section). Multi-select stands in for the Mac's
/// cmd/shift-click two ways: touch gets a "Select" toggle where tapping a tile toggles it in/out of
/// `multiSelectedIDs`; a hardware keyboard/trackpad gets the real thing (cmd-click/shift-click, via
/// `TileTapCatcher`), including shift-click range-select using the same portable
/// `SelectionScope.rangeBetween` the Mac app's shift-click uses. There's deliberately no touch
/// equivalent of drag-to-range-select: an earlier attempt (`LongPressGesture.sequenced(before:
/// DragGesture())` on the grid) fought the `ScrollView`'s own pan recognizer and every tile's plain
/// tap recognizer badly enough to break scrolling and normal tap-to-toggle even outside an active
/// drag, so it was removed rather than tuned further.
struct SourcePanelView: View {
    @ObservedObject var viewModel: PhotoBrowserViewModel
    @State private var isChoosingFolder = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    private var emptyStateMessage: String {
        guard !viewModel.breadcrumb.isEmpty else { return "Open a folder to browse photos." }
        switch viewModel.sourceViewFilter {
        case .active: return "No supported photos in this folder."
        case .skipped: return "No skipped items in this folder."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isSelecting {
                HStack {
                    Text("\(viewModel.multiSelectedIDs.count) selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.sourceViewFilter == .active {
                        Button("Merge") { viewModel.mergeSelectedCaptureSets() }
                            .disabled(!viewModel.canMergeSelection)
                    }
                    Button(viewModel.sourceViewFilter == .active ? "Skip" : "Un-skip") {
                        viewModel.performBatchSkipAction()
                    }
                    .disabled(viewModel.multiSelectedIDs.isEmpty)
                }
                .font(.callout)
            }

            if !viewModel.breadcrumb.isEmpty {
                BreadcrumbBar(segments: viewModel.breadcrumb) { viewModel.navigate(to: $0) }
            }

            if !viewModel.subfolders.isEmpty {
                SubfolderStrip(folders: viewModel.subfolders) { viewModel.navigate(to: $0) }
            }

            Picker("View", selection: $viewModel.sourceViewFilter) {
                Text("Active").tag(SourceViewFilter.active)
                Text("Skipped (\(viewModel.skippedCaptureSets.count))").tag(SourceViewFilter.skipped)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let message = viewModel.loadErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            } else if viewModel.displayedCaptureSets.isEmpty {
                Text(emptyStateMessage)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.displayedCaptureSets) { captureSet in
                            if let representative = captureSet.representative {
                                let tile = CaptureTileView(
                                    asset: representative,
                                    memberCount: captureSet.members.count,
                                    isSelected: viewModel.selectedAssetID == representative.id,
                                    isSelectMode: viewModel.isSelecting,
                                    isMultiSelected: viewModel.multiSelectedIDs.contains(representative.id),
                                    isProcessed: viewModel.isProcessed(captureSet),
                                    isTagged: viewModel.isTagged(captureSet),
                                    isMarkedForRawDevelop: viewModel.isMarkedForRawDevelop(captureSet),
                                    onSelect: {
                                        if viewModel.isSelecting {
                                            viewModel.toggleMultiSelect(representative.id)
                                        } else {
                                            viewModel.select(representative.id)
                                        }
                                    },
                                    onModifierClick: { flags in
                                        viewModel.handleModifierClick(representative.id, flags: flags)
                                    }
                                )

                                // A long-press context menu would otherwise still show "Skip" while
                                // Select mode is on, which reads as if the tap toggled nothing.
                                if viewModel.isSelecting {
                                    tile
                                } else {
                                    tile.contextMenu {
                                        switch viewModel.sourceViewFilter {
                                        case .active:
                                            Button("Skip") { viewModel.skip(captureSet) }
                                            // iPad can't develop a RAW itself, so this only records
                                            // the request — the Mac's iPad import does the work.
                                            if viewModel.canMarkForRawDevelop(captureSet) {
                                                Button(
                                                    viewModel.isMarkedForRawDevelop(captureSet)
                                                        ? "Unmark RAW Develop" : "Mark for RAW Develop"
                                                ) {
                                                    viewModel.toggleRawDevelopMark(captureSet)
                                                }
                                            }
                                            if viewModel.isMerged(captureSet) {
                                                Button("Split Apart") { viewModel.splitApart(captureSet) }
                                            }
                                        case .skipped:
                                            Button("Un-skip") { viewModel.unskip(captureSet) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .navigationTitle("Source")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isSelecting {
                    Button("Cancel") { viewModel.isSelecting = false }
                } else {
                    Button("Select") { viewModel.isSelecting = true }
                        .disabled(viewModel.displayedCaptureSets.isEmpty)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Open Folder…") { isChoosingFolder = true }
                    .disabled(viewModel.isSelecting)
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                viewModel.openFolder(at: url)
            }
        }
    }
}

/// Path-bar-style row of the folders between the opened root and the current folder. Tapping a
/// segment jumps straight there.
private struct BreadcrumbBar: View {
    let segments: [URL]
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.element) { index, url in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(url.lastPathComponent) { onSelect(url) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .fontWeight(index == segments.count - 1 ? .semibold : .regular)
                }
            }
        }
    }
}

/// Chip row of the current folder's immediate subfolders. Tapping one descends into it.
private struct SubfolderStrip: View {
    let folders: [URL]
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(folders, id: \.self) { folder in
                    Button {
                        onSelect(folder)
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// One capture-set tile: the representative's thumbnail, plus a badge when the set has more than
/// one member (e.g. a RAW+JPEG pair from the same shutter press). Plain tap selects it; in Select
/// mode, tap instead toggles the checkmark badge; cmd-click or shift-click from a hardware
/// keyboard/trackpad works too, independent of Select mode — see this file's doc comment.
private struct CaptureTileView: View {
    let asset: PhotoAsset
    let memberCount: Int
    let isSelected: Bool
    let isSelectMode: Bool
    let isMultiSelected: Bool
    /// Whether this set has already been through Process & Move at least once — purely
    /// informational (see `PhotoBrowserViewModel.processedAssetPaths`'s doc comment), shown as a
    /// small bottom-leading checkmark so it never competes with the Select-mode badge (top-leading)
    /// or the member-count badge (bottom-trailing).
    let isProcessed: Bool
    /// Whether this set already carries a description — a session's tagging lives only in the staged
    /// sidecars until Process & Move runs (the card is never written to), so without this the second
    /// evening of a trip opens on a grid that looks untouched. Bottom-leading, beside the processed
    /// check: the two answer the same question at different stages.
    let isTagged: Bool
    /// Whether this set's RAW is waiting for the Mac to develop it — the only feedback the iPad can
    /// give, since the develop itself happens at import time on the other machine. Top-trailing, the
    /// one corner none of the other badges use.
    let isMarkedForRawDevelop: Bool
    let onSelect: () -> Void
    let onModifierClick: (UIKeyModifierFlags) -> Void

    @State private var thumbnail: CGImage?

    private var accessibilityTraits: AccessibilityTraits {
        (isSelectMode ? isMultiSelected : isSelected) ? [.isButton, .isSelected] : .isButton
    }

    var body: some View {
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
                    .strokeBorder(
                        (isSelectMode ? isMultiSelected : isSelected) ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .bottomTrailing) {
                if memberCount > 1 {
                    Text("\(memberCount)")
                        .font(.caption2.bold())
                        .padding(4)
                        .background(.black.opacity(0.6), in: Circle())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelectMode {
                    Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isMultiSelected ? Color.accentColor : .black.opacity(0.35))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isMarkedForRawDevelop {
                    Image(systemName: "hourglass.circle.fill")
                        .font(.caption)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Both marks share this corner, tagged first, because they are the two halves of the
                // same question — what have I already done to this set — and on a multi-evening trip
                // the answer has to be readable from the grid rather than by opening each set.
                HStack(spacing: 3) {
                    if isTagged {
                        Image(systemName: "text.bubble.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                    }
                    if isProcessed {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                    }
                }
                .font(.caption)
                .padding(6)
            }
            .clipped()
            .overlay(
                TileTapCatcher { flags in
                    if flags.contains(.command) || flags.contains(.shift) {
                        onModifierClick(flags)
                    } else {
                        onSelect()
                    }
                }
            )
            .task(id: asset.id) {
                thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 256)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                memberCount > 1 ? "\(asset.url.lastPathComponent), \(memberCount) items" : asset.url.lastPathComponent)
            .accessibilityAddTraits(accessibilityTraits)
            .accessibilityAction(.default, onSelect)
    }
}

#Preview {
    SourcePanelView(viewModel: PhotoBrowserViewModel())
}
