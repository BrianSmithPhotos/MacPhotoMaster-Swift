import AppKit
import Foundation

/// Holds the currently-browsed folder's capture sets and the current selection. Views bind to
/// this via `@StateObject`/`@ObservedObject`; it owns no I/O itself — it kicks off `Service` calls
/// from a `Task` and republishes the results, per docs/ARCHITECTURE.md "Layers".
///
/// `@MainActor` on the class means every property and method here is main-actor-isolated by
/// default: SwiftUI reads `@Published` properties on the main thread, so this guarantees those
/// reads never race the writes below. It's also why `loadFolder` doesn't need to hop back to the
/// main actor explicitly after `await` — the compiler already knows this whole class runs there,
/// and only the `await loader.loadAssets(...)` line itself briefly suspends onto the service's
/// background task.
@MainActor
final class SourceBrowserViewModel: ObservableObject {
    @Published private(set) var captureSets: [CaptureSet] = []
    @Published private(set) var subfolders: [URL] = []
    /// The path from the folder the user opened down to the folder currently displayed — e.g.
    /// `[card, DCIM, 100OLYMP]`. Drives the breadcrumb bar; see docs/SPEC.md §1 "folder tree" and
    /// `FolderBrowser`'s doc comment for why this is breadcrumb navigation rather than a recursive
    /// tree.
    @Published private(set) var breadcrumb: [URL] = []
    @Published private(set) var isLoading = false
    @Published var loadErrorMessage: String?
    /// The single asset shown large in the center preview — always a member of whatever the grid
    /// or filmstrip most recently pointed at. See `multiSelectedIDs` for the separate batch-action
    /// selection.
    ///
    /// `didSet` resyncs the metadata edit buffer below to match whatever's now selected, discarding
    /// any unsaved in-progress edit on the previously-selected asset — there's no autosave-on-switch
    /// in this first pass, see `loadEditBuffer`.
    @Published var selectedAssetID: PhotoAsset.ID? {
        didSet {
            guard selectedAssetID != oldValue else { return }
            loadEditBuffer()
        }
    }

    /// Grid multi-selection (cmd-click toggles a tile, shift-click ranges from the last anchor) —
    /// docs/SPEC.md §1 "Manual multi-select". Always representative ids (one per capture set/single
    /// image tile in the grid); a plain click resets this to just that one tile. Drives the
    /// `.manualSelection` process/move scope and, via `refreshVariantStrip`, what the filmstrip
    /// under the preview shows.
    @Published private(set) var multiSelectedIDs: Set<PhotoAsset.ID> = []
    private var rangeAnchorID: PhotoAsset.ID?

    /// The full capture-group membership of the current grid selection (`SelectionScope.resolveScope`)
    /// — the filmstrip under the preview renders exactly this list, in this order.
    @Published private(set) var variantMemberIDs: [PhotoAsset.ID] = []
    /// Ring-selected subset of `variantMemberIDs` — starts equal to the full scope; cmd-click on a
    /// filmstrip tile narrows it (kept non-empty, mirroring the reference app). Not yet consumed by
    /// any action (there's no "Save Selected"/AI wiring in this app yet) — reserved for that.
    @Published private(set) var variantSelectedIDs: Set<PhotoAsset.ID> = []

    var hasMultiSelection: Bool { multiSelectedIDs.count > 1 }

    /// Where process/move (docs/SPEC.md §5) copies destination files under — picked once via a
    /// folder picker in `SourcePanelView` and persisted in `UserDefaults` so it's only asked for
    /// once rather than every process action; `setLibraryRoot` is also how the user changes it
    /// later. This app has no App Sandbox entitlement (no `.entitlements` file in the package), so
    /// a plain persisted path is enough — no security-scoped bookmark dance required.
    @Published private(set) var libraryRootURL: URL?
    @Published private(set) var isProcessing = false
    @Published var processStatusMessage: String?

    /// The metadata panel's editable fields, kept as free text (parsed via `MetadataEditParsing` at
    /// save time) rather than typed properties so the view can bind `TextField`s directly. Synced
    /// to `selectedAsset`'s current values by `loadEditBuffer` whenever the selection changes. See
    /// docs/SPEC.md §2-3.
    ///
    /// There is no `editableTitle` — Title is not independently user-typed. It tracks
    /// `renamePreviewFilename` below instead, matching the reference app's `metadata_panel` (its
    /// `title_edit` gets overwritten by `_update_rename_preview` on every selection/location change,
    /// so it's effectively a live display of the eventual rename, not a separate saved field — see
    /// `_process_one` in `process_batch_mover.py`, which derives the title actually written to disk
    /// from the rename filename, never from a user-typed title). See [[feedback-follow-reference-app]].
    @Published var editableDescription: String = ""
    @Published var editableKeywords: String = ""
    @Published var editableLatitudeText: String = ""
    @Published var editableLongitudeText: String = ""
    @Published private(set) var isSavingMetadata = false
    @Published var saveStatusMessage: String?

