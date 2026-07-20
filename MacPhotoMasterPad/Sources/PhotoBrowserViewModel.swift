import Foundation
import UIKit
import MacPhotoMasterCore

/// iPad-scoped counterpart to the macOS app's `SourceBrowserViewModel` — deliberately a much
/// smaller slice while the iPad UI is still being built out. No AI suggestions, no GPS/altitude
/// lookups, no Save/Process — this wires up browsing, capture-set grouping, skip/un-skip,
/// single-selection preview, and grid multi-select, all via the platform-portable
/// `MacPhotoMasterCore` services the macOS view model already uses for the same jobs.
///
/// Multi-select mirrors the Mac app's `multiSelectedIDs`/shift-click behavior two ways: touch has
/// no modifier-key equivalent, so "Select mode" plus tap-to-toggle stands in for cmd-click there;
/// but when a hardware keyboard/trackpad is attached, real cmd-click/shift-click also works
/// (`handleModifierClick`, via `TileTapCatcher`), reusing
/// the exact same portable `SelectionScope.rangeBetween` the Mac app's `selectTile(_:modifiers:)`
/// uses. Both paths write to the same `multiSelectedIDs`. This stops short of porting the Mac's
/// filmstrip ring-selection, though: that only exists to narrow a Save/Process action's scope, and
/// there's no Save/Process on iPad yet for it to feed — see `PreviewPanelView`'s doc comment.
@MainActor
final class PhotoBrowserViewModel: ObservableObject {
    @Published private(set) var breadcrumb: [URL] = []
    @Published private(set) var subfolders: [URL] = []
    @Published var sourceViewFilter: SourceViewFilter = .active {
        didSet { selectFirstTile() }
    }
    @Published private(set) var captureSets: [CaptureSet] = []
    @Published private(set) var skippedCaptureSets: [CaptureSet] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadErrorMessage: String?

    /// The grid's current selection. The filmstrip's own `previewAssetID` (below) can point at a
    /// different member of this set's capture group without changing which tile is selected.
    @Published private(set) var selectedAssetID: PhotoAsset.ID?
    /// Which member of `selectedCaptureSet` the big preview shows — `nil` means "the
    /// representative." Separate from `selectedAssetID` so tapping a filmstrip thumbnail doesn't
    /// re-select a different grid tile.
    @Published private(set) var previewAssetID: PhotoAsset.ID?

    /// "Select mode" for the grid — while on, tapping a tile toggles `multiSelectedIDs` instead of
    /// changing the preview, and a batch Skip/Un-skip action bar becomes available. Turning it off
    /// always clears the multi-selection rather than leaving stale picks around for next time.
    @Published var isSelecting = false {
        didSet {
            guard !isSelecting else { return }
            multiSelectedIDs = []
        }
    }
    /// The grid's batch-action selection set (Select mode only) — the touch equivalent of the Mac
    /// app's cmd/shift-click `multiSelectedIDs`.
    @Published private(set) var multiSelectedIDs: Set<PhotoAsset.ID> = []

    /// The last tile clicked with a modifier key held — the anchor a subsequent shift-click ranges
    /// from, mirroring the Mac app's `rangeAnchorID`.
    private var modifierClickAnchorID: PhotoAsset.ID?

    private let folderBrowser = FolderBrowser()
    private let assetLoader = PhotoAssetLoader()
    private let grouping = CaptureGroupingService()
    private var folderPathByCaptureSetID: [CaptureSet.ID: String] = [:]
    private var skipStore: SkipStateStore?

    /// The root `.fileImporter` hands back is only guaranteed accessible for the synchronous
    /// duration of its completion closure — reading it afterward (which `load(_:)`'s `Task`s always
    /// do) needs an explicit, held-open `startAccessingSecurityScopedResource()` call on that root.
    /// The grant covers the whole subtree while active, so subfolder navigation doesn't need its
    /// own start/stop calls — only opening a new root does. (The macOS app never needed this: it
    /// isn't sandboxed the same way, so `SourceBrowserViewModel.openFolder(at:)` skips it entirely.)
    private var securityScopedRootURL: URL?

