import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Folder navigator + thumbnail grid for the active source directory. See docs/SPEC.md §1.
///
/// Navigation is breadcrumb-style (one level open at a time) rather than a recursive expandable
/// tree — see `FolderBrowser`'s doc comment for why.
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

            if !viewModel.breadcrumb.isEmpty {
                BreadcrumbBar(segments: viewModel.breadcrumb) { viewModel.navigate(to: $0) }
            }

            if !viewModel.subfolders.isEmpty {
                SubfolderStrip(folders: viewModel.subfolders) { viewModel.navigate(to: $0) }
            }

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let message = viewModel.loadErrorMessage {
                Text(message)
                    .foregroundStyle(.red)
            } else if viewModel.captureSets.isEmpty {
                Text(
                    viewModel.breadcrumb.isEmpty
                        ? "Open a folder to browse photos."
                        : "No supported photos in this folder."
                )
                .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.captureSets) { captureSet in
                            if let representative = captureSet.representative {
                                CaptureTileView(
                                    asset: representative,
                                    memberCount: captureSet.members.count,
                                    isSelected: viewModel.multiSelectedIDs.contains(representative.id),
                                    onSelect: { modifiers in
                                        viewModel.selectTile(representative.id, modifiers: modifiers)
                                    }
                                )
                                .contextMenu {
                                    Button("Skip") { viewModel.skip(captureSet) }
                                }
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
                viewModel.openFolder(at: url)
            }
        }
        // A visually hidden button is the standard SwiftUI way to attach a keyboard shortcut that
        // isn't tied to an on-screen control — `.hidden()` only affects rendering, so the shortcut
        // still registers with the window's responder chain. Mirrors the context-menu "Skip" action
        // so the same set-level skip is reachable either by right-click or the Delete key.
        .background {
            Button("Skip Selected", action: viewModel.skipSelected)
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(viewModel.selectedCaptureSet == nil)
                .hidden()
        }
    }
}

/// Finder-path-bar-style row of the folders between the opened root and the current folder.
/// Clicking a segment jumps straight there (via `SourceBrowserViewModel.navigate(to:)`, which
/// truncates the breadcrumb back to that point).
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
/// one member (e.g. a RAW+JPEG pair from the same shutter press).
private struct CaptureTileView: View {
    let asset: PhotoAsset
    let memberCount: Int
    let isSelected: Bool
    /// Cmd-click toggles this tile in/out of the grid's multi-selection, shift-click ranges from
    /// the last clicked tile, a plain click resets to just this one — see
    /// `SourceBrowserViewModel.selectTile`. `NSEvent.modifierFlags` reads the real modifier-key
    /// state at the moment of a genuine user click; this is unrelated to (and unaffected by) the
    /// AppleScript/System Events automation quirks documented for this app elsewhere.
    let onSelect: (NSEvent.ModifierFlags) -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        // A real Button (rather than a plain view with `.onTapGesture`) so the tap action and the
        // accessibility frame/press-action live on the same node — otherwise VoiceOver and
        // AXPress-based UI automation see a properly framed element with no action wired to it.
        Button(action: { onSelect(NSEvent.modifierFlags) }) {
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
        }
        .buttonStyle(.plain)
        // `.task(id:)` re-runs whenever `asset.id` changes (SwiftUI diffs the id, not just
        // presence) and auto-cancels the previous run — important here because ForEach reuses
        // this view's identity across scroll/relayout, and without the id keying, a fast scroll
        // could leave a stale thumbnail decode from a previous asset finishing after this tile
        // was reassigned to a new one.
        .task(id: asset.id) {
            thumbnail = try? await NativeMetadataReader().extractPreviewAsync(at: asset.url, maxPixelSize: 256)
        }
        // Without this, VoiceOver (and UI-automation hit-testing) only see the badge Text as a
        // leaf element with a bogus position inside the LazyVGrid's virtualized content — not the
        // tile itself. Combining into one element gives it the button's real on-screen frame.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("captureTile.\(asset.id.lastPathComponent)")
        .accessibilityLabel(
            memberCount > 1 ? "\(asset.url.lastPathComponent), \(memberCount) items" : asset.url.lastPathComponent)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    SourcePanelView(viewModel: SourceBrowserViewModel())
}