    private let loader = PhotoAssetLoader()
    private let folderBrowser = FolderBrowser()
    private let grouping = CaptureGroupingService()
    private let processMoveService = ProcessMoveService()
    private let exifTool = ExifToolClient()
    private let renameService = RenameService()

    /// The manual per-session label `RenameService` needs for its filename pattern (docs/SPEC.md
    /// §4) — not GPS-derived, so it lives here rather than on `PhotoAsset`. Defaults to empty, in
    /// which case `RenameService` just omits the batch segment.
    ///
    /// `didSet` recomputes `renamePreviewFilename` immediately, so the Title field the user sees
    /// updates live as they type a batch label — same as the reference app's
    /// `location_edit.textChanged` -> `_update_rename_preview` wiring.
    @Published var sessionBatch: String = "" {
        didSet {
            guard sessionBatch != oldValue else { return }
            updateRenamePreview()
        }
    }

    /// Live preview of the filename `RenameService` would generate for `selectedAsset` right now —
    /// recomputed by `updateRenamePreview()` whenever the selection or `sessionBatch` changes.
    /// Uniqueness here is only checked against the *source* folder's existing names (a fast,
    /// dependency-free preview, same as the reference app's `_update_rename_preview`); the
    /// authoritative check against the real destination folder happens at process time in
    /// `ProcessMoveService`, so this can differ from the final name in rare collision cases.
    @Published private(set) var renamePreviewFilename: String = ""

    /// What the Title field displays — the rename preview's filename stem, not a separately typed
    /// or saved value. See the note on `editableDescription` above for why there's no `editableTitle`.
    var titlePreview: String { (renamePreviewFilename as NSString).deletingPathExtension }