    deinit {
        securityScopedRootURL?.stopAccessingSecurityScopedResource()
    }

    var displayedCaptureSets: [CaptureSet] {
        switch sourceViewFilter {
        case .active: return captureSets
        case .skipped: return skippedCaptureSets
        }
    }

    var selectedCaptureSet: CaptureSet? {
        displayedCaptureSets.first { $0.representative?.id == selectedAssetID }
    }

    var previewAsset: PhotoAsset? {
        guard let captureSet = selectedCaptureSet else { return nil }
        guard let previewAssetID else { return captureSet.representative }
        return captureSet.members.first { $0.id == previewAssetID } ?? captureSet.representative
    }

    /// Starts a fresh breadcrumb rooted at `folderURL` — called from the "Open Folder…" picker,
    /// which on iPad is backed by `UIDocumentPickerViewController` (the same `.fileImporter`
    /// modifier as the Mac app), so `folderURL` may point at an external volume such as a
    /// mass-storage-mode camera or SD card reader, not just local app storage.
    func openFolder(at folderURL: URL) {
        securityScopedRootURL?.stopAccessingSecurityScopedResource()
        securityScopedRootURL = folderURL.startAccessingSecurityScopedResource() ? folderURL : nil

        isSelecting = false
        breadcrumb = [folderURL]
        load(folderURL)
    }

    /// Tapping a subfolder chip or a breadcrumb segment. An ancestor already in the breadcrumb
    /// truncates back to it; a subfolder appends one level.
    func navigate(to folderURL: URL) {
        isSelecting = false
        if let index = breadcrumb.firstIndex(of: folderURL) {
            breadcrumb.removeSubrange((index + 1)...)
        } else {
            breadcrumb.append(folderURL)
        }
        load(folderURL)
    }

    func select(_ assetID: PhotoAsset.ID) {
        selectedAssetID = assetID
        previewAssetID = nil
    }

    func setActivePreview(_ assetID: PhotoAsset.ID) {
        previewAssetID = assetID
    }

    /// Tapping a tile while `isSelecting` is on.
    func toggleMultiSelect(_ id: PhotoAsset.ID) {
        if multiSelectedIDs.contains(id) {
            multiSelectedIDs.remove(id)
        } else {
            multiSelectedIDs.insert(id)
        }
    }

    /// Cmd-click or shift-click from a hardware keyboard/trackpad, delivered by
    /// `TileTapCatcher`. Works independently of the touch-only `isSelecting` toggle — a
    /// modifier-click always means "start multi-selecting," so it turns Select mode on to match
    /// (the Mac app has no separate "mode" for this at all; clicking with a modifier is enough).
    func handleModifierClick(_ id: PhotoAsset.ID, flags: UIKeyModifierFlags) {
        isSelecting = true
        if flags.contains(.shift), let anchor = modifierClickAnchorID {
            let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
            multiSelectedIDs.formUnion(SelectionScope.rangeBetween(anchor: anchor, target: id, visible: visibleIDs))
        } else {
            toggleMultiSelect(id)
        }
        modifierClickAnchorID = id
    }

    /// Skips (or un-skips) every capture set in the multi-selection at once, then leaves Select
    /// mode — the multi-selection's only consumer today, since there's no Save/Process on iPad yet
    /// for a "Current Selection" action to scope (see this type's doc comment).
    func performBatchSkipAction() {
        let targets = displayedCaptureSets.filter { set in
            guard let id = set.representative?.id else { return false }
            return multiSelectedIDs.contains(id)
        }
        switch sourceViewFilter {
        case .active: targets.forEach(skip)
        case .skipped: targets.forEach(unskip)
        }
        isSelecting = false
    }

