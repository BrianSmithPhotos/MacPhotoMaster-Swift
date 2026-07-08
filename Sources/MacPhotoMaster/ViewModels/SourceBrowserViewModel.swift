import AppKit
import Foundation
import os

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
    /// Capture sets skipped in the current folder — populated alongside `captureSets` in `load(_:)`
    /// and kept in sync by `skip(_:)`/`unskip(_:)`. Only ever shown by `SourcePanelView`'s
    /// "Skipped" segmented-filter view; not selectable for editing or process/move.
    @Published private(set) var skippedCaptureSets: [CaptureSet] = []
    /// Which of `captureSets`/`skippedCaptureSets` `SourcePanelView`'s grid currently displays.
    ///
    /// `didSet` re-focuses selection onto the first item of whichever list is now shown — without
    /// this, switching filters left the previous filter's selection/preview lingering (or nothing
    /// selected at all the first time `.skipped` is shown), rather than the grid and preview
    /// agreeing on what's focused.
    @Published var sourceViewFilter: SourceViewFilter = .active {
        didSet {
            guard sourceViewFilter != oldValue else { return }
            selectFirstTile()
        }
    }
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

    /// Status text for the Timeline-derived GPS suggestion (docs/SPEC.md §7) shown under the
    /// lat/long fields — e.g. "Nearest GPS 3m 20s away (GPS, accuracy 12m)". Set by
    /// `suggestGPSIfNeeded()` or by reverse-geocode keyword lookup; cleared on every selection
    /// change by `loadEditBuffer()` so a message from one photo never lingers under another.
    @Published var gpsSuggestionStatusMessage: String?

    /// True while a manually-triggered `refreshTimeline()` Drive sync/import is in flight —
    /// disables the "Refresh Timeline" button so it can't be fired twice concurrently.
    @Published private(set) var isSyncingTimeline = false

    /// Result text for a manually-triggered `refreshTimeline()` — e.g. "Imported 214 Timeline
    /// points." or "Timeline is already up to date." The silent per-launch/per-folder-load sync
    /// (`syncAndImportTimelineIfNeeded()`) never touches this; it's only for the explicit button.
    @Published var timelineSyncStatusMessage: String?

    /// True while `refreshAltitude()` has an elevation lookup in flight — disables the manual
    /// refresh button so a slow/timed-out USGS EPQS call can't be fired twice concurrently.
    @Published private(set) var isLookingUpAltitude = false

    /// AI vision model used for AI-assisted description/keyword suggestions (docs/SPEC.md §6), in
    /// `"<provider>:<model>"` form (see `AIModelSelection`) — editable so the user can point at any
    /// pulled Ollama model or OpenRouter model id without a rebuild.
    @Published var aiModelText: String = AIModelSelection.presets[0]
    /// True while `suggestAI()` has a request (and its immediate auto-save) in flight — disables
    /// the Suggest button so a slow local-model response can't be fired twice concurrently.
    @Published private(set) var isSuggestingAI = false
    @Published var aiStatusMessage: String?
    /// The exact image the last `suggestAI()` call sent to the model (post `SubjectIsolationService`
    /// crop, when one was found) — shown in the Metadata panel so a misidentification is diagnosable
    /// (was the model looking at the subject, or a diluted full frame?).
    @Published private(set) var aiEvaluatedImage: CGImage?

    /// OpenRouter model strings (matching the `"<provider>:<model>"` convention `aiModelText` uses,
    /// e.g. `"openrouter:google/gemini-3.5-flash"`) for which the eBird candidate species list is
    /// withheld from the prompt. The candidate list is extra input-token cost on every request; for
    /// the free local Ollama/MLX providers that's irrelevant, so those always get it (never added
    /// here), but for a few flagship pay-per-token models the user judged the accuracy gain isn't
    /// worth the added cost by default. Persisted in `UserDefaults`; `SettingsView` exposes a
    /// per-model Toggle via `setEBirdCandidateListEnabled(_:forModel:)`.
    @Published private(set) var eBirdDisabledModels: Set<String>

    /// Whether `suggestAI()` crops to `SubjectIsolationService`'s detected subject before sending the
    /// image to the AI. Good for a small/distant bird or flower filling little of the frame; bad for
    /// a general scene (e.g. a street shot), where it can crop to an incidental foreground object —
    /// a parked car, a lamp-post — instead of the scene the user meant to describe. Off by default;
    /// the user flips it on for a bird/flower session and back off for general shooting. Persisted in
    /// `UserDefaults`; `MetadataPanelView` exposes it as a Toggle next to the AI model picker (a
    /// per-session choice, not a rarely-touched preference, so it lives there rather than
    /// `SettingsView`).
    @Published private(set) var subjectIsolationEnabled: Bool

    /// Off-by-default set as of 2026-07-05 — the user's call, not derived from anything measurable;
    /// revisit if the OpenRouter preset list (`AIModelSelection.presets`) changes these model names.
    static let defaultEBirdDisabledModels: Set<String> = [
        "openrouter:google/gemini-3.5-flash",
        "openrouter:anthropic/claude-opus-4.6",
        "openrouter:openai/gpt-5.5",
    ]

    private let loader = PhotoAssetLoader()
    private let folderBrowser = FolderBrowser()
    private let grouping = CaptureGroupingService()
    private let processMoveService = ProcessMoveService()
    private let exifTool = ExifToolClient()
    private let renameService = RenameService()
    private let timelineImportParser = TimelineImportParser()
    private let elevationService = ElevationLookupService()
    private let reverseGeocodeService = ReverseGeocodeService()
    private let ebirdService = EBirdSpeciesListService()
    private let ollamaProvider: AIProvider = OllamaProvider()
    private let openRouterProvider: AIProvider = OpenRouterProvider()
    private let mlxProvider: AIProvider = MLXNativeProvider()
    private let aiSuggestionService = AISuggestionService()
    private static let ebirdLogger = Logger(subsystem: "MacPhotoMaster", category: "EBirdSpecies")

    /// Reverse-geocode context text (docs/SPEC.md §6/§7), keyed by capture-set representative id so
    /// `suggestAI()` can pass along location context for whichever set it's sourcing the AI image
    /// from. Populated by `lookupLocationKeywordsIfNeeded()`.
    private var locationContextByRepresentativeID: [PhotoAsset.ID: String] = [:]
    /// eBird candidate-species list text (see `EBirdCandidateFormatting`/`AISuggestionService`'s doc
    /// comment for why), keyed the same way as `locationContextByRepresentativeID` and populated
    /// alongside it since both come from the same GPS fix. Not part of docs/SPEC.md or the reference
    /// app — added to improve wildlife identification accuracy beyond a single generic prompt.
    private var birdCandidateSpeciesByRepresentativeID: [PhotoAsset.ID: String] = [:]
    /// Guards against re-querying Nominatim for the same capture set more than once per session —
    /// mirrors the reference app's `_geocode_auto_applied_paths`.
    private var geocodeAppliedRepresentativeIDs: Set<PhotoAsset.ID> = []

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
    private static let sourceRootDefaultsKey = "sourceRootPath"
    private static let eBirdDisabledModelsDefaultsKey = "eBirdDisabledModels"
    private static let subjectIsolationEnabledDefaultsKey = "subjectIsolationEnabled"
    /// Falls back to the user's SD card mount point when no source folder has ever been opened.
    /// The card is swapped for a new one roughly every 10K images, far less often than the app is
    /// launched, so defaulting to (and, via `openFolder`, persisting) whatever was last opened
    /// saves an "Open Folder…" click on almost every launch.
    private static let defaultSourceRootPath = "/Volumes/OM SYSTEM/DCIM/105OMSYS/"

    init() {
        if let stored = UserDefaults.standard.array(forKey: Self.eBirdDisabledModelsDefaultsKey)
            as? [String]
        {
            eBirdDisabledModels = Set(stored)
        } else {
            eBirdDisabledModels = Self.defaultEBirdDisabledModels
        }
        subjectIsolationEnabled =
            UserDefaults.standard.bool(forKey: Self.subjectIsolationEnabledDefaultsKey)
        if let path = UserDefaults.standard.string(forKey: Self.libraryRootDefaultsKey) {
            libraryRootURL = URL(fileURLWithPath: path)
        }
        let sourceRootPath =
            UserDefaults.standard.string(forKey: Self.sourceRootDefaultsKey) ?? Self.defaultSourceRootPath
        // `openFolder` -> `load(_:)` already triggers `syncAndImportTimelineIfNeeded()`, covering
        // the launch-time sync too.
        openFolder(at: URL(fileURLWithPath: sourceRootPath))
    }

    /// Called from the library-folder picker, both on first pick and on later changes.
    func setLibraryRoot(_ url: URL) {
        libraryRootURL = url
        UserDefaults.standard.set(url.path, forKey: Self.libraryRootDefaultsKey)
    }

    /// Called from `SettingsView`'s per-model Toggle — see `eBirdDisabledModels`'s doc comment.
    func setEBirdCandidateListEnabled(_ enabled: Bool, forModel model: String) {
        if enabled {
            eBirdDisabledModels.remove(model)
        } else {
            eBirdDisabledModels.insert(model)
        }
        UserDefaults.standard.set(
            Array(eBirdDisabledModels), forKey: Self.eBirdDisabledModelsDefaultsKey)
    }

    /// Called from `MetadataPanelView`'s subject-crop Toggle — see `subjectIsolationEnabled`'s doc
    /// comment.
    func setSubjectIsolationEnabled(_ enabled: Bool) {
        subjectIsolationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.subjectIsolationEnabledDefaultsKey)
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

    /// Called from the "Open Folder…" picker (and from `init` to reopen last time's root) — starts
    /// a fresh breadcrumb rooted at the chosen folder, discarding anything previously open, and
    /// persists `folderURL` as the new default source root so the next launch starts here too. The
    /// picker is only ever expected to change roots roughly every 10K images, so it's cheap to
    /// re-persist the same path most of the time this is called from `init`.
    func openFolder(at folderURL: URL) {
        UserDefaults.standard.set(folderURL.path, forKey: Self.sourceRootDefaultsKey)
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
        Task { await syncAndImportTimelineIfNeeded() }
        Task {
            defer { isLoading = false }
            do {
                async let assetsTask = loader.loadAssets(in: folderURL)
                async let subfoldersTask = folderBrowser.subfolders(of: folderURL)
                let (assets, folders) = try await (assetsTask, subfoldersTask)
                let skippedPaths = await skippedAssetPaths(inFolder: folderURL)
                processedAssetPaths = await loadProcessedAssetPaths(inFolder: folderURL)
                let allSets = grouping.group(assets)
                captureSets = allSets.filter { set in
                    guard let representativePath = set.representative?.url.path else { return true }
                    return !skippedPaths.contains(representativePath)
                }
                skippedCaptureSets = allSets.filter { set in
                    guard let representativePath = set.representative?.url.path else { return false }
                    return skippedPaths.contains(representativePath)
                }
                folderPathByCaptureSetID = Dictionary(
                    uniqueKeysWithValues: allSets.map { ($0.id, folderURL.path) })
                subfolders = folders
                selectFirstTile()
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    /// Hides every member of `captureSet` from the active view and persists that choice so it
    /// stays hidden if this folder is reopened later — moves it into `skippedCaptureSets`, visible
    /// via `SourcePanelView`'s "Skipped" filter and restorable with `unskip(_:)`. Never touches the
    /// files on disk — see `SkipStateStore`'s doc comment for why "skip" is view-only.
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
            if let representativeID = captureSet.representative?.id {
                multiSelectedIDs.remove(representativeID)
            }
            if selectedAssetID == captureSet.representative?.id {
                selectTileAfterRemoval(from: captureSets, previousIndex: removedIndex)
            } else {
                refreshVariantStrip()
            }
        }
    }

    /// Restores `captureSet` from `skippedCaptureSets` back into the active `captureSets` — the
    /// inverse of `skip(_:)`, reachable only via `SourcePanelView`'s "Skipped" filter's context-menu
    /// "Un-skip" action (never a side effect of previewing/clicking a tile there). Reconciles
    /// selection the same way `skip(_:)` does when the un-skipped item was the one currently
    /// previewed, so un-skipping while reviewing the Skipped grid moves focus to the next skipped
    /// item rather than leaving the preview pointed at something no longer in that list.
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

    /// Restores grouping order (ascending by representative capture time) after `skip(_:)`/
    /// `unskip(_:)` splice a set into the middle of `captureSets`/`skippedCaptureSets` rather than
    /// rebuilding from a fresh `CaptureGroupingService.group(_:)` call — see that type for the
    /// canonical ordering this mirrors.
    private func sortByCaptureOrder(_ sets: inout [CaptureSet]) {
        sets.sort {
            ($0.representative?.capturedAt ?? .distantPast) < ($1.representative?.capturedAt ?? .distantPast)
        }
    }

    /// Selects the first tile in whichever list `sourceViewFilter` currently displays (or clears
    /// selection if that list is empty), resetting the multi-selection and filmstrip to match. Used
    /// on a fresh folder load and whenever `sourceViewFilter` changes, so the grid and the preview
    /// always agree on what's focused.
    private func selectFirstTile() {
        guard let id = displayedCaptureSets.first?.representative?.id else {
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

    /// Selects whichever capture set now sits at `previousIndex` in `sets` — the set that took the
    /// just-removed set's place, i.e. the *next* one in capture order, since `skip(_:)`/`unskip(_:)`
    /// remove without re-sorting. Falls back to the new last set if the removed one was last, or
    /// clears selection if `sets` is now empty. Shared by `skip(_:)` (passing `captureSets`) and
    /// `unskip(_:)` (passing `skippedCaptureSets`) so focus stays near where the user was working
    /// instead of jumping back to the first tile in the folder.
    private func selectTileAfterRemoval(from sets: [CaptureSet], previousIndex: Int) {
        guard !sets.isEmpty else {
            selectedAssetID = nil
            multiSelectedIDs = []
            rangeAnchorID = nil
            refreshVariantStrip()
            return
        }
        let index = min(previousIndex, sets.count - 1)
        guard let id = sets[index].representative?.id else {
            selectFirstTile()
            return
        }
        selectedAssetID = id
        multiSelectedIDs = [id]
        rangeAnchorID = id
        refreshVariantStrip()
    }

    /// Whichever of `captureSets`/`skippedCaptureSets` `sourceViewFilter` currently displays —
    /// selection, range/multi-select, and the filmstrip all operate against this so browsing the
    /// Skipped filter previews and (multi-)selects within that list exactly like the Active filter
    /// does, without any of it touching skip state.
    private var displayedCaptureSets: [CaptureSet] {
        switch sourceViewFilter {
        case .active: return captureSets
        case .skipped: return skippedCaptureSets
        }
    }

    /// Maps every asset id (within `displayedCaptureSets`) to its full capture-group membership
    /// (including itself) — the lookup `SelectionScope`'s pure functions need but don't own
    /// themselves.
    private var membersByAssetID: [PhotoAsset.ID: [PhotoAsset.ID]] {
        var map: [PhotoAsset.ID: [PhotoAsset.ID]] = [:]
        for set in displayedCaptureSets {
            let memberIDs = set.members.map(\.id)
            for id in memberIDs { map[id] = memberIDs }
        }
        return map
    }

    /// Handles a click on a capture-set tile in the source grid: shift-click ranges from the last
    /// anchor, cmd-click toggles the tile in/out of the multi-selection, a plain click resets to a
    /// single selection. Mirrors the reference Python app's `SourcePanel._on_tile_clicked`. Used the
    /// same way regardless of `sourceViewFilter` — previewing/multi-selecting a skipped item never
    /// un-skips it; only `SourcePanelView`'s "Un-skip" context-menu action does that.
    func selectTile(_ id: PhotoAsset.ID, modifiers: NSEvent.ModifierFlags) {
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
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
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
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
        let assetByID = Dictionary(uniqueKeysWithValues: displayedCaptureSets.flatMap(\.members).map { ($0.id, $0) })
        if hasPartialVariantSelection {
            return variantMemberIDs.filter { variantSelectedIDs.contains($0) }.compactMap { assetByID[$0] }
        }
        guard hasMultiSelection else { return [] }
        let visibleIDs = displayedCaptureSets.compactMap { $0.representative?.id }
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

    /// Paths (within the currently loaded folder) that have already been through Process & Move at
    /// least once — drives the non-blocking checkmark badge on `CaptureTileView`/`VariantTileView`.
    /// Purely informational: unlike `skippedCaptureSets`, being in this set never hides or disables
    /// anything, since reprocessing must stay freely available.
    @Published private(set) var processedAssetPaths: Set<String> = []

    /// Lazily created for the same reason as `skipStore` above.
    private var processedStore: ProcessedStateStore?

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
    /// badge appears immediately, without waiting for the next folder load.
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

    /// Lazily created for the same reason as `skipStore` above — `TimelineLocationCache.init` is
    /// throwing filesystem/database work, so it can't happen synchronously in `init()`.
    private var timelineCache: TimelineLocationCache?

    private func ensureTimelineCache() async -> TimelineLocationCache? {
        if let timelineCache { return timelineCache }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "timeline_location.sqlite3")
            let cache = try TimelineLocationCache(databasePath: databasePath)
            timelineCache = cache
            return cache
        } catch {
            return nil
        }
    }

    private var elevationCache: ElevationCache?

    private func ensureElevationCache() async -> ElevationCache? {
        if let elevationCache { return elevationCache }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "elevation_cache.sqlite3")
            let cache = try ElevationCache(databasePath: databasePath)
            elevationCache = cache
            return cache
        } catch {
            return nil
        }
    }

    private var ebirdCache: EBirdCache?

    private func ensureEBirdCache() async -> EBirdCache? {
        if let ebirdCache { return ebirdCache }
        do {
            let databasePath = try AppSupportDirectory.url(forFileNamed: "ebird_cache.sqlite3")
            let cache = try EBirdCache(databasePath: databasePath)
            ebirdCache = cache
            return cache
        } catch {
            return nil
        }
    }

    private enum TimelineSyncOutcome {
        case imported(sampleCount: Int)
        case upToDate
        case sourceNotFound
        case failed
    }

    /// Copies down a fresher `Timeline.json` from Google Drive (if present) and imports it into
    /// `timelineCache` when its (path, size, mtime) signature has changed — see docs/SPEC.md §7 and
    /// `TimelineLocationCache.isImportNeeded`. Shared by the silent per-launch/per-folder-load sync
    /// (`syncAndImportTimelineIfNeeded()`) and the explicit `refreshTimeline()` button action.
    private func performTimelineSync() async -> TimelineSyncOutcome {
        guard let localCopyPath = try? TimelineDriveSync.resolveLocalCopyPath() else { return .failed }
        if let driveSourcePath = TimelineDriveSync.resolveDriveSourcePath() {
            _ = try? TimelineDriveSync.syncIfNewer(driveSource: driveSourcePath, localCopy: localCopyPath)
        }
        guard FileManager.default.fileExists(atPath: localCopyPath.path) else { return .sourceNotFound }
        guard let cache = await ensureTimelineCache() else { return .failed }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: localCopyPath.path)
            let size = (attributes[.size] as? Int) ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            let modificationNanoseconds = Int64(modificationDate.timeIntervalSince1970 * 1_000_000_000)

            guard
                try await cache.isImportNeeded(
                    sourcePath: localCopyPath.path, sourceSize: size,
                    sourceModificationNanoseconds: modificationNanoseconds)
            else { return .upToDate }

            let samples = try timelineImportParser.parseSamples(fromFileAt: localCopyPath)
            let sha256 = try FileHashing.sha256(of: localCopyPath)
            try await cache.importSamples(
                samples, sourcePath: localCopyPath.path, sourceSize: size,
                sourceModificationNanoseconds: modificationNanoseconds, sourceSHA256: sha256)
            return .imported(sampleCount: samples.count)
        } catch {
            return .failed
        }
    }

    /// Silent best-effort Timeline sync/import called from `init` and from every `load(_:)` (i.e.
    /// on folder open/navigate), so replacing `Timeline.json` on Drive mid-session doesn't require
    /// an app relaunch to be picked up. Failure just means GPS suggestions stay unavailable, not a
    /// user-facing error — see `TimelineDriveSync`'s doc comment.
    private func syncAndImportTimelineIfNeeded() async {
        _ = await performTimelineSync()
    }

    /// Explicit "Refresh Timeline" button action — runs the same sync/import as
    /// `syncAndImportTimelineIfNeeded()` but reports the outcome via `timelineSyncStatusMessage`
    /// instead of staying silent, since a user pressing a button expects to see what happened.
    func refreshTimeline() async {
        isSyncingTimeline = true
        defer { isSyncingTimeline = false }
        switch await performTimelineSync() {
        case .imported(let sampleCount):
            timelineSyncStatusMessage = "Imported \(sampleCount) Timeline point(s)."
        case .upToDate:
            timelineSyncStatusMessage = "Timeline is already up to date."
        case .sourceNotFound:
            timelineSyncStatusMessage = "No Timeline.json found."
        case .failed:
            timelineSyncStatusMessage = "Timeline refresh failed."
        }
    }

    /// Timeline-derived GPS suggestion for `selectedAsset`, auto-applied on first focus of a
    /// GPS-less photo — mirrors the reference app's UX (see docs/SPEC.md §7 and
    /// `loadArtFilterTokenIfNeeded()`'s doc comment for the same lazy-per-selection shape). No-ops
    /// whenever the asset already has embedded GPS or the edit buffer already holds something (a
    /// prior suggestion or an in-progress user edit), so this never overwrites real data. Chains an
    /// elevation lookup after a successful match, since altitude is never trusted from Timeline
    /// itself (SPEC.md §7).
    func suggestGPSIfNeeded() async {
        guard let id = selectedAssetID, let asset = selectedAsset,
            asset.gpsLatitude == nil, asset.gpsLongitude == nil,
            editableLatitudeText.isEmpty, editableLongitudeText.isEmpty,
            let capturedAt = asset.capturedAt
        else { return }
        guard let cache = await ensureTimelineCache() else { return }

        let captureTimestampUTC = Int(capturedAt.timeIntervalSince1970)
        guard let suggestion = try? await cache.suggestion(forCaptureTimestampUTC: captureTimestampUTC),
            selectedAssetID == id
        else { return }

        editableLatitudeText = String(suggestion.latitude)
        editableLongitudeText = String(suggestion.longitude)
        let accuracyText = suggestion.accuracyMeters.map { String(format: ", accuracy %.0fm", $0) } ?? ""
        gpsSuggestionStatusMessage =
            "Nearest GPS \(suggestion.ageSeconds / 60)m \(suggestion.ageSeconds % 60)s away "
            + "(\(suggestion.sourceType)\(accuracyText))"

        await lookupElevation(for: id, latitude: suggestion.latitude, longitude: suggestion.longitude)
    }

    private func lookupElevation(for id: PhotoAsset.ID, latitude: Double, longitude: Double) async {
        guard let elevationCache = await ensureElevationCache() else { return }

        if let cached = try? await elevationCache.cachedElevation(latitude: latitude, longitude: longitude) {
            guard selectedAssetID == id else { return }
            updateAsset(id) { $0.gpsAltitude = cached }
            return
        }

        guard let elevation = try? await elevationService.lookupElevation(latitude: latitude, longitude: longitude)
        else { return }
        try? await elevationCache.store(latitude: latitude, longitude: longitude, elevationMeters: elevation)

        guard selectedAssetID == id else { return }
        updateAsset(id) { $0.gpsAltitude = elevation }
    }

    /// Manually re-runs the elevation lookup for the current lat/long — surfaced as a small refresh
    /// button next to the Altitude field for the rare case the automatic USGS EPQS call times out
    /// (mirrors the reference app's manual "lookup altitude" button, `gps_coordinator.py`'s
    /// `_start_altitude_lookup`). No-ops while a lookup is already in flight or lat/long is blank.
    func refreshAltitude() async {
        guard !isLookingUpAltitude, let id = selectedAssetID,
            let latitude = Double(editableLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let longitude = Double(editableLongitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }

        isLookingUpAltitude = true
        defer { isLookingUpAltitude = false }
        await lookupElevation(for: id, latitude: latitude, longitude: longitude)
    }

    /// Reverse-geocodes the selected asset's GPS (embedded or freshly Timeline-suggested) into
    /// city/county/state, merges those into the keyword edit buffer, and keeps the result around
    /// keyed by capture-set representative so `suggestAI()` can pass it to the model as location
    /// context — docs/SPEC.md §6/§7, mirrors the reference app's `_start_reverse_geocode`/
    /// `_on_reverse_geocoded`. No-ops without GPS in the edit buffer, and only looks up once per
    /// capture set per session so re-selecting the same set doesn't re-hit the network. Meant to run
    /// after `suggestGPSIfNeeded()` in the same `.task(id:)` chain, so embedded GPS (already in the
    /// buffer from `loadEditBuffer`) and Timeline-suggested GPS (just written by that call) are both
    /// covered by one guard.
    func lookupLocationKeywordsIfNeeded() async {
        guard let id = selectedAssetID,
            let latitude = Double(editableLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let longitude = Double(editableLongitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let representativeID = selectedCaptureSet?.representative?.id,
            !geocodeAppliedRepresentativeIDs.contains(representativeID)
        else { return }
        geocodeAppliedRepresentativeIDs.insert(representativeID)

        guard
            let result = try? await reverseGeocodeService.lookupLocation(
                latitude: latitude, longitude: longitude)
        else { return }
        locationContextByRepresentativeID[representativeID] = result.contextText
        await lookupBirdCandidates(
            representativeID: representativeID, county: result.county,
            stateRegionCode: result.stateRegionCode)

        let tokens = result.keywordTokens
        guard !tokens.isEmpty, selectedAssetID == id else { return }
        var keywords = MetadataEditParsing.parseKeywords(editableKeywords)
        var seenLowercased = Set(keywords.map { $0.lowercased() })
        for token in tokens where seenLowercased.insert(token.lowercased()).inserted {
            keywords.append(token)
        }
        editableKeywords = keywords.joined(separator: ", ")
        gpsSuggestionStatusMessage = "Added location keywords: \(tokens.joined(separator: ", "))"
    }

    private static let birdRegionSpeciesMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let birdTaxonomyMaxAge: TimeInterval = 90 * 24 * 60 * 60
    /// Safety valve against prompt-token growth for the noisy state-level fallback case (a raw state
    /// species list can exceed 1,000 codes) — see `EBirdCandidateFormatting.buildCandidateList`.
    private static let birdCandidateListLimit = 500

    /// Resolves `county` (falling back to the bare `stateRegionCode` when county resolution fails or
    /// isn't available) to an eBird region code, fetches/caches that region's species list and the
    /// global taxonomy, and stores the formatted candidate list for `suggestAI()` to pass along.
    /// No-ops without a `stateRegionCode` (Nominatim didn't report one for this coordinate) or if the
    /// eBird cache can't be opened; any other failure here just means the AI prompt goes out without
    /// a candidate list, matching `lookupLocationKeywordsIfNeeded`'s best-effort posture. Every
    /// no-op path logs why — a silent no-op here previously cost a debugging session tracing a
    /// fabricated species name back to a missing `EBIRD_API_KEY` (env var or Keychain, see
    /// `APIKeyStore`).
    private func lookupBirdCandidates(
        representativeID: PhotoAsset.ID, county: String, stateRegionCode: String?
    ) async {
        guard let stateRegionCode else {
            Self.ebirdLogger.log("Bird candidates skipped: no eBird state region code for this location")
            return
        }
        guard APIKeyStore.resolve(envVar: "EBIRD_API_KEY", account: "EBIRD_API_KEY") != nil else {
            Self.ebirdLogger.log("Bird candidates skipped: EBIRD_API_KEY not set (env or Keychain)")
            return
        }
        guard let cache = await ensureEBirdCache() else {
            Self.ebirdLogger.log("Bird candidates skipped: could not open EBirdCache")
            return
        }

        var regionCode = stateRegionCode
        if !county.isEmpty,
            let regions = try? await ebirdService.fetchSubnational2Regions(
                parentCode: stateRegionCode),
            let matched = EBirdCandidateFormatting.matchRegion(countyName: county, in: regions)
        {
            regionCode = matched.code
        } else {
            Self.ebirdLogger.log(
                "Bird candidates: county \(county, privacy: .public) not resolved, falling back to state region \(stateRegionCode, privacy: .public)"
            )
        }

        guard let codes = await birdSpeciesCodes(forRegionCode: regionCode, cache: cache) else {
            Self.ebirdLogger.log(
                "Bird candidates skipped: species-code fetch failed for region=\(regionCode, privacy: .public)"
            )
            return
        }
        guard let taxonomy = await birdTaxonomyEntries(forSpeciesCodes: codes, cache: cache) else {
            Self.ebirdLogger.log("Bird candidates skipped: taxonomy fetch failed")
            return
        }

        let candidateList = EBirdCandidateFormatting.buildCandidateList(
            speciesCodes: codes, taxonomy: taxonomy, limit: Self.birdCandidateListLimit)
        guard !candidateList.isEmpty else {
            Self.ebirdLogger.log(
                "Bird candidates skipped: 0 taxonomy matches for \(codes.count, privacy: .public) species codes in region=\(regionCode, privacy: .public)"
            )
            return
        }
        birdCandidateSpeciesByRepresentativeID[representativeID] = candidateList
        Self.ebirdLogger.log(
            "Bird candidates: region=\(regionCode, privacy: .public) speciesCodes=\(codes.count, privacy: .public) matched=\(taxonomy.count, privacy: .public)"
        )
    }

    private func birdSpeciesCodes(forRegionCode regionCode: String, cache: EBirdCache) async -> [String]? {
        if let cached = try? await cache.cachedSpeciesCodes(regionCode: regionCode),
            Date().timeIntervalSince(cached.fetchedAt) < Self.birdRegionSpeciesMaxAge
        {
            return cached.codes
        }
        guard let codes = try? await ebirdService.fetchSpeciesCodes(regionCode: regionCode) else {
            return nil
        }
        try? await cache.storeSpeciesCodes(codes, regionCode: regionCode)
        return codes
    }

    private func birdTaxonomyEntries(
        forSpeciesCodes codes: [String], cache: EBirdCache
    ) async -> [EBirdTaxonEntry]? {
        let taxonomyFetchedAt = try? await cache.taxonomyFetchedAt()
        let isFresh = taxonomyFetchedAt.map { Date().timeIntervalSince($0) < Self.birdTaxonomyMaxAge } ?? false
        if !isFresh, let taxonomy = try? await ebirdService.fetchTaxonomy() {
            try? await cache.replaceTaxonomy(taxonomy)
        }
        return try? await cache.taxonomyEntries(forSpeciesCodes: codes)
    }

    /// Sends the AI-source representative image (docs/SPEC.md §6: prefer RAW over a heavily
    /// in-camera-filtered JPEG) to whichever provider `aiModelText` selects (see
    /// `AIModelSelection`) and fills the description/keywords fields with its response, then
    /// auto-saves immediately — matching the Python reference app's behavior exactly, per user
    /// direction (there is no separate accept/apply step). When
    /// the grid has a multi-capture-set selection active, the suggestion is applied and saved to
    /// every member of every selected set, but the image sent to the model is always drawn from
    /// the *first* selected set (grid order) — picking a dissimilar mix of sets to suggest across
    /// is the user's own responsibility, not something this method tries to detect.
    func suggestAI() async {
        guard !isSuggestingAI, let id = selectedAssetID else { return }
        guard let selection = AIModelSelection.parse(aiModelText) else {
            aiStatusMessage =
                "Invalid AI model — expected \"ollama:<model>\", \"openrouter:<model>\", or \"mlx:<model>\""
            return
        }
        let provider: AIProvider
        switch selection.providerID {
        case .ollama: provider = ollamaProvider
        case .openRouter: provider = openRouterProvider
        case .mlx: provider = mlxProvider
        }

        let targetAssets: [PhotoAsset]
        let sourceSetMembers: [PhotoAsset]
        let sourceRepresentativeID: PhotoAsset.ID?
        if hasMultiSelection {
            targetAssets = manualSelectionAssets
            guard
                let firstSelectedSet = captureSets.first(where: {
                    guard let representativeID = $0.representative?.id else { return false }
                    return multiSelectedIDs.contains(representativeID)
                })
            else { return }
            sourceSetMembers = firstSelectedSet.members
            sourceRepresentativeID = firstSelectedSet.representative?.id
        } else {
            guard let captureSet = selectedCaptureSet else { return }
            targetAssets = captureSet.members
            sourceSetMembers = captureSet.members
            sourceRepresentativeID = captureSet.representative?.id
        }
        guard !targetAssets.isEmpty,
            let sourceAsset = AISuggestionSourcePicker.pickSourceAsset(from: sourceSetMembers)
        else { return }
        let locationContext = sourceRepresentativeID.flatMap { locationContextByRepresentativeID[$0] } ?? ""
        let birdCandidateSpecies =
            eBirdDisabledModels.contains(aiModelText)
            ? ""
            : sourceRepresentativeID.flatMap { birdCandidateSpeciesByRepresentativeID[$0] } ?? ""

        isSuggestingAI = true
        aiStatusMessage = "Generating AI suggestions…"
        defer { isSuggestingAI = false }
        do {
            let cgImage = try await NativeMetadataReader().extractPreviewAsync(at: sourceAsset.url)
            let subjectCrop =
                subjectIsolationEnabled ? SubjectIsolationService.isolateSubject(in: cgImage) : nil
            let evaluatedImage = subjectCrop ?? cgImage
            guard selectedAssetID == id else { return }
            // Only show the "Evaluated" crop when it's actually a crop (subject-isolation found a
            // subject) — with the toggle off, or no subject found, the full frame was sent and
            // showing it back as "Evaluated" would just duplicate the source photo for no reason.
            aiEvaluatedImage = subjectCrop
            let result = try await aiSuggestionService.suggest(
                provider: provider, model: selection.modelName, image: evaluatedImage,
                existingDescription: editableDescription, existingKeywords: editableKeywords,
                locationContext: locationContext, birdCandidateSpecies: birdCandidateSpecies)
            guard selectedAssetID == id else { return }
            editableDescription = result.description
            editableKeywords = result.keywords.joined(separator: ", ")
            // The timeout-retry crop (`AISuggestionService`'s separate fallback, unrelated to the
            // subject-isolation toggle) is a genuine crop worth surfacing even if `subjectCrop` was
            // nil; otherwise keep whatever `subjectCrop` decided above.
            aiEvaluatedImage = result.timeoutRetrySucceeded ? result.evaluatedImage : subjectCrop
            let categorySuffix = result.sceneCategory == .other ? "" : " [\(result.sceneCategory.rawValue)]"
            aiStatusMessage =
                (result.timeoutRetrySucceeded ? "Suggested (after retry)" : "Suggested")
                + categorySuffix + "; saving…"
            let saveStatus = await performSave(scope: .manualSelection(targetAssets))
            guard selectedAssetID == id else { return }
            if let saveStatus {
                aiStatusMessage = "Suggested\(categorySuffix); \(saveStatus)"
            }
        } catch {
            guard selectedAssetID == id else { return }
            aiStatusMessage = "AI suggestion failed: \(error.localizedDescription)"
        }
    }

    var selectedAsset: PhotoAsset? {
        displayedCaptureSets
            .flatMap(\.members)
            .first { $0.id == selectedAssetID }
    }

    /// The capture set the selected tile belongs to. Matches on full membership rather than just
    /// `representative` because `setActivePreview` (a filmstrip click) can point `selectedAssetID`
    /// at a non-representative member, e.g. the RAW file behind a stacked JPEG representative.
    var selectedCaptureSet: CaptureSet? {
        displayedCaptureSets.first { set in set.members.contains { $0.id == selectedAssetID } }
    }

    /// Keyboard-shortcut entry point for skipping the current selection — see `SourcePanelView`'s
    /// delete-key binding, which is disabled while browsing the Skipped filter so this can't be
    /// invoked on a set that's already skipped. No-op with nothing selected.
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
        // Captured now, not read from `breadcrumb.last` after the `Task` finishes — mirrors
        // `skip(_:)`'s reasoning: the user could navigate to a different folder while this is
        // still running.
        let folderPath = breadcrumb.last?.path

        isProcessing = true
        processStatusMessage = "Processing \(assets.count) file(s)…"
        Task {
            defer { isProcessing = false }
            await loadArtFilterTokens(for: assets)
            let assetByID = Dictionary(
                uniqueKeysWithValues: captureSets.flatMap(\.members).map { ($0.id, $0) })
            var failures: [String] = []
            var processedPaths: [String] = []
            for asset in assets {
                let asset = assetByID[asset.id] ?? asset
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

    /// Resets the metadata edit buffer to `selectedAsset`'s current field values (or clears it when
    /// nothing's selected) — called from `selectedAssetID`'s `didSet` so the form always reflects
    /// whichever photo is currently shown large. Also clears `gpsSuggestionStatusMessage`, since
    /// it's a shared status line for both the Timeline-GPS-suggestion and reverse-geocode-keyword
    /// features — without this it would keep showing the previous photo's message (e.g. a geocoded
    /// location) for a newly selected photo that has no GPS at all.
    private func loadEditBuffer() {
        gpsSuggestionStatusMessage = nil
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

    /// Lazily reads `selectedAsset`'s maker-note fields via `ExifToolClient` and fills in
    /// `artFilterToken`, per docs/SPEC.md §2/§4 — `NativeMetadataReader`'s fast ImageIO-based
    /// initial load can't reach Olympus's proprietary maker-note tags (see its doc comment), so
    /// this fills the gap with one `exiftool` read for whichever asset is actually being looked at.
    /// Meant to be driven by a View's `.task(id: selectedAssetID)`, which cancels any still-in-
    /// flight read for the previous asset on reselection; the `selectedAssetID == id` guard after
    /// the `await` discards a stale result that finishes after the selection has already moved on
    /// (the underlying `exiftool` process isn't itself interruptible by task cancellation). `nil`
    /// on `artFilterToken` means "not yet loaded" — once loaded it's set to `""` rather than left
    /// `nil` even when no art filter was found, so this never re-reads the same file twice. Batch
    /// scopes (capture set / session / manual selection) use `loadArtFilterTokens(for:)` below
    /// instead, since a per-asset read there would be one `exiftool` process launch per file.
    ///
    /// Also corrects `descriptionText` from this same `exiftool` read: real camera-original JPEGs
    /// (confirmed against an actual OM SYSTEM card file, not just synthetic fixtures) have an
    /// ImageIO limitation where `CGImageSourceCopyPropertiesAtIndex`'s IPTC dictionary — and even
    /// `CGImageMetadataCreateFromXMPData`'s `dc:description` — comes back as an empty string for
    /// `Caption-Abstract`/`XMP-dc:Description` despite the on-disk IPTC bytes being correct (verified
    /// by parsing the raw IPTC IIM dataset directly: the `2:120` Caption-Abstract entry is present
    /// with the right value). Byline/copyright/keywords in the same file parse fine via ImageIO, so
    /// this is narrowly a `Caption-Abstract`/description read gap, not a general IPTC failure.
    /// `NativeMetadataReader`'s initial scan (`PhotoAssetLoader`) is the path affected, since it
    /// never shells out to `exiftool`; this only overwrites `editableDescription` if the user
    /// hasn't already started typing into it since selecting this asset.
    func loadArtFilterTokenIfNeeded() async {
        guard let id = selectedAssetID, let asset = selectedAsset, asset.artFilterToken == nil
        else { return }
        let descriptionBeforeFetch = asset.descriptionText
        guard let metadata = try? await exifTool.readMetadata(at: asset.url) else { return }
        guard selectedAssetID == id else { return }
        updateAsset(id) { current in
            current.artFilterToken = ArtFilterTokenParsing.token(from: metadata)
            current.focusDistance = (metadata["Olympus:FocusDistance"] as? String) ?? ""
            if let correctedDescription = metadata["IPTC:Caption-Abstract"] as? String,
                !correctedDescription.isEmpty, correctedDescription != current.descriptionText {
                current.descriptionText = correctedDescription
            }
        }
        updateRenamePreview()
        if editableDescription == descriptionBeforeFetch {
            editableDescription = selectedAsset?.descriptionText ?? editableDescription
        }
    }

    /// Batch-fills `artFilterToken` for every asset in `assets` that doesn't have one loaded yet,
    /// via `ExifToolClient`'s already-batched multi-file read rather than one `exiftool` launch per
    /// file — called before Process & Move so a full capture-set/session/manual-selection scope
    /// gets an accurate art-filter rename token even for files the user never individually selected
    /// (the only thing that triggers `loadArtFilterTokenIfNeeded` above). Also applies that same
    /// function's `descriptionText` correction (see its doc comment for the ImageIO
    /// `Caption-Abstract` read gap) — without this, an asset the user never selected keeps whatever
    /// empty/wrong description `PhotoAssetLoader`'s ImageIO-only scan produced, and Process & Move
    /// would write just the art-filter note to the destination on top of that empty string, even
    /// though the source file's on-disk description was always correct.
    private func loadArtFilterTokens(for assets: [PhotoAsset]) async {
        let missing = assets.filter { $0.artFilterToken == nil }
        guard !missing.isEmpty else { return }
        let results = (try? await exifTool.readMetadata(at: missing.map(\.url))) ?? [:]
        for asset in missing {
            guard case .success(let metadata) = results[asset.url] else { continue }
            updateAsset(asset.id) { current in
                current.artFilterToken = ArtFilterTokenParsing.token(from: metadata)
                current.focusDistance = (metadata["Olympus:FocusDistance"] as? String) ?? ""
                if let correctedDescription = metadata["IPTC:Caption-Abstract"] as? String,
                    !correctedDescription.isEmpty, correctedDescription != current.descriptionText {
                    current.descriptionText = correctedDescription
                }
            }
        }
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
    /// set, but the auto-applied tokens (docs/SPEC.md §6: SOOC keyword, art-filter note) can differ
    /// per file within that same scope — a RAW file gets no SOOC token, a filtered JPEG sibling
    /// does — so targets are grouped by their *computed* (description, keywords) pair and each
    /// group goes out in its own batched `exiftool` invocation, rather than one invocation with
    /// identical values for the whole scope. `ExifToolClient`'s batched write already reports
    /// per-file success/failure without letting one bad file cost its group the write, so this just
    /// relays that per group.
    ///
    /// No-op while a previous save is still running.
    func saveMetadata(scope: MetadataSaveScope) {
        Task { await performSave(scope: scope) }
    }

    /// Does the actual save, returning the final status text (`nil` if a save was already running
    /// or there was nothing to save) — factored out of `saveMetadata(scope:)` so `suggestAI()` can
    /// `await` this directly and fold the outcome into its own status caption, instead of the
    /// caption getting stuck on "saving…" while a fire-and-forget `Task` finishes in the
    /// background.
    @discardableResult
    private func performSave(scope: MetadataSaveScope) async -> String? {
        guard !isSavingMetadata else { return nil }
        let description = editableDescription
        let keywords = MetadataEditParsing.parseKeywords(editableKeywords)
        let gps = MetadataEditParsing.parseGPS(
            latitudeText: editableLatitudeText, longitudeText: editableLongitudeText,
            altitude: selectedAsset?.gpsAltitude)

        let targets: [PhotoAsset]
        switch scope {
        case .singleAsset(let asset): targets = [asset]
        case .captureSet(let captureSet): targets = captureSet.members
        case .manualSelection(let assets): targets = assets
        }
        guard !targets.isEmpty else { return nil }

        isSavingMetadata = true
        saveStatusMessage = "Saving…"
        defer { isSavingMetadata = false }

        await loadArtFilterTokens(for: targets)
        let assetByID = Dictionary(
            uniqueKeysWithValues: captureSets.flatMap(\.members).map { ($0.id, $0) })

        var groupedTargets: [AutoMetadataGroupKey: [(id: PhotoAsset.ID, url: URL)]] = [:]
        for target in targets {
            let asset = assetByID[target.id] ?? target
            let soocToken = AutoMetadataRules.soocToken(for: asset.url)
            let finalKeywords = AutoMetadataRules.keywordsWithAutoTokens(
                keywords, artFilterToken: asset.artFilterToken, cameraToken: asset.cameraModel,
                lensToken: asset.lensModel, soocToken: soocToken)
            let finalDescription = AutoMetadataRules.descriptionWithArtFilterNote(
                description, artFilterToken: asset.artFilterToken)
            let key = AutoMetadataGroupKey(description: finalDescription, keywords: finalKeywords)
            groupedTargets[key, default: []].append((id: asset.id, url: asset.url))
        }

        let finalStatus: String
        do {
            var failureCount = 0
            for (key, entries) in groupedTargets {
                let results = try await exifTool.write(
                    description: key.description, keywords: key.keywords, gps: gps,
                    to: entries.map(\.url))
                for entry in entries {
                    switch results[entry.url] {
                    case .success:
                        updateAsset(entry.id) { asset in
                            asset.descriptionText = key.description
                            asset.keywords = key.keywords
                            if let gps {
                                asset.gpsLatitude = gps.latitude
                                asset.gpsLongitude = gps.longitude
                            }
                        }
                    default:
                        failureCount += 1
                    }
                }
            }
            finalStatus =
                failureCount == 0
                ? "Saved to \(targets.count) file(s)."
                : "Saved \(targets.count - failureCount)/\(targets.count) file(s); \(failureCount) failed."
        } catch {
            finalStatus = "Save failed: \(error.localizedDescription)"
        }
        saveStatusMessage = finalStatus
        return finalStatus
    }
}

/// Groups `saveMetadata`'s write targets by their computed (description, keywords) pair, since
/// `AutoMetadataRules` tokens can differ per file within one save scope — see that method's doc
/// comment.
private struct AutoMetadataGroupKey: Hashable {
    var description: String
    var keywords: [String]
}