    private static let libraryRootDefaultsKey = "libraryRootPath"

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.libraryRootDefaultsKey) {
            libraryRootURL = URL(fileURLWithPath: path)
        }
    }

    /// Called from the library-folder picker, both on first pick and on later changes.
    func setLibraryRoot(_ url: URL) {
        libraryRootURL = url
        UserDefaults.standard.set(url.path, forKey: Self.libraryRootDefaultsKey)
    }

    /// Lazily created on first use rather than in `init` because `SkipStateStore.init` is
    /// throwing (it touches the filesystem to open/migrate the database) and `SourceBrowserViewModel`
    /// is constructed synchronously by SwiftUI (`@StateObject`). Cached after the first successful
    /// creation so every folder load doesn't reopen the database.
    private var skipStore: SkipStateStore?

    /// The folder a just-loaded `CaptureSet` belongs to, keyed by set id — needed by `skip(_:)`
    /// since by the time the user acts, `breadcrumb.last` may already point at a different folder
    /// (they could have navigated on).
    private var folderPathByCaptureSetID: [CaptureSet.ID: String] = [:]

    /// Called from the "Open Folder…" picker — starts a fresh breadcrumb rooted at the chosen
    /// folder. Anything previously open is discarded.
    func openFolder(at folderURL: URL) {
        breadcrumb = [folderURL]
        load(folderURL)
    }

    /// Called when the user clicks a subfolder tile or a breadcrumb segment. Clicking an ancestor
    /// already in the breadcrumb truncates back to it (like clicking a Finder path-bar segment);
    /// clicking a subfolder appends one level.
    func navigate(to folderURL: URL) {
        if let index = breadcrumb.firstIndex(of: folderURL) {
            breadcrumb.removeSubrange((index + 1)...)
        } else {
            breadcrumb.append(folderURL)
        }
        load(folderURL)
    }

    /// Fire-and-forget from the View's perspective: starts an unstructured `Task` so the caller
    /// (a SwiftUI button/tap action) doesn't need to be `async` itself. Re-entrant calls just
    /// replace whatever the previous load was populating.
    ///
    /// The two `async let`s run concurrently — unlike `Task { }`, `async let` creates a
    /// *structured* child task: it's automatically awaited (and cancelled, if this enclosing
    /// `Task` is cancelled) by the time this scope exits, so there's no separate lifetime to
    /// manage the way there would be with two unstructured `Task { }`s.
    private func load(_ folderURL: URL) {
        isLoading = true
        loadErrorMessage = nil
        Task {
            defer { isLoading = false }
            do {
                async let assetsTask = loader.loadAssets(in: folderURL)
                async let subfoldersTask = folderBrowser.subfolders(of: folderURL)
                let (assets, folders) = try await (assetsTask, subfoldersTask)
                let skippedPaths = await skippedAssetPaths(inFolder: folderURL)
                let allSets = grouping.group(assets)
                captureSets = allSets.filter { set in
                    guard let representativePath = set.representative?.url.path else { return true }
                    return !skippedPaths.contains(representativePath)
                }
                folderPathByCaptureSetID = Dictionary(
                    uniqueKeysWithValues: captureSets.map { ($0.id, folderURL.path) })
                subfolders = folders
                selectFirstTile()
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    /// Hides every member of `captureSet` from the current view and persists that choice so it
    /// stays hidden if this folder is reopened later. Never touches the files on disk — see
    /// `SkipStateStore`'s doc comment for why "skip" is view-only.
    func skip(_ captureSet: CaptureSet) {
        guard let folderPath = folderPathByCaptureSetID[captureSet.id] else { return }
        Task {
            guard let store = await ensureSkipStore() else { return }
            let assetPaths = captureSet.members.map(\.url.path)
            try? await store.skip(assetPaths: assetPaths, inFolder: folderPath)

            captureSets.removeAll { $0.id == captureSet.id }
            folderPathByCaptureSetID.removeValue(forKey: captureSet.id)
            if let representativeID = captureSet.representative?.id {
                multiSelectedIDs.remove(representativeID)
            }
            if selectedAssetID == captureSet.representative?.id {
                selectFirstTile()
            } else {
                refreshVariantStrip()
            }
        }
    }

    /// Selects the first tile in the grid (or clears selection if the grid is empty), resetting
    /// the multi-selection and filmstrip to match. Used on a fresh folder load and whenever the
    /// active selection is skipped out from under it.
    private func selectFirstTile() {
        guard let id = captureSets.first?.representative?.id else {
            selectedAssetID = nil
            multiSelectedIDs = []
            rangeAnchorID = nil
            refreshVariantStrip()
            return
        }
        selectedAssetID = id
        multiSelectedIDs = [id]
        rangeAnchorID = id
        refreshVariantStrip()
    }

    /// Maps every asset id to its full capture-group membership (including itself) — the lookup
    /// `SelectionScope`'s pure functions need but don't own themselves.
    private var membersByAssetID: [PhotoAsset.ID: [PhotoAsset.ID]] {
        var map: [PhotoAsset.ID: [PhotoAsset.ID]] = [:]
        for set in captureSets {
            let memberIDs = set.members.map(\.id)
            for id in memberIDs { map[id] = memberIDs }
        }
        return map
    }

    /// Handles a click on a capture-set tile in the source grid: shift-click ranges from the last
    /// anchor, cmd-click toggles the tile in/out of the multi-selection, a plain click resets to a
    /// single selection. Mirrors the reference Python app's `SourcePanel._on_tile_clicked`.
    func selectTile(_ id: PhotoAsset.ID, modifiers: NSEvent.ModifierFlags) {
        let visibleIDs = captureSets.compactMap { $0.representative?.id }
        if modifiers.contains(.shift), let anchor = rangeAnchorID {
            multiSelectedIDs = SelectionScope.rangeBetween(anchor: anchor, target: id, visible: visibleIDs)
        } else if modifiers.contains(.command) {
            if multiSelectedIDs.contains(id) {
                multiSelectedIDs.remove(id)
            } else {
                multiSelectedIDs.insert(id)
            }
            rangeAnchorID = id
        } else {
            multiSelectedIDs = [id]
            rangeAnchorID = id
        }
        selectedAssetID = id
        refreshVariantStrip()
    }

    /// Recomputes the filmstrip's member list and resets its ring-selection to the full scope.
    /// Called after any change to the grid selection.
    private func refreshVariantStrip() {
        guard let selectedAssetID else {
            variantMemberIDs = []
            variantSelectedIDs = []
            return
        }
        let visibleIDs = captureSets.compactMap { $0.representative?.id }
        let orderedMultiSelection = visibleIDs.filter { multiSelectedIDs.contains($0) }
        let scope = SelectionScope.resolveScope(
            selected: selectedAssetID, multiSelected: orderedMultiSelection, membersByID: membersByAssetID)
        variantMemberIDs = scope
        variantSelectedIDs = Set(scope)
    }

    /// Cmd-click on a filmstrip tile: toggles it out of the ring-selection, refusing to drop below
    /// one selected member so the strip is never fully empty (mirrors the reference app).
    func toggleVariantSelection(_ id: PhotoAsset.ID) {
        if variantSelectedIDs.contains(id) {
            guard variantSelectedIDs.count > 1 else { return }
            variantSelectedIDs.remove(id)
        } else {
            variantSelectedIDs.insert(id)
        }
    }

    /// Plain click on a filmstrip tile: switches the large preview to that specific member without
    /// touching the grid multi-selection or the ring-selection.
    func setActivePreview(_ id: PhotoAsset.ID) {
        selectedAssetID = id
    }

    /// Whether the filmstrip's ring-selection has been narrowed away from the full scope it
    /// started at — i.e. the user cmd-clicked at least one member out, but not all the way down to
    /// zero (which `toggleVariantSelection` already disallows).
    var hasPartialVariantSelection: Bool {
        !variantSelectedIDs.isEmpty && variantSelectedIDs.count < variantMemberIDs.count
    }

    /// True when there's a "current selection" distinct from the default single set/asset — either
    /// the grid's manual multi-selection (2+ tiles) or the filmstrip narrowed to a subset of the
    /// active selection's members. Drives whether "Current Selection" is actionable.
    var hasCurrentSelection: Bool { hasMultiSelection || hasPartialVariantSelection }

    /// Assets for a "Current Selection" process/move action (docs/SPEC.md §5's `.manualSelection`
    /// scope). Prefers the filmstrip's narrowed ring-selection when the user has hand-picked a
    /// subset there (e.g. excluded the RAW file from a set they're processing) — the reference
    /// app's variant strip only ever fed a "Save Selected" metadata action, but this app's filmstrip
    /// is also meant to scope process/move. Falls back to the grid's manual multi-selection,
    /// expanded to full capture-group membership, when the filmstrip hasn't been narrowed.
    var manualSelectionAssets: [PhotoAsset] {
        let assetByID = Dictionary(uniqueKeysWithValues: captureSets.flatMap(\.members).map { ($0.id, $0) })
        if hasPartialVariantSelection {
            return variantMemberIDs.filter { variantSelectedIDs.contains($0) }.compactMap { assetByID[$0] }
        }
        guard hasMultiSelection else { return [] }
        let visibleIDs = captureSets.compactMap { $0.representative?.id }
        let ordered = visibleIDs.filter { multiSelectedIDs.contains($0) }
        let expandedIDs = SelectionScope.expandToCaptureGroups(ordered, membersByID: membersByAssetID)
        return expandedIDs.compactMap { assetByID[$0] }
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

    var selectedAsset: PhotoAsset? {
        captureSets
            .flatMap(\.members)
            .first { $0.id == selectedAssetID }
    }

    /// The capture set the selected tile belongs to. Matches on full membership rather than just
    /// `representative` because `setActivePreview` (a filmstrip click) can point `selectedAssetID`
    /// at a non-representative member, e.g. the RAW file behind a stacked JPEG representative.
    var selectedCaptureSet: CaptureSet? {
        captureSets.first { set in set.members.contains { $0.id == selectedAssetID } }
    }

    /// Keyboard-shortcut entry point for skipping the current selection — see `SourcePanelView`'s
    /// delete-key binding. No-op with nothing selected.
    func skipSelected() {
        guard let selectedCaptureSet else { return }
        skip(selectedCaptureSet)
    }

    /// Resolves `scope` to its concrete assets (see `ProcessMoveScope.assets`) and copies each into
    /// `libraryRoot` via `ProcessMoveService`, per docs/SPEC.md §5. One asset's failure (a bad copy,
    /// a metadata-write error) doesn't stop the rest of the scope from processing — failures are
    /// collected and surfaced together afterward, the same "don't let one bad file fail the whole
    /// batch" approach `ExifToolClient` uses. Reports progress/outcome via `processStatusMessage`
    /// rather than `loadErrorMessage`, since that property's View treatment replaces the whole
    /// thumbnail grid — appropriate for a folder-load failure, wrong for a process action that
    /// should leave the grid exactly as it was.
    ///
    /// No-op while a previous call is still running, and no-op on an empty scope (nothing
    /// selected). Auto-skip-on-success (SPEC.md §5: "successfully processed files auto-skip from
    /// the current session view") isn't wired yet — this only performs the copy-and-write-metadata
    /// step.
    func process(scope: ProcessMoveScope, libraryRoot: URL) {
        guard !isProcessing else { return }
        let assets = scope.assets
        guard !assets.isEmpty else { return }

        isProcessing = true
        processStatusMessage = "Processing \(assets.count) file(s)…"
        Task {
            defer { isProcessing = false }
            var failures: [String] = []
            for asset in assets {
                let context = RenameContext(
                    sourceURL: asset.url,
                    capturedAt: asset.capturedAt,
                    cameraModel: asset.cameraModel,
                    lensModel: asset.lensModel,
                    batch: sessionBatch,
                    artFilterToken: asset.artFilterToken)
                do {
                    _ = try await processMoveService.processAndCopy(
                        asset: asset, renameContext: context, libraryRoot: libraryRoot)
                } catch {
                    failures.append("\(asset.url.lastPathComponent): \(error.localizedDescription)")
                }
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

    /// Resets the metadata edit buffer to `selectedAsset`'s current field values (or clears it when
    /// nothing's selected) — called from `selectedAssetID`'s `didSet` so the form always reflects
    /// whichever photo is currently shown large.
    private func loadEditBuffer() {
        guard let asset = selectedAsset else {
            editableDescription = ""
            editableKeywords = ""
            editableLatitudeText = ""
            editableLongitudeText = ""
            updateRenamePreview()
            return
        }
        editableDescription = asset.descriptionText
        editableKeywords = asset.keywords.joined(separator: ", ")
        editableLatitudeText = asset.gpsLatitude.map { String($0) } ?? ""
        editableLongitudeText = asset.gpsLongitude.map { String($0) } ?? ""
        updateRenamePreview()
    }

    /// Recomputes `renamePreviewFilename` for `selectedAsset` against `sessionBatch`'s current
    /// value — see that property's doc comment for why this exists and when it's called.
    private func updateRenamePreview() {
        guard let asset = selectedAsset else {
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

    /// Finds `id` across every capture set and applies `mutate` in place — the one spot that knows
    /// how to reach into `captureSets`' nested `members` arrays, so a successful metadata save can
    /// update in-memory state immediately without re-reading the file back from disk.
    private func updateAsset(_ id: PhotoAsset.ID, _ mutate: (inout PhotoAsset) -> Void) {
        for setIndex in captureSets.indices {
            if let memberIndex = captureSets[setIndex].members.firstIndex(where: { $0.id == id }) {
                mutate(&captureSets[setIndex].members[memberIndex])
                return
            }
        }
    }

    /// Saves the current edit buffer to `scope`'s file(s) via `ExifToolClient`, per docs/SPEC.md §3.
    ///
    /// Title is deliberately not part of this action — per the Python reference app, it is never
    /// user-typed at all, only ever written at Process & Move time from the rename candidate's stem
    /// (see `ProcessMoveService`). Description/keywords/GPS are genuinely shared across a capture
    /// set, so they go out in one batched `exiftool` invocation across every target — see
    /// docs/ARCHITECTURE.md "exiftool integration" for why grouping same-value writes into one
    /// invocation matters. `ExifToolClient`'s batched write already reports per-file success/failure
    /// without letting one bad file cost the group its write, so this just relays that.
    ///
    /// No-op while a previous save is still running.
    func saveMetadata(scope: MetadataSaveScope) {
        guard !isSavingMetadata else { return }
        let description = editableDescription
        let keywords = MetadataEditParsing.parseKeywords(editableKeywords)
        let gps = MetadataEditParsing.parseGPS(
            latitudeText: editableLatitudeText, longitudeText: editableLongitudeText,
            altitude: selectedAsset?.gpsAltitude)

        let targets: [PhotoAsset]
        switch scope {
        case .singleAsset(let asset): targets = [asset]
        case .captureSet(let captureSet): targets = captureSet.members
        }
        guard !targets.isEmpty else { return }

        isSavingMetadata = true
        saveStatusMessage = "Saving…"
        Task {
            defer { isSavingMetadata = false }
            do {
                let results = try await exifTool.write(
                    description: description, keywords: keywords, gps: gps, to: targets.map(\.url))
                var failureCount = 0
                for target in targets {
                    switch results[target.url] {
                    case .success:
                        updateAsset(target.id) { asset in
                            asset.descriptionText = description
                            asset.keywords = keywords
                            if let gps {
                                asset.gpsLatitude = gps.latitude
                                asset.gpsLongitude = gps.longitude
                            }
                        }
                    default:
                        failureCount += 1
                    }
                }
                saveStatusMessage =
                    failureCount == 0
                    ? "Saved to \(targets.count) file(s)."
                    : "Saved \(targets.count - failureCount)/\(targets.count) file(s); \(failureCount) failed."
            } catch {
                saveStatusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}