    /// Hides every member of `captureSet` from the active view — persisted so a re-opened folder
    /// remembers what was skipped. Never touches the files on disk.
    func skip(_ captureSet: CaptureSet) {
        guard let folderPath = folderPathByCaptureSetID[captureSet.id] else { return }
        Task {
            guard let store = await ensureSkipStore() else { return }
            let assetPaths = captureSet.members.map(\.url.path)
            try? await store.skip(assetPaths: assetPaths, inFolder: folderPath)

            let removedIndex = captureSets.firstIndex { $0.id == captureSet.id } ?? 0
            captureSets.removeAll { $0.id == captureSet.id }
            skippedCaptureSets.append(captureSet)
            sortByCaptureOrder(&skippedCaptureSets)
            if selectedAssetID == captureSet.representative?.id {
                selectTileAfterRemoval(from: captureSets, previousIndex: removedIndex)
            }
        }
    }

    func unskip(_ captureSet: CaptureSet) {
        guard let folderPath = folderPathByCaptureSetID[captureSet.id] else { return }
        Task {
            guard let store = await ensureSkipStore() else { return }
            let assetPaths = captureSet.members.map(\.url.path)
            try? await store.unskip(assetPaths: assetPaths, inFolder: folderPath)

            let removedIndex = skippedCaptureSets.firstIndex { $0.id == captureSet.id } ?? 0
            skippedCaptureSets.removeAll { $0.id == captureSet.id }
            captureSets.append(captureSet)
            sortByCaptureOrder(&captureSets)
            if selectedAssetID == captureSet.representative?.id {
                selectTileAfterRemoval(from: skippedCaptureSets, previousIndex: removedIndex)
            }
        }
    }

    private func load(_ folderURL: URL) {
        isLoading = true
        loadErrorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                async let assetsTask = assetLoader.loadAssets(in: folderURL)
                async let subfoldersTask = folderBrowser.subfolders(of: folderURL)
                let (assets, folders) = try await (assetsTask, subfoldersTask)
                let skippedPaths = await skippedAssetPaths(inFolder: folderURL)
                let allSets = grouping.group(assets)
                captureSets = allSets.filter { set in
                    guard let path = set.representative?.url.path else { return true }
                    return !skippedPaths.contains(path)
                }
                skippedCaptureSets = allSets.filter { set in
                    guard let path = set.representative?.url.path else { return false }
                    return skippedPaths.contains(path)
                }
                folderPathByCaptureSetID = Dictionary(uniqueKeysWithValues: allSets.map { ($0.id, folderURL.path) })
                subfolders = folders
                selectFirstTile()
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    private func selectFirstTile() {
        guard let id = displayedCaptureSets.first?.representative?.id else {
            selectedAssetID = nil
            previewAssetID = nil
            return
        }
        selectedAssetID = id
        previewAssetID = nil
    }

    private func selectTileAfterRemoval(from sets: [CaptureSet], previousIndex: Int) {
        guard !sets.isEmpty else {
            selectedAssetID = nil
            previewAssetID = nil
            return
        }
        let index = min(previousIndex, sets.count - 1)
        selectedAssetID = sets[index].representative?.id
        previewAssetID = nil
    }

    private func sortByCaptureOrder(_ sets: inout [CaptureSet]) {
        sets.sort {
            ($0.representative?.capturedAt ?? .distantPast) < ($1.representative?.capturedAt ?? .distantPast)
        }
    }

    private func skippedAssetPaths(inFolder folderURL: URL) async -> Set<String> {
        guard let store = await ensureSkipStore() else { return [] }
        return (try? await store.skippedAssetPaths(inFolder: folderURL.path)) ?? []
    }

    private func ensureSkipStore() async -> SkipStateStore? {
        if let skipStore { return skipStore }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "skip_state.sqlite3")
            let store = try SkipStateStore(databasePath: databasePath)
            skipStore = store
            return store
        } catch {
            loadErrorMessage = error.localizedDescription
            return nil
        }
    }
}
