import Foundation
import UIKit
import MacPhotoMasterCore

/// iPad-scoped counterpart to the macOS app's `SourceBrowserViewModel` — deliberately a much
/// smaller slice while the iPad UI is still being built out. No AI suggestions, no GPS/altitude
/// lookups — this wires up browsing, capture-set grouping, skip/un-skip, single-selection preview,
/// grid multi-select, description/keywords metadata editing + save (staged via
/// `SidecarStagingStore`, not written straight to the original file — see docs/ARCHITECTURE.md's
/// iPad section), a live rename preview (`titlePreview`), and Process & Move (`process(scope:)`),
/// all via the platform-portable `MacPhotoMasterCore` services the macOS view model already uses for
/// the same jobs — `ProcessMoveService` is constructed with `NativeMetadataWriter()` here instead of
/// the Mac app's `ExifToolClient()`, but is otherwise reused unmodified. Renaming itself, like the
/// Mac app, only ever applies to the destination copy made at Process & Move time — this view model
/// only computes the *preview*, never renames the source file.
///
/// Multi-select mirrors the Mac app's `multiSelectedIDs`/shift-click behavior two ways: touch has
/// no modifier-key equivalent, so "Select mode" plus tap-to-toggle stands in for cmd-click there;
/// but when a hardware keyboard/trackpad is attached, real cmd-click/shift-click also works
/// (`handleModifierClick`, via `TileTapCatcher`), reusing
/// the exact same portable `SelectionScope.rangeBetween` the Mac app's `selectTile(_:modifiers:)`
/// uses. Both paths write to the same `multiSelectedIDs`, which now doubles as the scope for
/// `saveMetadata(scope: .manualSelection(...))` the same way it already did for
/// `performBatchSkipAction`. This stops short of porting the Mac's filmstrip ring-selection, though:
/// that only exists to further narrow a Save/Process scope beyond the grid's own multi-selection —
/// see `PreviewPanelView`'s doc comment.
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
    ///
    /// `didSet` resyncs the metadata edit buffer to whatever's now shown large, discarding any
    /// unsaved in-progress edit — mirrors the Mac app's `SourceBrowserViewModel.selectedAssetID`.
    @Published private(set) var selectedAssetID: PhotoAsset.ID? {
        didSet {
            guard selectedAssetID != oldValue else { return }
            loadEditBuffer()
        }
    }
    /// Which member of `selectedCaptureSet` the big preview shows — `nil` means "the
    /// representative." Separate from `selectedAssetID` so tapping a filmstrip thumbnail doesn't
    /// re-select a different grid tile.
    @Published private(set) var previewAssetID: PhotoAsset.ID? {
        didSet {
            guard previewAssetID != oldValue else { return }
            loadEditBuffer()
        }
    }

    /// The metadata panel's editable fields, kept as free text (parsed via `MetadataEditParsing` at
    /// save time) the same way the Mac app's `SourceBrowserViewModel` does — see its doc comment.
    /// Synced to `previewAsset`'s current values (or a previously staged draft, if one exists) by
    /// `loadEditBuffer` whenever the selection/preview changes. No `editableTitle`: per
    /// docs/SPEC.md §3/§4, Title only becomes real metadata at Process & Move time (not built on
    /// iPad yet) — until then it's just `titlePreview` below, a live rename preview.
    @Published var editableDescription: String = ""
    @Published var editableKeywords: String = ""
    @Published private(set) var isSavingMetadata = false
    @Published var saveStatusMessage: String?

    /// The manual per-session label `RenameService` needs for its filename pattern (docs/SPEC.md
    /// §4) — mirrors the Mac app's `sessionBatch`. `didSet` recomputes `renamePreviewFilename`
    /// immediately so the Title field updates live as the user types a batch label.
    @Published var sessionBatch: String = "" {
        didSet {
            guard sessionBatch != oldValue else { return }
            updateRenamePreview()
        }
    }
    /// Live preview of the filename `RenameService` would generate for `previewAsset` right now —
    /// recomputed by `updateRenamePreview()` whenever the preview or `sessionBatch` changes.
    /// Uniqueness is only checked against the *source* folder's existing names, same caveat as the
    /// Mac app's `renamePreviewFilename` doc comment: the authoritative check happens at Process &
    /// Move time (not built on iPad yet), so this can differ from the eventual final name in rare
    /// collision cases.
    @Published private(set) var renamePreviewFilename: String = ""
    /// What the Title field displays — the rename preview's filename stem, never independently typed
    /// or saved. See `editableDescription`'s doc comment for why there's no `editableTitle`.
    var titlePreview: String { (renamePreviewFilename as NSString).deletingPathExtension }

    /// Where Process & Move copies destination files under — a fixed local folder inside the app's
    /// own container, not something the user picks. Deliberately not the Mac app's model (a
    /// user-chosen, `UserDefaults`-persisted folder that can point anywhere, including external
    /// volumes): a Google-Drive-mounted folder was considered and ruled out, since Drive's own
    /// background sync writing/evicting bytes in the same folder `ProcessMoveService` copies into and
    /// SHA-256-verifies would race with that verification. Files land here and stay local until a
    /// separate, not-yet-built Mac-initiated pull moves them off the iPad — likely via Finder file
    /// sharing, which can only see the app's own `Documents` directory (see project.yml's
    /// `UIFileSharingEnabled`), hence staging inside `Documents` rather than anywhere else in the
    /// sandbox. No security-scoped access needed since this is entirely inside the app's own sandbox.
    let libraryRootURL: URL = PhotoBrowserViewModel.makeLibraryRootDirectory()

    private static func makeLibraryRootDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let staging = documents.appendingPathComponent("ProcessedLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    @Published private(set) var isProcessing = false
    @Published var processStatusMessage: String?

    /// Paths (within the currently loaded folder) that have already been through Process & Move at
    /// least once — drives a non-blocking "processed" indicator, the same purely-informational role
    /// as the Mac app's `processedAssetPaths`. Never hides or disables anything: reprocessing must
    /// stay freely available.
    @Published private(set) var processedAssetPaths: Set<String> = []
    private var processedStore: ProcessedStateStore?

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
    private let renameService = RenameService()
    private let processMoveService = ProcessMoveService(metadataWriter: NativeMetadataWriter())
    private var folderPathByCaptureSetID: [CaptureSet.ID: String] = [:]
    private var skipStore: SkipStateStore?
    private var sidecarStagingStore: SidecarStagingStore?

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

    /// True when the grid's manual multi-selection (Select mode, or a hardware modifier-click) has
    /// more than one tile picked — mirrors the Mac app's `hasMultiSelection`. No filmstrip
    /// ring-selection equivalent exists on iPad (see this type's doc comment), so unlike the Mac
    /// app's `hasCurrentSelection` this is the whole story for whether "Save (Current Selection)" is
    /// actionable.
    var hasMultiSelection: Bool { multiSelectedIDs.count > 1 }

    /// Assets for a "Save (Current Selection)" metadata action (docs/SPEC.md §5's `.manualSelection`
    /// scope): the grid's manual multi-selection, expanded from representative tiles to full
    /// capture-group membership so a stacked RAW file behind a selected JPEG representative isn't
    /// silently skipped.
    var manualSelectionAssets: [PhotoAsset] {
        guard hasMultiSelection else { return [] }
        let assetByID = Dictionary(uniqueKeysWithValues: displayedCaptureSets.flatMap(\.members).map { ($0.id, $0) })
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
        let ordered = visibleIDs.filter { multiSelectedIDs.contains($0) }
        let expandedIDs = SelectionScope.expandToCaptureGroups(ordered, membersByID: membersByAssetID)
        return expandedIDs.compactMap { assetByID[$0] }
    }

    /// Maps every asset id (within `displayedCaptureSets`) to its full capture-group membership
    /// (including itself) — the lookup `SelectionScope`'s pure functions need but don't own
    /// themselves. Mirrors the Mac app's private `membersByAssetID`.
    private var membersByAssetID: [PhotoAsset.ID: [PhotoAsset.ID]] {
        var map: [PhotoAsset.ID: [PhotoAsset.ID]] = [:]
        for set in displayedCaptureSets {
            let memberIDs = set.members.map(\.id)
            for id in memberIDs { map[id] = memberIDs }
        }
        return map
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
    /// mode. The other consumer of the same multi-selection, `saveMetadata(scope: .manualSelection)`,
    /// leaves Select mode on its own terms instead (a save can be retried), so it isn't handled here.
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

    /// Resyncs the metadata edit buffer to `previewAsset`'s current values whenever the selection or
    /// active preview changes. Checks for a previously staged draft afterward — mirrors the Mac
    /// app's `SourceBrowserViewModel.loadEditBuffer`, minus GPS/AI state this view model doesn't have
    /// yet.
    private func loadEditBuffer() {
        saveStatusMessage = nil
        guard let asset = previewAsset else {
            editableDescription = ""
            editableKeywords = ""
            updateRenamePreview()
            return
        }
        editableDescription = asset.descriptionText
        editableKeywords = asset.keywords.joined(separator: ", ")
        updateRenamePreview()
        applyStagedDraftIfPresent(for: asset)
    }

    /// Recomputes `renamePreviewFilename` for `previewAsset` against `sessionBatch`'s current value
    /// — mirrors the Mac app's `updateRenamePreview`, using `previewAsset` (the filmstrip's active
    /// pick) rather than `selectedAssetID` directly, since on iPad those are deliberately separate
    /// (see this type's doc comment) and it's whichever file is shown large that a rename preview
    /// should track.
    private func updateRenamePreview() {
        guard let asset = previewAsset else {
            renamePreviewFilename = ""
            return
        }
        let context = RenameContext(
            sourceURL: asset.url,
            capturedAt: asset.capturedAt,
            cameraModel: asset.cameraModel,
            lensModel: asset.lensModel,
            batch: sessionBatch,
            artFilterToken: asset.artFilterToken)
        let candidate = renameService.buildFilename(for: context)

        var existingNames = Self.existingFileNames(in: asset.url.deletingLastPathComponent())
        existingNames.remove(asset.url.lastPathComponent)
        renamePreviewFilename = renameService.ensureUniqueName(candidate, existingNames: existingNames)
    }

    private static func existingFileNames(in directory: URL) -> Set<String> {
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return Set(names ?? [])
    }

    /// Overwrites the just-loaded buffer with a previously staged (unsaved-to-original-file) draft,
    /// if one exists — lets re-selecting a photo pick back up mid-edit rather than reverting to
    /// what's still on disk. Store lookup is async, so this re-checks `previewAsset` before writing
    /// into the buffer in case the selection moved on again while the lookup was in flight.
    private func applyStagedDraftIfPresent(for asset: PhotoAsset) {
        Task {
            guard let store = await ensureSidecarStagingStore() else { return }
            guard let draft = try? store.stagedDraft(for: asset.url) else { return }
            guard previewAsset?.id == asset.id else { return }
            editableDescription = draft.description
            editableKeywords = draft.keywords.joined(separator: ", ")
        }
    }

    /// Stages the edit buffer for `scope`'s file(s) via `SidecarStagingStore`, one `stage` call per
    /// target (the store has no batched-write equivalent of `ExifToolClient.write`, so there's no
    /// need for the Mac app's per-file `AutoMetadataGroupKey` grouping — that only exists to keep
    /// differing per-file auto-tokens out of a single batched invocation, and `AutoMetadataRules`
    /// isn't ported to iPad yet anyway). `title`/`gps` are always `nil`: Title isn't independently
    /// editable yet (it's rename-derived, per the Mac app's convention, and iPad has no rename yet
    /// either) and GPS editing isn't built on iPad yet.
    ///
    /// No-op while a previous save is still running.
    func saveMetadata(scope: MetadataSaveScope) {
        Task { await performSave(scope: scope) }
    }

    private func performSave(scope: MetadataSaveScope) async {
        guard !isSavingMetadata else { return }
        let targets: [PhotoAsset]
        switch scope {
        case .singleAsset(let asset): targets = [asset]
        case .captureSet(let captureSet): targets = captureSet.members
        case .manualSelection(let assets): targets = assets
        }
        guard !targets.isEmpty else { return }

        isSavingMetadata = true
        saveStatusMessage = "Saving…"
        defer { isSavingMetadata = false }
        guard let store = await ensureSidecarStagingStore() else { return }

        let description = editableDescription
        let keywords = MetadataEditParsing.parseKeywords(editableKeywords)

        var failureCount = 0
        for target in targets {
            do {
                try await store.stage(title: nil, description: description, keywords: keywords, gps: nil, for: target.url)
                updateAsset(target.id) { updated in
                    updated.descriptionText = description
                    updated.keywords = keywords
                }
            } catch {
                failureCount += 1
            }
        }
        saveStatusMessage =
            failureCount == 0
            ? "Saved to \(targets.count) file(s)."
            : "Saved \(targets.count - failureCount)/\(targets.count) file(s); \(failureCount) failed."
    }

    /// Mutates the in-memory asset so the grid/preview reflect a successful save immediately, without
    /// a full reload. Only searches `captureSets`, not `skippedCaptureSets` — mirrors the Mac app's
    /// `SourceBrowserViewModel.updateAsset`, which has the same accepted scope limit.
    private func updateAsset(_ id: PhotoAsset.ID, _ mutate: (inout PhotoAsset) -> Void) {
        for setIndex in captureSets.indices {
            if let memberIndex = captureSets[setIndex].members.firstIndex(where: { $0.id == id }) {
                mutate(&captureSets[setIndex].members[memberIndex])
                return
            }
        }
    }

    /// Resolves `scope` to its concrete assets (see `ProcessMoveScope.assets`) and copies each into
    /// `libraryRootURL` via `ProcessMoveService`, per docs/SPEC.md §5 — mirrors the Mac app's
    /// `process(scope:libraryRoot:)`, minus the `libraryRoot` parameter since iPad's is a fixed local
    /// folder rather than something picked per call (see `libraryRootURL`'s doc comment). Before
    /// copying, checks `SidecarStagingStore` for a draft staged in an earlier session that never got
    /// loaded into `editableDescription`/`editableKeywords` this time around (e.g. this asset was
    /// never previewed this session): without this, a prior session's staged edit could be silently
    /// dropped, since `ProcessMoveService` only ever sees whatever description/keywords are already
    /// on the `PhotoAsset` value it's handed.
    ///
    /// One asset's failure doesn't stop the rest of the scope from processing — failures are
    /// collected and surfaced together afterward via `processStatusMessage`. No-op while a previous
    /// call is still running, and no-op on an empty scope. Unlike the Mac app, there's no
    /// `loadArtFilterTokens` step first: iPad has no exiftool, so `asset.artFilterToken` is whatever
    /// `NativeMetadataReader` already found — nothing, for Olympus maker notes, a pre-existing
    /// documented gap.
    func process(scope: ProcessMoveScope) {
        guard !isProcessing else { return }
        let assets = scope.assets
        guard !assets.isEmpty else { return }
        // Captured now, not read from `breadcrumb.last` after the `Task` finishes — mirrors
        // `skip(_:)`'s reasoning: the user could navigate to a different folder while this is still
        // running.
        let folderPath = breadcrumb.last?.path

        isProcessing = true
        processStatusMessage = "Processing \(assets.count) file(s)…"
        Task {
            defer { isProcessing = false }
            guard let stagingStore = await ensureSidecarStagingStore() else { return }
            var failures: [String] = []
            var processedPaths: [String] = []
            for asset in assets {
                var asset = asset
                if let draft = try? stagingStore.stagedDraft(for: asset.url) {
                    asset.descriptionText = draft.description
                    asset.keywords = draft.keywords
                }
                let context = RenameContext(
                    sourceURL: asset.url,
                    capturedAt: asset.capturedAt,
                    cameraModel: asset.cameraModel,
                    lensModel: asset.lensModel,
                    batch: sessionBatch,
                    artFilterToken: asset.artFilterToken)
                do {
                    _ = try await processMoveService.processAndCopy(
                        asset: asset, renameContext: context, libraryRoot: libraryRootURL)
                    processedPaths.append(asset.url.path)
                } catch {
                    failures.append("\(asset.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if let folderPath, !processedPaths.isEmpty {
                await markAssetsProcessed(processedPaths, inFolder: folderPath)
            }
            let successCount = assets.count - failures.count
            if failures.isEmpty {
                processStatusMessage = "Processed \(successCount) file(s)."
            } else {
                processStatusMessage =
                    "Processed \(successCount)/\(assets.count) file(s); \(failures.count) failed:\n"
                    + failures.joined(separator: "\n")
            }
        }
    }

    private func ensureProcessedStore() async -> ProcessedStateStore? {
        if let processedStore { return processedStore }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "processed_state.sqlite3")
            let store = try ProcessedStateStore(databasePath: databasePath)
            processedStore = store
            return store
        } catch {
            return nil
        }
    }

    private func loadProcessedAssetPaths(inFolder folderURL: URL) async -> Set<String> {
        guard let store = await ensureProcessedStore() else { return [] }
        return (try? await store.processedAssetPaths(inFolder: folderURL.path)) ?? []
    }

    /// Persists `assetPaths` as processed for `folderPath` and updates the in-memory set so the
    /// indicator appears immediately, without waiting for the next folder load.
    private func markAssetsProcessed(_ assetPaths: [String], inFolder folderPath: String) async {
        guard let store = await ensureProcessedStore() else { return }
        try? await store.markProcessed(assetPaths: assetPaths, inFolder: folderPath)
        processedAssetPaths.formUnion(assetPaths)
    }

    /// Whether `asset` has already been through Process & Move at least once in this folder.
    func isProcessed(_ asset: PhotoAsset) -> Bool {
        processedAssetPaths.contains(asset.url.path)
    }

    /// Whether any member of `captureSet` has already been through Process & Move — a set is shown
    /// as processed as soon as one member has, since the common case processes the whole set at once.
    func isProcessed(_ captureSet: CaptureSet) -> Bool {
        captureSet.members.contains { processedAssetPaths.contains($0.url.path) }
    }

    private func ensureSidecarStagingStore() async -> SidecarStagingStore? {
        if let sidecarStagingStore { return sidecarStagingStore }
        do {
            let store = try SidecarStagingStore.makeDefault()
            sidecarStagingStore = store
            return store
        } catch {
            loadErrorMessage = error.localizedDescription
            return nil
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
                processedAssetPaths = await loadProcessedAssetPaths(inFolder: folderURL)
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
